import AppKit
import SwiftUI

/// Quick Terminal: short shell commands from the island, as QuickAsk is questions.
///
/// A command goes, in order:
///  1. a plain `cd` is done here (instant), and the folder carries over to the next command;
///  2. one that needs a real terminal (sudo, ssh, editors, REPLs…) isn't run: it's offered to
///     Terminal.app instead, ready to run there;
///  3. one that could do damage (rm -r, disk erase, `curl … | sh`, writing to system folders…) waits
///     for a confirmation;
///  4. everything else runs in the login shell (`ShellProcess`), its output streaming in.
///
/// The transcript keeps the last `maxLines` lines. The command keeps running when the island
/// closes; `status` (observed by the island) says so, so the pill can show it.
final class QuickTerminal: ObservableObject {
    struct Line: Identifiable, Equatable {
        enum Kind: Equatable {
            /// The command as typed, and the folder it ran in.
            case command(folder: String)
            case stdout, stderr
            /// How a command ended: success, failure (exit code) or stopped.
            case status(Outcome)
            /// A note from Quick Terminal itself.
            case notice
        }
        let id: Int
        var text: AttributedString
        let kind: Kind
    }

    enum Outcome: Equatable {
        case success, failure(Int32), stopped

        var succeeded: Bool { self == .success }
    }

    /// A question about the typed command, shown under the transcript.
    enum Prompt: Equatable {
        case none
        /// Risky: run only after a confirmation. `highlight` is the risky part (character offsets).
        case confirm(command: String, reason: String, highlight: Range<Int>)
        /// Can't run here: open it in Terminal.app instead.
        case needsTerminal(command: String, reason: String)
    }

    static let maxLines = 500

    @Published var input = ""
    /// The transcript. Not published itself: `revision` announces changes, once per batch of output.
    private(set) var lines: [Line] = []
    @Published private(set) var prompt: Prompt = .none
    /// The folder commands run in (starts at home).
    @Published private(set) var directory = FileManager.default.homeDirectoryForCurrentUser.path
    /// Bumped whenever the transcript changes, including a line being rewritten (to keep it scrolled).
    @Published private(set) var revision = 0
    /// While output is being decoded, changes are announced once at the end.
    private var batching = false
    let status = TerminalStatus()
    let history = TerminalHistory.shared
    /// Set by the controller: a command finished (for the pill's done/failed moment).
    var onFinish: ((TerminalStatus.Result) -> Void)?

    private var process: ShellProcess?
    private var previousDirectory: String?
    private var nextID = 0
    private var started = Date()
    private var runningCommand = ""
    /// Output waiting to be shown; filled on the reader queues, emptied on the main thread.
    private let pending = PendingOutput()
    private var decoders: [ShellProcess.Stream: TerminalDecoder] = [:]
    /// The line each stream is still writing (shown as it grows), by id.
    private var openLines: [ShellProcess.Stream: Int] = [:]
    /// Something in the output said it needed a terminal.
    private var wantedTerminal = false
    private var historyIndex: Int?
    private var draft = ""

    static let stderrColor = Color(red: 1, green: 0.5, blue: 0.47).opacity(0.85)

    var isRunning: Bool { process != nil }

    /// The folder for display: `~` for home, `~/Desktop` under it.
    var folderLabel: String { Self.abbreviate(directory) }

    static func abbreviate(_ path: String) -> String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        if path == home { return "~" }
        return path.hasPrefix(home + "/") ? "~" + path.dropFirst(home.count) : path
    }

    // MARK: Commands

    func submit() {
        let command = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !command.isEmpty else { return }
        guard !isRunning else {
            notice("“\(runningCommand)” is still running. Stop it first.")
            return
        }
        prompt = .none
        history.add(command)
        historyIndex = nil
        input = ""
        let parsed = ShellCommand(command)

        if let target = parsed.cdTarget {
            echo(command)
            changeDirectory(to: target)
            return
        }
        if let reason = parsed.interactiveReason {
            echo(command)
            print("terminal: needs a full terminal — \(command)")
            prompt = .needsTerminal(command: command, reason: reason)
            status.expanded = true
            return
        }
        if let risk = parsed.risk(in: directory) {
            print("terminal: asking before running — \(command)")
            let start = command.distance(from: command.startIndex, to: risk.range.lowerBound)
            prompt = .confirm(command: command, reason: risk.reason,
                              highlight: start..<(start + command[risk.range].count))
            status.expanded = true
            return
        }
        run(command)
    }

    /// "Run anyway" on a risky command.
    func confirm() {
        guard case .confirm(let command, _, _) = prompt else { return }
        prompt = .none
        run(command)
    }

    /// Dismisses the question (Escape, or its close button). False if there was none.
    @discardableResult
    func dismissPrompt() -> Bool {
        guard prompt != .none else { return false }
        if case .confirm(let command, _, _) = prompt {
            echo(command)
            notice("Not run.")
        }
        prompt = .none
        updateExpanded()
        return true
    }

    private func run(_ command: String) {
        echo(command)
        runningCommand = command
        started = Date()
        wantedTerminal = false
        decoders = [.stdout: TerminalDecoder(baseColor: Ink.primary), .stderr: TerminalDecoder(baseColor: Self.stderrColor)]
        openLines = [:]
        pending.reset()
        let directory = self.directory
        do {
            process = try ShellProcess(command: command, directory: directory) { [weak self] stream, data in
                guard let self else { return }
                if self.pending.add(stream, data) {
                    // Batch the output: at most ~30 updates a second, however fast it arrives.
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.033) { [weak self] in self?.flushOutput() }
                }
            } onExit: { [weak self] termination, folder in
                DispatchQueue.main.async { self?.finished(termination, folder: folder) }
            }
            status.isRunning = true
            print("terminal: running “\(command)” in \(directory) (pid \(process?.pid ?? 0))")
        } catch {
            print("terminal: couldn't start the shell — \(error)")
            append(.stderr, text: "Couldn't start the shell.")
            append(.status(.failure(127)), text: "")
        }
    }

    /// Stop: Ctrl-C first; if it's still running, ask it to quit, then make it.
    func stop() {
        guard let process else { return }
        print("terminal: stopping pid \(process.pid)")
        process.interrupt()
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
            guard self?.process === process else { return }
            process.terminate()
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
                if self?.process === process { process.forceQuit() }
            }
        }
    }

    private func finished(_ termination: ShellProcess.Termination, folder: String?) {
        flushOutput()
        // Lines still being written are done now.
        for (stream, id) in openLines {
            if let partial = decoders[stream]?.partialLine { replace(id, with: partial) }
        }
        openLines = [:]
        let seconds = Date().timeIntervalSince(started)
        let outcome: Outcome = switch termination {
        case .exited(0): .success
        case .exited(130), .signaled(SIGINT), .signaled(SIGTERM), .signaled(SIGKILL): .stopped
        case .exited(let code): .failure(code)
        case .signaled(let signal): .failure(128 + signal)
        }
        let duration = seconds < 10 ? String(format: "%.1f s", seconds) : String(format: "%.0f s", seconds)
        append(.status(outcome), text: duration)
        print("terminal: “\(runningCommand)” ended \(termination) after \(duration)")

        if let folder, folder != directory, FileManager.default.fileExists(atPath: folder) {
            previousDirectory = directory
            directory = folder
        }
        if wantedTerminal, outcome != .success {
            prompt = .needsTerminal(command: runningCommand, reason: "It needs to read from a real terminal.")
        }
        process = nil
        status.isRunning = false
        let result = TerminalStatus.Result(outcome: outcome, command: runningCommand)
        status.lastResult = result
        onFinish?(result)
    }

    // MARK: cd

    private func changeDirectory(to target: String) {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        var path: String
        switch target {
        case "~", "": path = home
        case "-":
            guard let previous = previousDirectory else {
                append(.stderr, text: "cd: no previous folder")
                append(.status(.failure(1)), text: "")
                return
            }
            path = previous
        default:
            path = ShellCommand.absolute(target, in: directory)
        }
        path = URL(fileURLWithPath: path).standardizedFileURL.path
        var isFolder: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isFolder), isFolder.boolValue else {
            append(.stderr, text: "cd: no such folder: \(target)")
            append(.status(.failure(1)), text: "")
            return
        }
        previousDirectory = directory
        directory = path
        if target == "-" { append(.stdout, text: Self.abbreviate(path)) }
        updateExpanded()
        print("terminal: cd → \(path)")
    }

    // MARK: Terminal.app

    /// Opens a new Terminal window in the current folder with the command typed in, not run (zsh's
    /// `print -z` puts it on the command line), so sudo's password prompt and the like happen there.
    /// If Terminal can't be scripted (the Automation permission was declined), it opens a window
    /// in the folder and the command goes on the clipboard instead.
    func openInTerminal() {
        guard case .needsTerminal(let command, _) = prompt else { return }
        TerminalHandoff.open(command, in: directory) { [weak self] scripted in
            guard let self else { return }
            if !scripted {
                self.notice("Copied the command. Paste it into Terminal with ⌘V.")
            }
        }
        prompt = .none
        updateExpanded()
    }

    // MARK: Transcript

    func clear() {
        lines = []
        openLines = [:]
        if case .confirm = prompt { prompt = .none }
        revision += 1
        updateExpanded()
    }

    /// The transcript as plain text.
    var plainText: String {
        lines.map { line in
            let text = String(line.text.characters)
            switch line.kind {
            case .command(let folder): return "\(folder) ❯ \(text)"
            case .status(.success): return "✓ \(text)"
            case .status(.failure(let code)): return "✕ exit \(code) · \(text)"
            case .status(.stopped): return "✕ stopped · \(text)"
            default: return text
            }
        }
        .joined(separator: "\n")
    }

    func copyOutput() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(plainText, forType: .string)
    }

    private func echo(_ command: String) {
        append(.command(folder: folderLabel), text: command)
    }

    private func notice(_ text: String) {
        append(.notice, text: text)
    }

    private func append(_ kind: Line.Kind, text: String) {
        var attributed = AttributedString(text)
        if kind == .stderr { attributed.foregroundColor = Self.stderrColor }
        append(kind, attributed)
    }

    @discardableResult
    private func append(_ kind: Line.Kind, _ text: AttributedString) -> Int {
        nextID += 1
        lines.append(Line(id: nextID, text: text, kind: kind))
        if lines.count > Self.maxLines { lines.removeFirst(lines.count - Self.maxLines) }
        if !batching {
            revision += 1
            updateExpanded()
        }
        return nextID
    }

    private func replace(_ id: Int, with text: AttributedString) {
        guard let index = lines.lastIndex(where: { $0.id == id }) else { return }
        lines[index].text = text
        if !batching { revision += 1 }
    }

    /// Decodes whatever output has arrived, in order, into lines.
    private func flushOutput() {
        let (chunks, trimmed) = pending.take()
        guard !chunks.isEmpty else { return }
        batching = true
        defer {
            batching = false
            revision += 1
            updateExpanded()
        }
        if trimmed { notice("… (a lot of output; only the most recent part is kept)") }
        for (stream, data) in chunks {
            guard var decoder = decoders[stream] else { continue }
            let complete = decoder.feed(data)
            let partial = decoder.partialLine
            decoders[stream] = decoder
            let kind: Line.Kind = stream == .stdout ? .stdout : .stderr
            for line in complete {
                if let open = openLines.removeValue(forKey: stream) { replace(open, with: line) } else { append(kind, line) }
                if stream == .stderr { checkForTerminalRequest(String(line.characters)) }
            }
            if let partial {
                if let open = openLines[stream] { replace(open, with: partial) } else { openLines[stream] = append(kind, partial) }
            }
        }
    }

    /// Programs that need a terminal say so when there isn't one; offer Terminal.app afterwards.
    private func checkForTerminalRequest(_ text: String) {
        let lower = text.lowercased()
        let signs = ["a terminal is required", "no tty present", "not a terminal", "inappropriate ioctl for device",
                     "must be run from a terminal", "requires a tty", "input is not a tty", "stdin is not a tty",
                     "the input device is not a tty", "not a tty"]
        if signs.contains(where: lower.contains) { wantedTerminal = true }
        if lower.contains("operation not permitted"), !lines.contains(where: { $0.kind == .notice && String($0.text.characters).contains("Privacy") }) {
            notice("macOS blocked that. To allow it: System Settings › Privacy & Security › Files & Folders (or Full Disk Access) › IslandMac.")
        }
    }

    private func updateExpanded() {
        let expanded = !lines.isEmpty || prompt != .none
        if status.expanded != expanded { status.expanded = expanded }
    }

    // MARK: History (↑ / ↓)

    func historyBack() {
        let items = history.items
        guard !items.isEmpty else { return }
        if let index = historyIndex {
            historyIndex = max(0, index - 1)
        } else {
            draft = input
            historyIndex = items.count - 1
        }
        input = items[historyIndex!]
    }

    func historyForward() {
        guard let index = historyIndex else { return }
        if index + 1 < history.items.count {
            historyIndex = index + 1
            input = history.items[index + 1]
        } else {
            historyIndex = nil
            input = draft
        }
    }
}

/// What the island needs to know about Quick Terminal, apart from its (busy) transcript: so the
/// island only redraws when these change, not on every line of output.
final class TerminalStatus: ObservableObject {
    struct Result: Equatable {
        let outcome: QuickTerminal.Outcome
        let command: String
    }

    @Published var isRunning = false
    /// The page shows more than its field (there's a transcript or a question).
    @Published var expanded = false
    @Published var lastResult: Result?
}

/// Commands run from Quick Terminal, oldest first, kept in UserDefaults for ↑/↓.
final class TerminalHistory: ObservableObject {
    static let shared = TerminalHistory()
    static let limit = 300
    private static let key = "TerminalHistory"

    @Published private(set) var items: [String]

    private init() {
        items = UserDefaults.standard.stringArray(forKey: Self.key) ?? []
    }

    func add(_ command: String) {
        if items.last == command { return }
        items.append(command)
        if items.count > Self.limit { items.removeFirst(items.count - Self.limit) }
        UserDefaults.standard.set(items, forKey: Self.key)
    }

    func clear() {
        items = []
        UserDefaults.standard.removeObject(forKey: Self.key)
        print("terminal: history cleared")
    }
}

/// Output read on background queues, waiting for the main thread. Very fast output is capped:
/// only the most recent part is kept, since the transcript only keeps its last lines anyway.
private final class PendingOutput {
    private let lock = NSLock()
    private var chunks: [(ShellProcess.Stream, Data)] = []
    private var bytes = 0
    private var trimmed = false
    private var scheduled = false
    private static let maxBytes = 512 * 1024

    /// Adds a chunk; true if a flush needs scheduling.
    func add(_ stream: ShellProcess.Stream, _ data: Data) -> Bool {
        lock.lock(); defer { lock.unlock() }
        chunks.append((stream, data))
        bytes += data.count
        while bytes > Self.maxBytes, chunks.count > 1 {
            bytes -= chunks.removeFirst().1.count
            trimmed = true
        }
        if scheduled { return false }
        scheduled = true
        return true
    }

    func take() -> ([(ShellProcess.Stream, Data)], Bool) {
        lock.lock(); defer { lock.unlock() }
        let result = (chunks, trimmed)
        chunks = []; bytes = 0; trimmed = false; scheduled = false
        return result
    }

    func reset() { _ = take() }
}

/// Hands a command to Terminal.app.
enum TerminalHandoff {
    /// Opens a Terminal window in `directory` with `command` on the command line, not yet run.
    /// `completion(true)` if Terminal was scripted; false if it fell back to the clipboard.
    static func open(_ command: String, in directory: String, completion: @escaping (Bool) -> Void) {
        let usesZsh = String(cString: getpwuid(getuid()).pointee.pw_shell).hasSuffix("zsh")
        let shellLine = usesZsh
            ? "cd -- \(quote(directory)) && print -z -- \(quote(command))"
            : "cd -- \(quote(directory)) && echo \(quote("Ready to run: " + command))"
        let source = """
        set wasRunning to application "Terminal" is running
        tell application "Terminal"
            if wasRunning then
                do script "\(appleScriptEscaped(shellLine))"
            else
                activate
                repeat 40 times
                    if (count of windows) > 0 then exit repeat
                    delay 0.05
                end repeat
                try
                    do script "\(appleScriptEscaped(shellLine))" in window 1
                on error
                    do script "\(appleScriptEscaped(shellLine))"
                end try
            end if
            activate
        end tell
        """
        if !usesZsh { copy(command) }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-e", source]
        let errors = Pipe()
        process.standardError = errors
        let finish: (Bool) -> Void = { ok in
            DispatchQueue.main.async {
                if !ok {
                    // No Automation permission: a window in the folder, and the command to paste.
                    copy(command)
                    let terminal = URL(fileURLWithPath: "/System/Applications/Utilities/Terminal.app")
                    NSWorkspace.shared.open([URL(fileURLWithPath: directory)], withApplicationAt: terminal, configuration: NSWorkspace.OpenConfiguration())
                }
                completion(ok)
            }
        }
        process.terminationHandler = { process in
            let ok = process.terminationStatus == 0
            if !ok {
                print("terminal: couldn't script Terminal — \(String(decoding: errors.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self))")
            }
            finish(ok)
        }
        do {
            try process.run()
            print("terminal: opening Terminal for “\(command)”")
        } catch {
            print("terminal: couldn't run osascript — \(error)")
            finish(false)
        }
    }

    private static func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    /// Single-quoted for the shell.
    static func quote(_ text: String) -> String {
        "'" + text.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    private static func appleScriptEscaped(_ text: String) -> String {
        text.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
    }
}

import Darwin
import Foundation
import SwiftUI

/// One command running in the user's login shell (`/bin/zsh -l -c`), so PATH and the rest of the
/// environment match Terminal (Homebrew, ollama, xcodebuild…).
///
/// It's started with posix_spawn in a session of its own, so Stop can signal the whole process
/// group (a pipeline, or a command the shell started) and nothing in it has a controlling terminal:
/// a program that wants a terminal fails at once ("a terminal is required") instead of waiting
/// forever. Input is /dev/null for the same reason. The shell reports its final folder on fd 3,
/// which is how `cd` inside a longer command carries over to the next one.
final class ShellProcess {
    enum Stream { case stdout, stderr }

    enum Termination: Equatable {
        case exited(Int32)
        case signaled(Int32)
    }

    let pid: pid_t
    private let outputs: [(Stream, FileHandle)]
    private let directoryPipe: Int32
    private let drained = DispatchGroup()

    /// Starts `command` in `directory`. `onOutput` gets raw bytes on a background queue as they
    /// arrive; `onExit` gets how it ended and the shell's final folder (nil if it didn't get to
    /// say, e.g. when stopped), also on a background queue, after the output has been delivered.
    init(command: String, directory: String, onOutput: @escaping (Stream, Data) -> Void,
         onExit: @escaping (Termination, String?) -> Void) throws {
        // The command, then report the folder on fd 3 and keep the command's exit status.
        let script = command + "\n__islandmac_status=$?\nprint -rn -- \"$PWD\" >&3 2>/dev/null\nexit $__islandmac_status"

        var out: [Int32] = [0, 0], err: [Int32] = [0, 0], dir: [Int32] = [0, 0]
        guard pipe(&out) == 0, pipe(&err) == 0, pipe(&dir) == 0 else { throw POSIXError(.EMFILE) }
        for fd in [out[0], err[0], dir[0]] { _ = fcntl(fd, F_SETFD, FD_CLOEXEC) }

        var actions: posix_spawn_file_actions_t?
        posix_spawn_file_actions_init(&actions)
        defer { posix_spawn_file_actions_destroy(&actions) }
        posix_spawn_file_actions_addopen(&actions, 0, "/dev/null", O_RDONLY, 0)
        posix_spawn_file_actions_adddup2(&actions, out[1], 1)
        posix_spawn_file_actions_adddup2(&actions, err[1], 2)
        posix_spawn_file_actions_adddup2(&actions, dir[1], 3)
        posix_spawn_file_actions_addchdir_np(&actions, directory)

        var attributes: posix_spawnattr_t?
        posix_spawnattr_init(&attributes)
        defer { posix_spawnattr_destroy(&attributes) }
        // A new session (no controlling terminal; its own process group to signal), no other open
        // files, default signal handling and nothing blocked (an app may ignore SIGPIPE; a shell
        // pipeline mustn't).
        posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_SETSID | POSIX_SPAWN_CLOEXEC_DEFAULT | POSIX_SPAWN_SETSIGDEF | POSIX_SPAWN_SETSIGMASK))
        var defaults: sigset_t = 0
        for signal in [SIGINT, SIGQUIT, SIGPIPE, SIGTERM, SIGHUP, SIGCHLD, SIGTSTP, SIGTTIN, SIGTTOU, SIGALRM] {
            defaults |= sigset_t(1) << sigset_t(signal - 1)
        }
        posix_spawnattr_setsigdefault(&attributes, &defaults)
        var unblocked: sigset_t = 0
        posix_spawnattr_setsigmask(&attributes, &unblocked)

        let argv = ["/bin/zsh", "-l", "-c", script].map { strdup($0) } + [nil]
        let envp = Self.environment().map { strdup("\($0.key)=\($0.value)") } + [nil]
        defer { (argv + envp).forEach { free($0) } }

        var pid: pid_t = 0
        let status = posix_spawn(&pid, "/bin/zsh", &actions, &attributes, argv, envp)
        // The child has its copies; the write ends here would keep the pipes from ever ending.
        close(out[1]); close(err[1]); close(dir[1])
        guard status == 0 else {
            close(out[0]); close(err[0]); close(dir[0])
            throw POSIXError(POSIXErrorCode(rawValue: status) ?? .EPERM)
        }
        self.pid = pid
        directoryPipe = dir[0]
        outputs = [(.stdout, FileHandle(fileDescriptor: out[0], closeOnDealloc: true)),
                   (.stderr, FileHandle(fileDescriptor: err[0], closeOnDealloc: true))]

        for (stream, handle) in outputs {
            drained.enter()
            handle.readabilityHandler = { [drained] handle in
                let data = handle.availableData
                if data.isEmpty {
                    handle.readabilityHandler = nil
                    drained.leave()
                } else {
                    onOutput(stream, data)
                }
            }
        }

        Thread.detachNewThread { [drained, directoryPipe] in
            var status: Int32 = 0
            while waitpid(pid, &status, 0) == -1 && errno == EINTR {}
            // The output normally ends with the shell; something left running in the background
            // can keep it open, so don't wait for that.
            _ = drained.wait(timeout: .now() + 0.5)
            let termination: Termination = status & 0x7f == 0 ? .exited((status >> 8) & 0xff) : .signaled(status & 0x7f)
            onExit(termination, Self.readAvailable(directoryPipe))
        }
    }

    /// Ctrl-C for the whole command.
    func interrupt() { kill(-pid, SIGINT) }
    func terminate() { kill(-pid, SIGTERM) }
    func forceQuit() { kill(-pid, SIGKILL) }

    /// The app's environment, plus what makes command-line tools behave without a terminal: no
    /// pager, no git credential prompt, and a TERM so tools that look at it don't complain.
    private static func environment() -> [String: String] {
        var env = ProcessInfo.processInfo.environment
        env["TERM"] = "xterm-256color"
        env["PAGER"] = "cat"
        env["GIT_PAGER"] = "cat"
        env["GIT_TERMINAL_PROMPT"] = "0"
        env["HOMEBREW_NO_ENV_HINTS"] = "1"
        if env["LANG"] == nil { env["LANG"] = "en_US.UTF-8" }
        return env
    }

    /// Whatever the shell wrote on fd 3, without waiting for more.
    private static func readAvailable(_ fd: Int32) -> String? {
        defer { close(fd) }
        _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while true {
            let n = read(fd, &buffer, buffer.count)
            guard n > 0 else { break }
            data.append(contentsOf: buffer[0..<n])
        }
        let path = String(decoding: data, as: UTF8.self)
        return path.hasPrefix("/") ? path : nil
    }
}

/// Turns a stream of terminal output into lines of styled text: ANSI colours (16, 256 and true
/// colour, bold, dim) become attributes, every other escape sequence (cursor movement, titles…) is
/// dropped, a bare carriage return rewrites the line (progress bars), and backspace erases.
/// Bytes can arrive split anywhere, including inside a character or an escape sequence.
struct TerminalDecoder {
    /// The colour of plain text on this stream.
    let baseColor: Color
    /// Longest line kept; the rest of a very long line is dropped.
    static let maxLineLength = 2000

    private var carry = Data()
    private var escape: String?
    private var inOSC = false
    private var oscEscape = false
    private var pendingCR = false
    private var line = AttributedString()
    private var run = ""
    private var lineLength = 0
    private var style = Style()

    private struct Style: Equatable {
        var color: Color?
        var bold = false
        var dim = false
    }

    init(baseColor: Color) { self.baseColor = baseColor }

    /// The line being written (not yet ended by a newline), if it has anything.
    var partialLine: AttributedString? {
        var current = line
        if !run.isEmpty { current.append(styled(run)) }
        return current.characters.isEmpty ? nil : current
    }

    /// Feeds bytes; returns the lines they completed.
    mutating func feed(_ data: Data) -> [AttributedString] {
        carry.append(data)
        let cut = Self.completeUTF8Prefix(carry)
        let text = String(decoding: carry.prefix(cut), as: UTF8.self)
        carry = Data(carry.suffix(from: carry.startIndex + cut))
        var lines: [AttributedString] = []
        for scalar in text.unicodeScalars { consume(scalar, into: &lines) }
        return lines
    }

    private mutating func consume(_ c: Unicode.Scalar, into lines: inout [AttributedString]) {
        if inOSC {
            // Operating system command (window title, hyperlinks): ends with BEL or ESC \.
            if c == "\u{07}" || (oscEscape && c == "\\") { inOSC = false; oscEscape = false } else { oscEscape = c == "\u{1B}" }
            return
        }
        if var sequence = escape {
            if sequence.isEmpty {
                switch c {
                case "[": escape = "["
                case "]": escape = nil; inOSC = true
                case "(", ")": escape = "("   // character set selection: one more byte
                default: escape = nil
                }
                return
            }
            if sequence == "(" { escape = nil; return }
            sequence.unicodeScalars.append(c)
            if (0x40...0x7E).contains(c.value) {
                escape = nil
                if c == "m" { applySGR(String(sequence.dropFirst().dropLast())) }
            } else {
                escape = sequence.count > 64 ? nil : sequence
            }
            return
        }
        if pendingCR {
            pendingCR = false
            if c != "\n" {
                // A bare carriage return: the line is being rewritten.
                line = AttributedString(); run = ""; lineLength = 0
            }
        }
        switch c {
        case "\u{1B}":
            flushRun()
            escape = ""
        case "\n":
            flushRun()
            lines.append(line)
            line = AttributedString(); lineLength = 0
        case "\r":
            pendingCR = true
        case "\u{08}":
            if !run.isEmpty { run.removeLast(); lineLength -= 1 }
        case "\t":
            let spaces = 4 - lineLength % 4
            append(String(repeating: " ", count: spaces))
        case _ where c.value < 0x20 || c.value == 0x7F:
            break
        default:
            append(String(c))
        }
    }

    private mutating func append(_ text: String) {
        guard lineLength < Self.maxLineLength else { return }
        run += text
        lineLength += text.count
        if lineLength >= Self.maxLineLength { run += " …" }
    }

    private mutating func flushRun() {
        guard !run.isEmpty else { return }
        line.append(styled(run))
        run = ""
    }

    private func styled(_ text: String) -> AttributedString {
        var piece = AttributedString(text)
        piece.foregroundColor = (style.color ?? baseColor).opacity(style.dim ? 0.6 : 1)
        if style.bold { piece.inlinePresentationIntent = .stronglyEmphasized }
        return piece
    }

    /// Select Graphic Rendition: `ESC [ … m`.
    private mutating func applySGR(_ parameters: String) {
        flushRun()
        let codes = parameters.split(separator: ";", omittingEmptySubsequences: false).map { Int($0) ?? 0 }
        var i = 0
        while i < max(codes.count, 1) {
            let code = codes.isEmpty ? 0 : codes[i]
            switch code {
            case 0: style = Style()
            case 1: style.bold = true
            case 2: style.dim = true
            case 22: style.bold = false; style.dim = false
            case 30...37: style.color = Self.palette[code - 30]
            case 90...97: style.color = Self.palette[code - 90 + 8]
            case 39: style.color = nil
            case 38:
                if i + 2 < codes.count, codes[i + 1] == 5 {
                    style.color = Self.color256(codes[i + 2]); i += 2
                } else if i + 4 < codes.count, codes[i + 1] == 2 {
                    style.color = Color(red: Double(codes[i + 2]) / 255, green: Double(codes[i + 3]) / 255, blue: Double(codes[i + 4]) / 255)
                    i += 4
                }
            case 48:
                // Background colours aren't drawn; skip their arguments.
                if i + 1 < codes.count { i += codes[i + 1] == 5 ? 2 : codes[i + 1] == 2 ? 4 : 0 }
            default: break
            }
            i += 1
        }
    }

    /// The 16 ANSI colours, tuned to read on the island's black.
    private static let palette: [Color] = [
        Color(white: 0.5), Color(red: 1, green: 0.42, blue: 0.4), Color(red: 0.45, green: 0.86, blue: 0.5), Color(red: 0.95, green: 0.82, blue: 0.4),
        Color(red: 0.45, green: 0.65, blue: 1), Color(red: 0.85, green: 0.55, blue: 1), Color(red: 0.4, green: 0.85, blue: 0.9), Color(white: 0.88),
        Color(white: 0.62), Color(red: 1, green: 0.55, blue: 0.52), Color(red: 0.58, green: 0.93, blue: 0.62), Color(red: 1, green: 0.9, blue: 0.55),
        Color(red: 0.6, green: 0.76, blue: 1), Color(red: 0.92, green: 0.68, blue: 1), Color(red: 0.55, green: 0.92, blue: 0.95), Color(white: 1),
    ]

    private static func color256(_ n: Int) -> Color {
        switch n {
        case 0..<16: return palette[n]
        case 16..<232:
            let i = n - 16
            let level = { (v: Int) -> Double in v == 0 ? 0 : (Double(v) * 40 + 55) / 255 }
            return Color(red: level(i / 36), green: level(i / 6 % 6), blue: level(i % 6))
        default:
            return Color(white: (Double(n - 232) * 10 + 8) / 255)
        }
    }

    /// How many leading bytes form whole UTF-8 characters (a character split across reads waits).
    static func completeUTF8Prefix(_ data: Data) -> Int {
        let bytes = [UInt8](data.suffix(4))
        var back = 0
        for byte in bytes.reversed() {
            back += 1
            if byte & 0xC0 == 0x80 { continue }          // continuation byte
            let length = byte >= 0xF0 ? 4 : byte >= 0xE0 ? 3 : byte >= 0xC0 ? 2 : 1
            return length > back ? data.count - back : data.count
        }
        return data.count
    }
}

import Foundation

/// A typed shell command, read just well enough to decide how Quick Terminal handles it: a plain
/// `cd` (done in the app), something that needs a real terminal (sudo, editors, REPLs…), or
/// something risky enough to confirm first. It never runs anything.
///
/// The reading is zsh-like but deliberately shallow: words (with quotes and backslashes removed),
/// split into simple commands at `;` `&&` `||` `|` `&` and newlines, with redirections as their own
/// words. Anything it can't follow (substitutions, globs) just runs in the shell as typed.
struct ShellCommand {
    struct Word {
        /// The word with quotes and escapes removed.
        let text: String
        /// Where it is in the typed command.
        let range: Range<String.Index>
        /// It had quotes or escapes (so `~` and `$` in it are literal).
        let quoted: Bool
    }

    /// One simple command (`ls -la`), and whether text is piped into it (`… | sh`).
    struct Segment {
        let words: [Word]
        let pipedInput: Bool
        /// From its first word to its last, in the typed command.
        var range: Range<String.Index>? {
            guard let first = words.first, let last = words.last else { return nil }
            return first.range.lowerBound..<last.range.upperBound
        }
    }

    let source: String
    let segments: [Segment]

    init(_ source: String) {
        self.source = source
        segments = Self.parse(source)
    }

    // MARK: cd

    /// For a command that is only `cd [dir]`, the directory to go to (`~` for home, `-` for the
    /// previous one); nil for anything else, which the shell handles (and reports its folder back).
    var cdTarget: String? {
        guard segments.count == 1, let words = segments.first?.words, words.first?.text == "cd", words.count <= 2,
              !source.contains("$("), !source.contains("`") else { return nil }
        guard words.count == 2 else { return "~" }
        let target = words[1]
        // Globs and variables (other than a leading $HOME) are the shell's to expand.
        if !target.quoted, target.text.contains(where: { "*?[$".contains($0) }), !target.text.hasPrefix("$HOME") { return nil }
        if !target.quoted, target.text.hasPrefix("$HOME") { return "~" + target.text.dropFirst("$HOME".count) }
        return target.text
    }

    // MARK: Needs a real terminal

    /// Why this command needs a real terminal (it reads the keyboard, draws full-screen, or asks
    /// for a password), or nil if it can run here.
    var interactiveReason: String? {
        for segment in segments {
            guard let (name, args) = Self.command(of: segment.words) else { continue }
            if let reason = Self.interactiveReason(name: name, args: args.map(\.text), pipedInput: segment.pipedInput) {
                return reason
            }
        }
        return nil
    }

    private static let fullScreen: Set<String> = [
        "vi", "vim", "nvim", "nano", "pico", "emacs", "micro", "hx", "less", "more", "most", "man",
        "top", "htop", "btop", "atop", "glances", "watch", "tmux", "screen", "mc", "ranger", "nnn", "tig", "lazygit",
    ]
    private static let remoteLogins: Set<String> = ["ssh", "sftp", "ftp", "telnet", "mosh", "rlogin"]
    /// Interactive with no arguments (a REPL or a client that waits for input).
    private static let repls: Set<String> = [
        "python", "python3", "python2", "node", "deno", "bun", "irb", "ruby", "lua", "ghci", "R", "julia", "php", "perl",
        "bash", "zsh", "sh", "fish", "dash", "ksh", "tcsh", "csh", "sqlite3", "mysql", "psql", "redis-cli", "mongosh", "mongo",
        "bc", "dc", "swift", "nslookup", "cat", "osascript",
    ]

    private static func interactiveReason(name: String, args: [String], pipedInput: Bool) -> String? {
        let flags = args.filter { $0.hasPrefix("-") }
        let operands = args.filter { !$0.hasPrefix("-") }
        switch name {
        case "sudo", "doas", "su", "login", "passwd", "visudo", "kinit":
            return name == "sudo" || name == "doas" ? "sudo asks for your password." : "\(name) asks for a password."
        case _ where remoteLogins.contains(name):
            return "\(name) opens a remote session and may ask for a password."
        case "emacs" where args.contains("--batch"):
            return nil
        case _ where fullScreen.contains(name):
            return "\(name) needs a full-screen terminal."
        case "ollama" where args.first == "run":
            // `ollama run <model>` alone is a chat; with a prompt (or piped input) it answers and exits.
            let rest = args.dropFirst().filter { !$0.hasPrefix("-") }
            return rest.count <= 1 && !pipedInput ? "ollama run without a prompt starts a chat." : nil
        case "git":
            let sub = operands.first ?? ""
            if sub == "commit", !args.contains(where: { ["-m", "-F", "--no-edit", "-C", "--fixup", "--amend"].contains($0) || $0.hasPrefix("-m") || $0.hasPrefix("--message") || $0.hasPrefix("--file") }) {
                return "git commit without -m opens an editor."
            }
            if sub == "rebase", flags.contains(where: { $0 == "-i" || $0 == "--interactive" }) { return "git rebase -i opens an editor." }
            if sub == "add", flags.contains(where: { ["-p", "-i", "--patch", "--interactive"].contains($0) }) { return "git add -p asks about each change." }
            if ["mergetool", "difftool"].contains(sub) { return "git \(sub) opens another tool." }
            return nil
        case "crontab" where flags.contains("-e"):
            return "crontab -e opens an editor."
        case "docker", "podman", "kubectl":
            let wantsTTY = flags.contains { $0 == "-it" || $0 == "-ti" || $0 == "-t" || $0 == "--tty" || $0 == "--interactive" || $0 == "-i" }
            return wantsTTY ? "\(name) with -it attaches to a terminal." : nil
        case "read", "select", "vared":
            return "\(name) waits for typing."
        case _ where repls.contains(name):
            // Only with nothing to run: `python3 script.py`, `sqlite3 db "select …"` and `bash -c …` run here.
            if pipedInput { return nil }
            if name == "sqlite3" || name == "mysql" || name == "psql" { return operands.count <= 1 && !flags.contains("-c") && !flags.contains("-e") ? "\(name) opens an interactive prompt." : nil }
            if name == "osascript" { return operands.isEmpty && !flags.contains("-e") ? "osascript without a script waits for typing." : nil }
            if name == "cat" { return args.isEmpty ? "cat with no file waits for typing." : nil }
            if flags.contains("-i") { return "\(name) -i starts an interactive session." }
            return operands.isEmpty && !flags.contains("-c") && !flags.contains("-e") && !flags.contains("--version") && !flags.contains("-V") && !flags.contains("--help")
                ? "\(name) with nothing to run starts an interactive session." : nil
        default:
            return nil
        }
    }

    // MARK: Risky

    /// Why to confirm before running, and the part of the command to highlight.
    struct Risk {
        let reason: String
        let range: Range<String.Index>
    }

    /// System folders a command shouldn't write to without asking (not /usr/local, /opt or /tmp).
    private static let systemFolders = ["/System", "/Library", "/bin", "/sbin", "/usr", "/etc", "/private", "/var", "/cores"]
    private static let userWritableUnderSystem = ["/usr/local", "/private/tmp", "/private/var/folders", "/var/folders", "/var/tmp"]
    /// Commands that change the paths they're given…
    private static let modifiesArguments: Set<String> = [
        "rm", "rmdir", "chmod", "chown", "chgrp", "chflags", "touch", "mkdir", "tee", "truncate", "xattr", "unlink", "srm", "shred",
    ]
    /// …or only their last one (the destination).
    private static let writesDestination: Set<String> = ["cp", "mv", "ln", "rsync", "ditto", "install", "scp"]

    /// The first reason to confirm, if any. `directory` resolves relative paths.
    func risk(in directory: String) -> Risk? {
        // A script from the internet run straight into a shell.
        if let match = source.range(of: #"\b(curl|wget|fetch)\b[^|;&]*\|\s*(sudo\s+)?(env\s+)?(ba|z|da|k|fi|tc|c)?sh\b"#, options: .regularExpression)
            ?? source.range(of: #"\b(ba|z|da|k)?sh\b[^;&|]*(\$\(|<\(|`)\s*(curl|wget)\b[^)`]*[)`]?"#, options: .regularExpression) {
            return Risk(reason: "Runs a script downloaded from the internet.", range: match)
        }
        for segment in segments {
            guard let range = segment.range, let (name, args) = Self.command(of: segment.words) else { continue }
            let words = segment.words.map(\.text)
            let flags = args.map(\.text).filter { $0.hasPrefix("-") && $0 != "-" }
            let operands = args.filter { !$0.text.hasPrefix("-") }

            switch name {
            case "sudo", "doas":
                return Risk(reason: "Runs with administrator rights.", range: range)
            case "rm" where flags.contains { $0 == "--recursive" || (!$0.hasPrefix("--") && ($0.contains("r") || $0.contains("R"))) }:
                return Risk(reason: "Permanently deletes files and folders, including everything inside them.", range: range)
            case "find" where words.contains("-delete") || words.contains(where: { $0 == "-exec" || $0 == "-execdir" }) && words.contains("rm"):
                return Risk(reason: "Deletes every file it finds.", range: range)
            case "diskutil" where operands.first.map({ ["eraseDisk", "eraseVolume", "reformat", "zeroDisk", "randomDisk", "secureErase", "partitionDisk", "splitPartition", "mergePartitions"].contains($0.text) || ($0.text == "apfs" && operands.dropFirst().first.map { $0.text.lowercased().contains("delete") || $0.text.lowercased().contains("erase") } == true) }) == true:
                return Risk(reason: "Erases or repartitions a disk.", range: range)
            case "dd" where words.contains { $0.hasPrefix("of=") }:
                return Risk(reason: "Writes raw data over a disk or file.", range: range)
            case _ where name.hasPrefix("mkfs") || name.hasPrefix("newfs"):
                return Risk(reason: "Formats a disk.", range: range)
            case "shutdown", "reboot", "halt":
                return Risk(reason: "Shuts down or restarts your Mac.", range: range)
            case "csrutil", "nvram", "spctl":
                return Risk(reason: "Changes macOS security or startup settings.", range: range)
            case "git":
                let sub = operands.first?.text
                if sub == "reset", flags.contains("--hard") { return Risk(reason: "Discards uncommitted changes.", range: range) }
                if sub == "clean", flags.contains(where: { $0.hasPrefix("-") && !$0.hasPrefix("--") && $0.contains("f") || $0 == "--force" }) {
                    return Risk(reason: "Deletes untracked files.", range: range)
                }
                if sub == "push", flags.contains(where: { $0 == "-f" || $0 == "--force" || $0.hasPrefix("--force-with-lease") }) {
                    return Risk(reason: "Overwrites the remote branch's history.", range: range)
                }
            default:
                break
            }

            // Writing into system folders.
            var targets: [Word] = []
            if Self.modifiesArguments.contains(name) || (name == "sed" && flags.contains { $0.hasPrefix("-i") }) {
                targets = operands
            } else if Self.writesDestination.contains(name), let last = operands.last {
                targets = [last]
            }
            // Redirections: `> /etc/hosts`.
            for (i, word) in segment.words.enumerated() where [">", ">>", ">|", "&>", "&>>"].contains(word.text) && i + 1 < segment.words.count {
                targets.append(segment.words[i + 1])
            }
            if let target = targets.first(where: { Self.isSystemPath(Self.absolute($0.text, in: directory)) }) {
                return Risk(reason: "Changes files in a macOS system folder (\(Self.absolute(target.text, in: directory))).", range: range)
            }
        }
        return nil
    }

    private static func isSystemPath(_ path: String) -> Bool {
        let standardized = (path as NSString).standardizingPath
        func under(_ folder: String) -> Bool { standardized == folder || standardized.hasPrefix(folder + "/") }
        if standardized == "/" { return true }
        return systemFolders.contains(where: under) && !userWritableUnderSystem.contains(where: under)
    }

    static func absolute(_ path: String, in directory: String) -> String {
        let expanded = (path as NSString).expandingTildeInPath
        return expanded.hasPrefix("/") ? expanded : (directory as NSString).appendingPathComponent(expanded)
    }

    // MARK: Reading

    /// The command's name (basename, past `VAR=x` assignments and wrappers like `env`, `nohup`,
    /// `time`, `command`, `xargs`) and its arguments. A wrapper that is itself the point (`sudo`) stays.
    static func command(of words: [Word]) -> (name: String, args: [Word])? {
        var i = 0
        let wrappers: Set<String> = ["command", "builtin", "exec", "nohup", "time", "env", "nice", "caffeinate", "xargs", "noglob", "then", "do", "else", "!", "{", "("]
        while i < words.count {
            let text = words[i].text
            if !words[i].quoted, text.range(of: #"^[A-Za-z_][A-Za-z0-9_]*="#, options: .regularExpression) != nil { i += 1; continue }
            if wrappers.contains(text) {
                i += 1
                // A wrapper's own options (`env -i`, `nice -n 5`, `xargs -0`).
                while i < words.count, words[i].text.hasPrefix("-") { i += 1 }
                continue
            }
            break
        }
        guard i < words.count else { return nil }
        let name = (words[i].text as NSString).lastPathComponent
        return (name, Array(words[(i + 1)...]))
    }

    private static func parse(_ source: String) -> [Segment] {
        var segments: [Segment] = []
        var words: [Word] = []
        var pipedInput = false
        var text = "", start: String.Index?, quoted = false
        var i = source.startIndex

        func endWord(at end: String.Index) {
            if let s = start { words.append(Word(text: text, range: s..<end, quoted: quoted)) }
            text = ""; start = nil; quoted = false
        }
        func endSegment(pipe: Bool) {
            if !words.isEmpty { segments.append(Segment(words: words, pipedInput: pipedInput)) }
            words = []
            pipedInput = pipe
        }

        while i < source.endIndex {
            let c = source[i]
            let next = source.index(after: i)
            switch c {
            case "'":
                if start == nil { start = i }
                quoted = true
                var j = next
                while j < source.endIndex, source[j] != "'" { text.append(source[j]); j = source.index(after: j) }
                i = j < source.endIndex ? source.index(after: j) : j
                continue
            case "\"":
                if start == nil { start = i }
                quoted = true
                var j = next
                while j < source.endIndex, source[j] != "\"" {
                    if source[j] == "\\", source.index(after: j) < source.endIndex, "\"\\$`".contains(source[source.index(after: j)]) {
                        j = source.index(after: j)
                    }
                    text.append(source[j]); j = source.index(after: j)
                }
                i = j < source.endIndex ? source.index(after: j) : j
                continue
            case "\\":
                if start == nil { start = i }
                quoted = true
                if next < source.endIndex {
                    if source[next] != "\n" { text.append(source[next]) }
                    i = source.index(after: next)
                } else {
                    i = next
                }
                continue
            case "#" where start == nil:
                // A comment runs to the end of the line.
                while i < source.endIndex, source[i] != "\n" { i = source.index(after: i) }
                continue
            case " ", "\t":
                endWord(at: i)
            case "\n", ";":
                endWord(at: i)
                endSegment(pipe: false)
            case "(", ")", "{", "}":
                // Grouping (`(cd x && ls)`, `{ …; }`); inside a word (`${HOME}`, `$(…)`) they're text.
                if start == nil {
                    endSegment(pipe: false)
                } else {
                    text.append(c)
                }
            case "|", "&":
                endWord(at: i)
                let doubled = next < source.endIndex && source[next] == c
                if c == "&", next < source.endIndex, source[next] == ">" {
                    // `&>` / `&>>`: a redirection, not a separator.
                    var j = source.index(after: next)
                    if j < source.endIndex, source[j] == ">" { j = source.index(after: j) }
                    words.append(Word(text: String(source[i..<j]), range: i..<j, quoted: false))
                    i = j
                    continue
                }
                endSegment(pipe: c == "|" && !doubled)
                i = doubled ? source.index(after: next) : next
                continue
            case ">", "<":
                // A redirection operator is a word of its own (`2>` keeps its digit).
                var opStart = i
                if let s = start, text.allSatisfy(\.isNumber), !quoted { opStart = s; text = ""; start = nil } else { endWord(at: i) }
                var j = next
                while j < source.endIndex, ">|&".contains(source[j]) { j = source.index(after: j) }
                let op = String(source[opStart..<j]).trimmingCharacters(in: .decimalDigits)
                words.append(Word(text: op, range: opStart..<j, quoted: false))
                i = j
                continue
            default:
                if start == nil { start = i }
                text.append(c)
            }
            i = next
        }
        endWord(at: source.endIndex)
        endSegment(pipe: false)
        return segments
    }
}

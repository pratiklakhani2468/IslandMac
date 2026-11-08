import Foundation

/// IslandMac's settings, in UserDefaults.
final class AppSettings: ObservableObject {
    static let shared = AppSettings()

    @Published var terminalShortcut: HotKeyShortcut {
        didSet { UserDefaults.standard.set(try? JSONEncoder().encode(terminalShortcut), forKey: Keys.terminalShortcut) }
    }
    /// While a Settings shortcut recorder listens, the hotkey is suspended so pressing the current
    /// combination records it instead of opening its page.
    @Published var isRecordingShortcut = false
    /// macOS refused the shortcut (another app owns it).
    @Published var terminalShortcutUnavailable = false

    private enum Keys {
        static let terminalShortcut = "TerminalShortcut"
    }

    private init() {
        let defaults = UserDefaults.standard
        terminalShortcut = defaults.data(forKey: Keys.terminalShortcut).flatMap { try? JSONDecoder().decode(HotKeyShortcut.self, from: $0) }
            ?? .terminalDefault
    }
}

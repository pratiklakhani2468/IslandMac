import AppKit
import Carbon.HIToolbox

setvbuf(stdout, nil, _IOLBF, 0)

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var controller: IslandController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        print("IslandMac pid \(ProcessInfo.processInfo.processIdentifier) exe \(CommandLine.arguments[0])")
        controller = IslandController(pinnedState: Self.pinnedStateArgument())
        // `--simulate-drag <seconds>` plays a file drag for profiling (see IslandController).
        let args = CommandLine.arguments
        if let i = args.firstIndex(of: "--simulate-drag"), i + 1 < args.count, let seconds = Double(args[i + 1]) {
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in self?.controller?.simulateFileDrag(seconds: seconds) }
        }
        // ⌃⌥⌘Q quits from anywhere, independent of the island and the menu bar.
        let quit = HotKeyShortcut(keyCode: UInt32(kVK_ANSI_Q), modifiers: UInt32(cmdKey | optionKey | controlKey), keyLabel: "Q")
        let ok = GlobalHotKeys.shared.register(.quit, quit) { NSApp.terminate(nil) }
        print(ok ? "quit hotkey \(quit.displayString) registered" : "quit hotkey registration FAILED")
    }

    /// `--state resting|hover|expanded` pins the island in one state, for visual verification only.
    private static func pinnedStateArgument() -> IslandState? {
        let args = CommandLine.arguments
        guard let i = args.firstIndex(of: "--state"), i + 1 < args.count else { return nil }
        return IslandState(rawValue: args[i + 1])
    }
}

let app = NSApplication.shared
app.setActivationPolicy(.accessory)
let delegate = AppDelegate()
app.delegate = delegate
app.run()

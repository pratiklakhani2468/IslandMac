import AppKit
import Carbon.HIToolbox

/// A key combination for a global hotkey: Carbon key code and modifiers (what
/// `RegisterEventHotKey` takes), plus the key's label as typed, for display.
struct HotKeyShortcut: Codable, Equatable {
    var keyCode: UInt32
    /// Carbon modifier mask (`cmdKey`, `optionKey`, `controlKey`, `shiftKey`).
    var modifiers: UInt32
    var keyLabel: String

    /// Quick Terminal's default: ⌃⌥T.
    static let terminalDefault = HotKeyShortcut(keyCode: UInt32(kVK_ANSI_T), modifiers: UInt32(controlKey | optionKey), keyLabel: "T")

    /// "⌥Space", "⌃⌘K" (modifiers in the standard macOS order).
    var displayString: String {
        var s = ""
        if modifiers & UInt32(controlKey) != 0 { s += "⌃" }
        if modifiers & UInt32(optionKey) != 0 { s += "⌥" }
        if modifiers & UInt32(shiftKey) != 0 { s += "⇧" }
        if modifiers & UInt32(cmdKey) != 0 { s += "⌘" }
        return s + keyLabel
    }

    /// The shortcut a key press describes, or nil if it isn't usable as a global hotkey (it needs
    /// ⌘, ⌥ or ⌃, so ordinary typing is never captured).
    init?(event: NSEvent) {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        var carbon: UInt32 = 0
        if flags.contains(.command) { carbon |= UInt32(cmdKey) }
        if flags.contains(.option) { carbon |= UInt32(optionKey) }
        if flags.contains(.control) { carbon |= UInt32(controlKey) }
        if flags.contains(.shift) { carbon |= UInt32(shiftKey) }
        guard carbon & UInt32(cmdKey | optionKey | controlKey) != 0 else { return nil }
        let code = Int(event.keyCode)
        let label = Self.specialKeys[code] ?? event.charactersIgnoringModifiers?.uppercased() ?? ""
        guard !label.isEmpty, !label.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else { return nil }
        self.init(keyCode: UInt32(code), modifiers: carbon, keyLabel: label)
    }

    init(keyCode: UInt32, modifiers: UInt32, keyLabel: String) {
        self.keyCode = keyCode
        self.modifiers = modifiers
        self.keyLabel = keyLabel
    }

    private static let specialKeys: [Int: String] = [
        kVK_Space: "Space", kVK_Return: "↩", kVK_Tab: "⇥", kVK_Delete: "⌫", kVK_ForwardDelete: "⌦",
        kVK_LeftArrow: "←", kVK_RightArrow: "→", kVK_UpArrow: "↑", kVK_DownArrow: "↓",
        kVK_Home: "↖", kVK_End: "↘", kVK_PageUp: "⇞", kVK_PageDown: "⇟",
        kVK_F1: "F1", kVK_F2: "F2", kVK_F3: "F3", kVK_F4: "F4", kVK_F5: "F5", kVK_F6: "F6",
        kVK_F7: "F7", kVK_F8: "F8", kVK_F9: "F9", kVK_F10: "F10", kVK_F11: "F11", kVK_F12: "F12",
    ]
}

/// System-wide hotkeys (Carbon `RegisterEventHotKey`: works from any app, no Accessibility
/// permission). One event handler serves them all and dispatches by the hotkey's ID, so each
/// hotkey runs only its own action.
final class GlobalHotKeys {
    static let shared = GlobalHotKeys()

    enum ID: UInt32 {
        case quit = 1
        case terminal = 3
    }

    /// 'ISLD': marks IslandMac's hotkeys.
    private static let signature = OSType(0x4953_4C44)
    private var actions: [UInt32: () -> Void] = [:]
    private var refs: [UInt32: EventHotKeyRef] = [:]

    private init() {
        var eventType = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, event, _ in
            var hotKey = EventHotKeyID()
            let status = GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                                           nil, MemoryLayout<EventHotKeyID>.size, nil, &hotKey)
            guard status == noErr, hotKey.signature == GlobalHotKeys.signature else { return OSStatus(eventNotHandledErr) }
            DispatchQueue.main.async { GlobalHotKeys.shared.actions[hotKey.id]?() }
            return noErr
        }, 1, &eventType, nil, nil)
    }

    /// Registers (or re-registers) `id`. False if macOS refused, typically because another app
    /// already owns that combination.
    @discardableResult
    func register(_ id: ID, _ shortcut: HotKeyShortcut, action: @escaping () -> Void) -> Bool {
        unregister(id)
        var ref: EventHotKeyRef?
        let status = RegisterEventHotKey(shortcut.keyCode, shortcut.modifiers, EventHotKeyID(signature: Self.signature, id: id.rawValue),
                                         GetApplicationEventTarget(), 0, &ref)
        guard status == noErr, let ref else {
            print("hotkey \(shortcut.displayString) registration FAILED (\(status))")
            return false
        }
        refs[id.rawValue] = ref
        actions[id.rawValue] = action
        return true
    }

    func unregister(_ id: ID) {
        if let ref = refs.removeValue(forKey: id.rawValue) { UnregisterEventHotKey(ref) }
        actions[id.rawValue] = nil
    }
}

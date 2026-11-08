import AppKit
import SwiftUI

/// IslandMac's Settings window, opened from the island's right-click menu. IslandMac has no Dock
/// icon, so opening it activates the app first.
final class SettingsWindowController: NSObject, NSWindowDelegate {
    static let shared = SettingsWindowController()
    private var window: NSWindow?

    @objc func showSettings(_ sender: Any?) {
        if window == nil {
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 480, height: 360),
                                  styleMask: [.titled, .closable], backing: .buffered, defer: false)
            window.title = "IslandMac Settings"
            window.isReleasedWhenClosed = false
            window.delegate = self
            window.contentView = NSHostingView(rootView: SettingsView(settings: .shared))
            window.center()
            self.window = window
        }
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
        print("settings: opened")
    }

    func windowWillClose(_ notification: Notification) {
        AppSettings.shared.isRecordingShortcut = false
    }
}

private struct SettingsView: View {
    @ObservedObject var settings: AppSettings

    var body: some View {
        Form {
            Section("File Conversion") {
                LabeledContent("Trigger") {
                    Text("Drop files on the island").foregroundStyle(.secondary)
                }
                LabeledContent("Documents") {
                    DocumentEngineStatus()
                }
            }
            Section("Quick Terminal") {
                LabeledContent("Shortcut") {
                    VStack(alignment: .trailing, spacing: 4) {
                        ShortcutRecorder(settings: settings, shortcut: $settings.terminalShortcut, defaultShortcut: .terminalDefault)
                        if settings.terminalShortcutUnavailable && !settings.isRecordingShortcut {
                            Text("Another app is using this shortcut. Choose a different one.")
                                .font(.caption).foregroundStyle(.orange)
                        }
                    }
                }
                LabeledContent("History") {
                    HistoryControl(history: .shared)
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 480)
        .fixedSize(horizontal: false, vertical: true)
    }
}

/// Whether LibreOffice is there for office documents (checked when Settings opens).
private struct DocumentEngineStatus: View {
    @State private var found = DocumentTools.libreOffice != nil

    var body: some View {
        VStack(alignment: .trailing, spacing: 3) {
            Label(found ? "LibreOffice" : "Built into macOS", systemImage: found ? "checkmark.circle.fill" : "circle.dashed")
                .foregroundStyle(found ? .green : .secondary)
            Text(found ? "Word, PowerPoint and Excel files become PDFs at full fidelity."
                       : "Word, RTF and text files become PDFs with a simpler layout. For PowerPoint and Excel, install LibreOffice: \(Text("brew install --cask libreoffice").font(.caption.monospaced()))")
                .font(.caption).foregroundStyle(.secondary)
                .multilineTextAlignment(.trailing)
                .frame(maxWidth: 260, alignment: .trailing)
        }
        .onAppear { found = DocumentTools.libreOffice != nil }
    }
}

/// How many commands Quick Terminal remembers for ↑/↓, and a button to forget them.
private struct HistoryControl: View {
    @ObservedObject var history: TerminalHistory

    var body: some View {
        HStack {
            Text(history.items.isEmpty ? "Empty" : "\(history.items.count) command\(history.items.count == 1 ? "" : "s")")
                .foregroundStyle(.secondary)
            Button("Clear History") { history.clear() }
                .disabled(history.items.isEmpty)
        }
    }
}

/// Shows a page's shortcut; "Record" listens for the next key combination (with ⌘, ⌥ or ⌃).
/// Escape cancels. The hotkeys are suspended while recording.
private struct ShortcutRecorder: View {
    @ObservedObject var settings: AppSettings
    @Binding var shortcut: HotKeyShortcut
    let defaultShortcut: HotKeyShortcut
    /// This recorder is the one listening (the suspension in settings covers every hotkey).
    @State private var recording = false
    @State private var monitor: Any?

    var body: some View {
        HStack(spacing: 8) {
            Text(recording ? "Type a shortcut…" : shortcut.displayString)
                .font(.system(.body, design: .rounded).weight(.medium))
                .foregroundStyle(recording ? .secondary : .primary)
                .frame(minWidth: 110)
                .padding(.vertical, 3)
                .padding(.horizontal, 8)
                .background(RoundedRectangle(cornerRadius: 6).strokeBorder(recording ? Color.accentColor : .secondary.opacity(0.4)))
            Button(recording ? "Cancel" : "Record") {
                recording ? stop() : start()
            }
            .disabled(settings.isRecordingShortcut && !recording)
            if shortcut != defaultShortcut && !recording {
                Button("Reset") { shortcut = defaultShortcut }
            }
        }
        .onDisappear(perform: stop)
    }

    private func start() {
        recording = true
        settings.isRecordingShortcut = true
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            if event.keyCode == 53 { // Escape
                stop()
            } else if let recorded = HotKeyShortcut(event: event) {
                shortcut = recorded
                print("settings: shortcut → \(recorded.displayString)")
                stop()
            } else {
                NSSound.beep() // needs ⌘, ⌥ or ⌃
            }
            return nil
        }
    }

    private func stop() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        guard recording else { return }
        recording = false
        settings.isRecordingShortcut = false
    }
}

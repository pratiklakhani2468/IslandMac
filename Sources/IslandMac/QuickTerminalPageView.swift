import SwiftUI

/// Quick Terminal: a command field (opened by its hotkey) with the transcript beneath it, inside
/// the island surface. Return runs; ↑/↓ step through history; ⌃C or Stop interrupts; Escape
/// dismisses a question, then closes. Like Quick Ask, it's just the field until something runs.
struct QuickTerminalPageView: View {
    @ObservedObject var terminal: QuickTerminal
    @ObservedObject var status: TerminalStatus
    let onClose: () -> Void
    @FocusState private var focused: Bool
    @State private var copied = false

    private typealias L = TerminalLayout
    private static let bottom = "bottom"

    var body: some View {
        VStack(spacing: 0) {
            field
            if status.expanded {
                Rectangle().fill(Ink.separator).frame(height: 0.5)
                    .transition(.opacity)
                transcript
                    .transition(.opacity)
                if terminal.prompt != .none {
                    promptCard
                        .padding(.bottom, L.cardBottomPadding)
                        .transition(.opacity.combined(with: .offset(y: 6)))
                }
            } else {
                Spacer(minLength: 0)
            }
        }
        .padding(.horizontal, L.horizontalPadding)
        .animation(.easeOut(duration: 0.18), value: terminal.prompt)
        .onAppear {
            // The panel becomes key as this page opens; focus the field once it has.
            DispatchQueue.main.async { focused = true }
        }
    }

    // MARK: Field

    private var field: some View {
        HStack(spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 7) {
                Image(systemName: "terminal")
                    .font(.system(size: L.fieldIconSize, weight: .semibold))
                    .foregroundStyle(Ink.secondary)
                Text(terminal.folderLabel)
                    .font(L.mono(L.fieldTextSize, weight: .medium))
                    .foregroundStyle(Ink.secondary)
                    .lineLimit(1)
                    .truncationMode(.head)
                    .frame(maxWidth: L.folderMaxWidth, alignment: .leading)
                    .fixedSize(horizontal: true, vertical: false)
                    .help(terminal.directory)
                Text("❯")
                    .font(L.mono(L.fieldTextSize, weight: .semibold))
                    .foregroundStyle(Ink.tertiary)
                TextField("", text: $terminal.input,
                          prompt: Text(status.isRunning ? "Running… ⌃C to stop" : "Type or paste a command").foregroundStyle(Ink.tertiary))
                    .textFieldStyle(.plain)
                    .font(L.mono(L.fieldTextSize))
                    .foregroundStyle(Ink.primary)
                    .tint(.white)
                    .focused($focused)
                    .onSubmit { terminal.submit() }
                    .onKeyPress(.upArrow) { terminal.historyBack(); return .handled }
                    .onKeyPress(.downArrow) { terminal.historyForward(); return .handled }
                    .onKeyPress(keys: ["c"]) { press in
                        guard press.modifiers.contains(.control), terminal.isRunning else { return .ignored }
                        terminal.stop()
                        return .handled
                    }
                    .onExitCommand { if !terminal.dismissPrompt() { onClose() } }
                    .offset(y: FileSearchLayout.textNudge)
            }
            controls
        }
        .frame(height: L.fieldHeight)
        // Centre the row in the field-only pill, as Quick Ask does.
        .offset(y: L.fieldCenteringOffset)
    }

    @ViewBuilder
    private var controls: some View {
        if status.isRunning {
            Button { terminal.stop() } label: { CapsuleLabel(title: "Stop") }
                .buttonStyle(PressScaleStyle())
                .help("Interrupt the command (⌃C)")
                .transition(.opacity)
        } else if !terminal.lines.isEmpty {
            HStack(spacing: 0) {
                GlyphButton(symbol: copied ? "checkmark" : "doc.on.doc", help: "Copy output") {
                    terminal.copyOutput()
                    copied = true
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { copied = false }
                }
                GlyphButton(symbol: "eraser", help: "Clear") { terminal.clear() }
            }
            .transition(.opacity)
        }
    }

    // MARK: Transcript

    private var transcript: some View {
        ScrollViewReader { proxy in
            ScrollView(.vertical) {
                LazyVStack(alignment: .leading, spacing: L.lineSpacing) {
                    ForEach(terminal.lines) { line in
                        TerminalLineView(line: line)
                    }
                    Color.clear.frame(height: 1).id(Self.bottom)
                }
                .padding(.vertical, L.transcriptPadding)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .scrollIndicators(.automatic)
            .onChange(of: terminal.revision) { proxy.scrollTo(Self.bottom, anchor: .bottom) }
            .onChange(of: terminal.prompt) { proxy.scrollTo(Self.bottom, anchor: .bottom) }
            .onAppear { proxy.scrollTo(Self.bottom, anchor: .bottom) }
        }
        .frame(maxHeight: .infinity)
    }

    // MARK: Questions

    @ViewBuilder
    private var promptCard: some View {
        switch terminal.prompt {
        case .none:
            EmptyView()
        case .confirm(let command, let reason, let highlight):
            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(Color.orange)
                    Text(reason).foregroundStyle(Ink.primary).fixedSize(horizontal: false, vertical: true)
                }
                .font(.system(size: 12, weight: .medium))
                Text(Self.highlighted(command, highlight))
                    .font(L.mono(L.textSize))
                    .foregroundStyle(Ink.primary)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(8)
                    .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(Color.white.opacity(0.06)))
                HStack(spacing: 8) {
                    Text("Run it anyway?").font(.system(size: 11)).foregroundStyle(Ink.tertiary)
                    Spacer()
                    Button { terminal.dismissPrompt() } label: { CapsuleLabel(title: "Cancel") }
                        .buttonStyle(PressScaleStyle())
                    Button { terminal.confirm() } label: { DestructiveCapsule(title: "Run") }
                        .buttonStyle(PressScaleStyle())
                }
            }
            .modifier(CardStyle(tint: Color.orange))
        case .needsTerminal(let command, let reason):
            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: "macwindow")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(Ink.secondary)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Needs a full terminal").font(.system(size: 12.5, weight: .semibold)).foregroundStyle(Ink.primary)
                        Text(reason).font(.system(size: 11)).foregroundStyle(Ink.secondary).fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: 4)
                    GlyphButton(symbol: "xmark", help: "Dismiss") { terminal.dismissPrompt() }
                }
                HStack(spacing: 8) {
                    Text(command)
                        .font(L.mono(L.textSize))
                        .foregroundStyle(Ink.primary)
                        .lineLimit(2)
                        .truncationMode(.middle)
                        .textSelection(.enabled)
                    Spacer(minLength: 8)
                    Button { terminal.openInTerminal() } label: { CapsuleLabel(title: "Open in Terminal") }
                        .buttonStyle(PressScaleStyle())
                        .help("Opens Terminal in \(terminal.folderLabel) with the command typed in, ready to run")
                }
            }
            .modifier(CardStyle(tint: Color.white))
        }
    }

    /// The command with its risky part marked.
    private static func highlighted(_ command: String, _ range: Range<Int>) -> AttributedString {
        var text = AttributedString(command)
        let characters = text.characters
        let lower = min(max(range.lowerBound, 0), characters.count), upper = min(max(range.upperBound, lower), characters.count)
        let start = characters.index(characters.startIndex, offsetBy: lower)
        let end = characters.index(characters.startIndex, offsetBy: upper)
        text[start..<end].backgroundColor = Color.orange.opacity(0.28)
        text[start..<end].foregroundColor = Color(red: 1, green: 0.82, blue: 0.6)
        return text
    }
}

private struct TerminalLineView: View {
    let line: QuickTerminal.Line

    private typealias L = TerminalLayout

    var body: some View {
        switch line.kind {
        case .command(let folder):
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(folder).foregroundStyle(Ink.secondary)
                Text("❯").foregroundStyle(Ink.tertiary)
                Text(line.text).foregroundStyle(Ink.primary).fontWeight(.semibold)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .font(L.mono(L.textSize))
            .textSelection(.enabled)
            .padding(.top, L.commandTopPadding)
        case .stdout, .stderr:
            Text(line.text.characters.isEmpty ? AttributedString(" ") : line.text)
                .font(L.mono(L.textSize))
                .foregroundStyle(Ink.primary)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        case .status(let outcome):
            HStack(spacing: 5) {
                Image(systemName: outcome.succeeded ? "checkmark" : "xmark")
                    .font(.system(size: 9.5, weight: .bold))
                Text(Self.label(outcome, String(line.text.characters)))
            }
            .font(L.mono(L.statusTextSize, weight: .medium))
            .foregroundStyle(TerminalLayout.color(for: outcome))
            .padding(.top, 2)
        case .notice:
            Text(line.text)
                .font(.system(size: L.statusTextSize + 0.5))
                .foregroundStyle(Ink.tertiary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 2)
        }
    }

    private static func label(_ outcome: QuickTerminal.Outcome, _ duration: String) -> String {
        let time = duration.isEmpty ? "" : " · \(duration)"
        return switch outcome {
        case .success: "done\(time)"
        case .failure(let code): "exit \(code)\(time)"
        case .stopped: "stopped\(time)"
        }
    }
}

private struct CardStyle: ViewModifier {
    let tint: Color

    func body(content: Content) -> some View {
        content
            .padding(10)
            .background(RoundedRectangle(cornerRadius: TerminalLayout.cardRadius, style: .continuous).fill(Color.white.opacity(0.07)))
            .overlay(RoundedRectangle(cornerRadius: TerminalLayout.cardRadius, style: .continuous).strokeBorder(tint.opacity(0.3), lineWidth: 0.5))
    }
}

/// A capsule button label for a destructive choice.
private struct DestructiveCapsule: View {
    let title: String

    var body: some View {
        Text(title)
            .font(.system(size: ControlLayout.capsuleTextSize, weight: .semibold))
            .foregroundStyle(.white)
            .padding(.horizontal, ControlLayout.capsulePadding + 2)
            .frame(height: ControlLayout.capsuleHeight)
            .background(Capsule().fill(Color(red: 0.78, green: 0.2, blue: 0.18)))
            .contentShape(Capsule())
    }
}

/// In the pill while a command runs with the island closed: a small turning arc.
struct TerminalSpinner: View {
    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30)) { context in
            let turn = context.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 0.9) / 0.9
            Circle()
                .trim(from: 0, to: 0.7)
                .stroke(Ink.primary, style: StrokeStyle(lineWidth: TerminalLayout.spinnerLineWidth, lineCap: .round))
                .frame(width: TerminalLayout.spinnerSize, height: TerminalLayout.spinnerSize)
                .rotationEffect(.degrees(turn * 360))
        }
        .help("A Quick Terminal command is running")
    }
}

/// The brief moment when a command finishes while the island is closed: "Done ✓" or "Failed ✕".
struct TerminalResultView: View {
    @ObservedObject var status: TerminalStatus
    @State private var bounce = false

    var body: some View {
        let outcome = status.lastResult?.outcome ?? .success
        HStack(spacing: 7) {
            Text(Self.title(outcome))
                .font(.system(size: 12.5, weight: .semibold))
                .foregroundStyle(Ink.primary)
            Image(systemName: outcome.succeeded ? "checkmark.circle.fill" : "xmark.circle.fill")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(TerminalLayout.color(for: outcome))
                .symbolEffect(.bounce, value: bounce)
            Text(status.lastResult?.command ?? "")
                .font(TerminalLayout.mono(11))
                .foregroundStyle(Ink.tertiary)
                .lineLimit(1)
                .truncationMode(.tail)
        }
        .padding(.horizontal, TerminalLayout.resultPadding)
        .onAppear { bounce.toggle() }
    }

    private static func title(_ outcome: QuickTerminal.Outcome) -> String {
        switch outcome {
        case .success: "Done"
        case .failure: "Failed"
        case .stopped: "Stopped"
        }
    }
}

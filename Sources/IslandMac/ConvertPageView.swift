import SwiftUI

/// Convert: the files dropped on the island as a "ticket" (thumbnail, name, details) and keycaps
/// for what can be done to them; a keycap that needs a setting opens its choices in place. While
/// it works, a dotted track runs from the source format to the target; when it's done the target
/// lands as a stamp and the ticket becomes the new file. Number keys press the keycaps; Escape
/// steps back from choices, then closes.
struct ConvertPageView: View {
    @ObservedObject var converter: Converter
    @FocusState private var focused: Bool
    @State private var appeared = false

    private typealias L = ConvertLayout

    var body: some View {
        let accent = converter.kind.accent
        VStack(alignment: .leading, spacing: 0) {
            ConvertTicket(converter: converter, accent: accent)
                .frame(height: L.ticketHeight)
                .opacity(appeared ? 1 : 0)
                .offset(y: appeared ? 0 : -8)
            Color.clear.frame(height: L.sectionGap)
            Group {
                switch converter.phase {
                case .idle, .choosing:
                    choosing(accent: accent)
                        .transition(.asymmetric(insertion: .opacity.combined(with: .offset(y: 6)), removal: .opacity))
                case .working:
                    ConvertWorkingView(converter: converter, progress: converter.progress, accent: accent)
                        .transition(.asymmetric(insertion: .opacity.combined(with: .offset(y: 8)), removal: .opacity))
                case .done:
                    done(accent: accent)
                        .transition(.asymmetric(insertion: .opacity.combined(with: .scale(scale: 0.96, anchor: .top)), removal: .opacity))
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, L.horizontalPadding)
        .padding(.top, L.topPadding)
        .animation(.spring(response: 0.34, dampingFraction: 0.86), value: converter.phase)
        .animation(.spring(response: 0.3, dampingFraction: 0.84), value: converter.choosing)
        .animation(.easeOut(duration: 0.16), value: converter.hint)
        // The page itself takes the keys: numbers, Escape, Return.
        .focusable()
        .focusEffectDisabled()
        .focused($focused)
        .onKeyPress(characters: .decimalDigits) { press in
            guard let number = Int(press.characters) else { return .ignored }
            return converter.pressNumber(number) ? .handled : .ignored
        }
        .onExitCommand {
            if !converter.closeChoices() { converter.close() }
        }
        .onKeyPress(.return) {
            guard converter.phase == .done else { return .ignored }
            converter.showInFinder()
            return .handled
        }
        .onAppear {
            withAnimation(.spring(response: 0.4, dampingFraction: 0.8).delay(0.05)) { appeared = true }
            // The panel becomes key as this page opens; take the keys once it has.
            DispatchQueue.main.async { focused = true }
        }
        .onChange(of: converter.phase) { focused = true }
    }

    // MARK: Choosing

    @ViewBuilder
    private func choosing(accent: Color) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            if let message = converter.unsupportedMessage {
                HStack(spacing: 7) {
                    Image(systemName: "questionmark.square.dashed")
                        .font(.system(size: 13, weight: .semibold))
                    Text(message)
                        .font(.system(size: 12, weight: .medium))
                }
                .foregroundStyle(Ink.secondary)
                .frame(height: L.keyHeight)
            } else if let open = converter.choosing, case .choose(let choices) = open.kind {
                ChoiceStrip(title: open.title, choices: choices, accent: accent, back: { converter.closeChoices() }) { converter.pick($0) }
                    .frame(height: L.keyHeight)
                    .transition(.asymmetric(insertion: .opacity.combined(with: .offset(x: 14)), removal: .opacity))
            } else {
                KeyGrid(buttons: converter.buttons, accent: accent, appeared: appeared) { converter.press($0) }
                    .transition(.asymmetric(insertion: .opacity.combined(with: .offset(x: -14)), removal: .opacity))
            }
            if let hint = converter.hint {
                HStack(alignment: .firstTextBaseline, spacing: 5) {
                    Image(systemName: hint.style == .error ? "arrow.uturn.left" : "checkmark.seal")
                        .font(.system(size: 9.5, weight: .bold))
                    Text(hint.text)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(hint.style == .error ? Color(red: 1, green: 0.66, blue: 0.5) : Ink.secondary)
                .help(hint.text)
                .padding(.top, L.hintTopPadding)
                .frame(height: L.hintHeight, alignment: .top)
                .transition(.opacity.combined(with: .offset(y: -3)))
            }
        }
    }

    // MARK: Done

    private func done(accent: Color) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: L.keySpacing) {
                FormatStamp(text: converter.job?.to ?? "", accent: accent)
                if converter.outputs.count > 1 {
                    Text("× \(converter.outputs.count)").font(L.mono(11, weight: .semibold)).foregroundStyle(Ink.secondary)
                }
                Spacer(minLength: 6)
                KeyCap(title: "Again", accent: accent) { converter.again() }
                    .help("Convert the same file another way")
                KeyCap(title: "Show in Finder", accent: accent, prominent: true) { converter.showInFinder() }
                    .help("Reveal the new file (Return)")
            }
            .frame(height: L.keyHeight)
            if let note = converter.note {
                Text(note)
                    .font(.system(size: 10.5))
                    .foregroundStyle(Ink.tertiary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .help(note)
                    .padding(.top, 5)
                    .frame(height: L.noteHeight, alignment: .top)
            }
        }
    }
}

// MARK: - Ticket

/// The file (or, when done, the new file): a tinted thumbnail tile with its format on a tab, the
/// name and a line of details.
private struct ConvertTicket: View {
    @ObservedObject var converter: Converter
    let accent: Color

    private typealias L = ConvertLayout

    var body: some View {
        let done = converter.phase == .done
        HStack(spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: L.tileRadius, style: .continuous).fill(accent.opacity(0.14))
                if let thumbnail = converter.thumbnail {
                    Image(nsImage: thumbnail).resizable().aspectRatio(contentMode: .fill)
                } else {
                    Image(systemName: converter.kind.symbol)
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundStyle(accent)
                }
            }
            .frame(width: L.tileSize, height: L.tileSize)
            .clipShape(RoundedRectangle(cornerRadius: L.tileRadius, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: L.tileRadius, style: .continuous).strokeBorder(accent.opacity(0.5), lineWidth: 1))
            .overlay(alignment: .bottomTrailing) {
                Text(tab)
                    .font(L.mono(7.5, weight: .heavy))
                    .foregroundStyle(.black)
                    .padding(.horizontal, 4)
                    .frame(height: 13)
                    .background(RoundedRectangle(cornerRadius: 4, style: .continuous).fill(accent))
                    .offset(x: 7, y: 5)
                    .contentTransition(.numericText())
            }
            .padding(.trailing, 4)

            VStack(alignment: .leading, spacing: 3) {
                Text(name)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Ink.primary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(done ? converter.resultLine : converter.details)
                    .font(L.mono(10.5))
                    .foregroundStyle(done && converter.resultShrank ? L.shrankColor : Ink.secondary)
                    .lineLimit(1)
            }
            .id(done)
            .transition(.asymmetric(insertion: .offset(y: 10).combined(with: .opacity), removal: .offset(y: -10).combined(with: .opacity)))
            Spacer(minLength: 6)
            if converter.phase == .choosing {
                Button { converter.keepInShelf() } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "tray.and.arrow.down")
                        Text("Keep in shelf")
                    }
                    .font(.system(size: 10.5, weight: .medium))
                    .foregroundStyle(Ink.secondary)
                    .padding(.horizontal, 7)
                    .frame(height: 20)
                    .background(Capsule().fill(Color.white.opacity(0.06)))
                    .contentShape(Capsule())
                }
                .buttonStyle(PressScaleStyle())
                .help("Put it in the Dropped Files shelf instead")
                .transition(.opacity)
            }
            if !converter.isWorking {
                GlyphButton(symbol: "xmark", help: "Close (Esc)") { converter.close() }
                    .transition(.opacity)
            }
        }
        .animation(.spring(response: 0.38, dampingFraction: 0.82), value: done)
    }

    private var name: String {
        if converter.phase == .done, let first = converter.outputs.first {
            return first.url.lastPathComponent
        }
        guard let first = converter.items.first else { return "" }
        return converter.items.count > 1 ? "\(first.name)  +\(converter.items.count - 1)" : first.name
    }

    private var tab: String {
        if converter.phase == .done, let job = converter.job { return job.to }
        let ext = converter.primary?.url.pathExtension.uppercased() ?? ""
        return ext.isEmpty ? (converter.kind == .folder ? "DIR" : "FILE") : String(ext.prefix(4))
    }
}

// MARK: - Keycaps

/// A converter choice drawn as a key: a face over a darker base that it presses into.
private struct KeyCap: View {
    let title: String
    var number: Int? = nil
    let accent: Color
    var prominent = false
    /// Fill the width it's given (grid cells) instead of hugging the title.
    var stretches = false
    var isEnabled = true
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(ConvertLayout.mono(11.5, weight: .semibold))
                .lineLimit(1)
                .fixedSize()
                .padding(.horizontal, ConvertLayout.keyPadding)
                .padding(.trailing, number == nil ? 0 : 3)
                .frame(maxWidth: stretches ? .infinity : nil)
        }
        .buttonStyle(KeyCapStyle(accent: accent, prominent: prominent, hovering: hovering && isEnabled, number: number))
        .disabled(!isEnabled)
        .opacity(isEnabled ? 1 : 0.35)
        .onHover { hovering = $0 }
    }
}

/// The buttons in even columns: up to three in a row, two by two for four, three then two for five.
private struct KeyGrid: View {
    let buttons: [ActionButton]
    let accent: Color
    let appeared: Bool
    let press: (ActionButton) -> Void

    private typealias L = ConvertLayout

    var body: some View {
        let columns = L.columns(for: buttons.count)
        let rows = stride(from: 0, to: buttons.count, by: columns).map { Array(buttons.indices[$0..<min($0 + columns, buttons.count)]) }
        VStack(spacing: L.rowGap) {
            ForEach(rows, id: \.self) { row in
                HStack(spacing: L.keySpacing) {
                    ForEach(row, id: \.self) { index in
                        let button = buttons[index]
                        KeyCap(title: button.title + (isChoice(button) ? " …" : ""), number: index + 1, accent: accent, stretches: true) { press(button) }
                            .opacity(appeared ? 1 : 0)
                            .offset(y: appeared ? 0 : 7)
                            .animation(.spring(response: 0.36, dampingFraction: 0.72).delay(0.1 + 0.05 * Double(index)), value: appeared)
                    }
                    // Keep the columns even on a short last row.
                    ForEach(0..<(columns - row.count), id: \.self) { _ in Color.clear.frame(maxWidth: .infinity) }
                }
                .frame(height: L.keyHeight)
            }
        }
    }

    private func isChoice(_ button: ActionButton) -> Bool {
        if case .choose = button.kind { return true }
        return false
    }
}

/// A button's choices in its place: "‹ Compress" to go back, then Light · Medium · Strong.
private struct ChoiceStrip: View {
    let title: String
    let choices: [ActionChoice]
    let accent: Color
    let back: () -> Void
    let pick: (ActionChoice) -> Void

    var body: some View {
        HStack(spacing: ConvertLayout.keySpacing) {
            Button(action: back) {
                HStack(spacing: 4) {
                    Image(systemName: "chevron.left").font(.system(size: 9.5, weight: .bold))
                    Text(title).font(.system(size: 11.5, weight: .semibold))
                }
                .foregroundStyle(accent)
                .padding(.trailing, 4)
                .contentShape(Rectangle())
            }
            .buttonStyle(PressScaleStyle())
            .help("Back (Esc)")
            ForEach(Array(choices.enumerated()), id: \.element.id) { index, choice in
                KeyCap(title: choice.title, number: index + 1, accent: accent, stretches: true, isEnabled: choice.isEnabled) { pick(choice) }
                    .help(choice.isEnabled ? "" : "The video is already this size or smaller")
            }
        }
    }
}

private struct KeyCapStyle: ButtonStyle {
    let accent: Color
    let prominent: Bool
    let hovering: Bool
    let number: Int?

    func makeBody(configuration: Configuration) -> some View {
        let pressed = configuration.isPressed
        let depth = ConvertLayout.keyDepth
        let face: Color = prominent ? .white : hovering ? accent.opacity(0.24) : Color.white.opacity(0.11)
        configuration.label
            .foregroundStyle(prominent ? Color.black : Ink.primary)
            .frame(height: ConvertLayout.keyHeight - depth)
            .background(alignment: .topTrailing) {
                if let number {
                    Text("\(number)")
                        .font(ConvertLayout.mono(7.5, weight: .bold))
                        .foregroundStyle(prominent ? Color.black.opacity(0.4) : Ink.tertiary)
                        .padding(.top, 3)
                        .padding(.trailing, 4)
                }
            }
            .background(RoundedRectangle(cornerRadius: ConvertLayout.keyRadius, style: .continuous).fill(face))
            .overlay(RoundedRectangle(cornerRadius: ConvertLayout.keyRadius, style: .continuous)
                .strokeBorder(hovering && !prominent ? accent.opacity(0.6) : Color.white.opacity(prominent ? 0 : 0.07), lineWidth: 1))
            .offset(y: pressed ? depth : 0)
            .frame(height: ConvertLayout.keyHeight, alignment: .top)
            .background(alignment: .bottom) {
                RoundedRectangle(cornerRadius: ConvertLayout.keyRadius, style: .continuous)
                    .fill(prominent ? Color.white.opacity(0.45) : Color.white.opacity(0.05))
                    .frame(height: ConvertLayout.keyHeight - depth)
            }
            .contentShape(Rectangle())
            .animation(.spring(response: 0.16, dampingFraction: 0.6), value: pressed)
            .animation(.easeOut(duration: 0.12), value: hovering)
    }
}

// MARK: - Working

/// From the source format to the target along a track of dots: lit up to the progress, with a
/// breathing head and a comet gliding along the lit part; when it can't tell how far along it
/// is, the comet sweeps the whole track.
private struct ConvertWorkingView: View {
    @ObservedObject var converter: Converter
    @ObservedObject var progress: ConvertProgress
    let accent: Color

    private typealias L = ConvertLayout

    var body: some View {
        VStack(alignment: .leading, spacing: L.statusGap) {
            HStack(spacing: 10) {
                FormatTag(text: converter.job?.from ?? "", accent: accent, lit: false)
                DotTrack(fraction: progress.fraction, accent: accent)
                FormatTag(text: converter.job?.to ?? "", accent: accent, lit: (progress.fraction ?? 0) >= 0.999)
            }
            .frame(height: L.trackHeight)
            HStack(spacing: 6) {
                Text(status)
                    .font(L.mono(10.5))
                    .foregroundStyle(Ink.secondary)
                    .contentTransition(.numericText())
                    .lineLimit(1)
                Spacer(minLength: 6)
                Button { converter.cancel() } label: {
                    Text("Cancel")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(Ink.secondary)
                        .contentShape(Rectangle())
                }
                .buttonStyle(PressScaleStyle())
                .help("Stop; nothing is saved")
            }
            .frame(height: L.statusHeight)
        }
    }

    private var status: String {
        var parts: [String] = [progress.fraction.map { "\(Int(($0 * 100).rounded(.down)))%" } ?? "working…"]
        if let summary = converter.job?.summary, !summary.isEmpty { parts.append(summary) }
        if let step = progress.step { parts.append(step) }
        return parts.joined(separator: " · ")
    }
}

private struct DotTrack: View {
    let fraction: Double?
    let accent: Color

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30)) { context in
            let t = context.date.timeIntervalSinceReferenceDate
            Canvas { canvas, size in
                let count = ConvertLayout.dotCount
                let step = size.width / CGFloat(count)
                let y = size.height / 2
                func dot(_ x: CGFloat, _ radius: CGFloat, _ color: Color) {
                    canvas.fill(Path(ellipseIn: CGRect(x: x - radius, y: y - radius, width: radius * 2, height: radius * 2)), with: .color(color))
                }
                let lit = fraction.map { $0 * Double(count) }
                for i in 0..<count {
                    let x = step * (CGFloat(i) + 0.5)
                    if let lit {
                        if Double(i) + 1 <= lit {
                            dot(x, 2.1, accent)
                        } else if Double(i) < lit || (i == 0 && lit == 0) {
                            let breath = (sin(t * 5.5) + 1) / 2
                            dot(x, 2 + 1.5 * breath, accent.opacity(0.55 + 0.45 * breath))
                        } else {
                            dot(x, 1.5, Color.white.opacity(0.14))
                        }
                    } else {
                        let head = t.truncatingRemainder(dividingBy: 1.5) / 1.5 * Double(count + 8) - 4
                        let behind = head - Double(i)
                        if behind >= 0, behind < 6 {
                            let k = 1 - behind / 6
                            dot(x, 1.5 + 1.3 * k, accent.opacity(0.2 + 0.8 * k))
                        } else {
                            dot(x, 1.5, Color.white.opacity(0.14))
                        }
                    }
                }
                // The comet: glides from the start to the lit head, again and again.
                if let lit, lit > 1 {
                    let cycle = t.truncatingRemainder(dividingBy: 1.1) / 1.1
                    let x = step * CGFloat(cycle * lit)
                    dot(x, 4.5, accent.opacity(0.28 * (1 - cycle)))
                }
            }
        }
    }
}

/// A format in the track: the source as an outline, the target as a dashed outline that fills
/// when the work is done.
private struct FormatTag: View {
    let text: String
    let accent: Color
    let lit: Bool

    var body: some View {
        Text(text)
            .font(ConvertLayout.mono(10.5, weight: .bold))
            .foregroundStyle(lit ? Color.black : Ink.primary)
            .padding(.horizontal, 7)
            .frame(height: 20)
            .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(lit ? accent : Color.clear))
            .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous)
                .strokeBorder(lit ? Color.clear : Ink.quaternary, style: StrokeStyle(lineWidth: 1, dash: text.isEmpty ? [] : [3, 2])))
            .fixedSize()
            .animation(.spring(response: 0.3, dampingFraction: 0.7), value: lit)
    }
}

/// The target format landing on the result: dropped from above, a little turned, settling flat.
private struct FormatStamp: View {
    let text: String
    let accent: Color
    @State private var landed = false

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: "checkmark")
                .font(.system(size: 9.5, weight: .black))
            Text(text)
                .font(ConvertLayout.mono(11, weight: .heavy))
        }
        .foregroundStyle(.black)
        .padding(.horizontal, 9)
        .frame(height: 22)
        .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(accent))
        .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous).strokeBorder(Color.black.opacity(0.25), lineWidth: 1).padding(2))
        .scaleEffect(landed ? 1 : 1.7)
        .rotationEffect(.degrees(landed ? -3 : -16))
        .opacity(landed ? 1 : 0)
        .onAppear {
            withAnimation(.spring(response: 0.32, dampingFraction: 0.52).delay(0.08)) { landed = true }
        }
    }
}

extension FileKind {
    /// Each kind of file has its own tint in the converter.
    var accent: Color {
        switch self {
        case .video: Color(red: 1.0, green: 0.53, blue: 0.41)
        case .image, .animatedGIF: Color(red: 0.38, green: 0.87, blue: 0.74)
        case .audio: Color(red: 0.71, green: 0.6, blue: 1.0)
        case .pdf: Color(red: 1.0, green: 0.47, blue: 0.58)
        case .document: Color(red: 1.0, green: 0.79, blue: 0.38)
        case .folder, .other: Color(white: 0.72)
        }
    }

    var symbol: String {
        switch self {
        case .video: "film"
        case .image: "photo"
        case .animatedGIF: "photo.stack"
        case .audio: "waveform"
        case .pdf: "doc.richtext"
        case .document: "doc.text"
        case .folder: "folder"
        case .other: "doc"
        }
    }
}

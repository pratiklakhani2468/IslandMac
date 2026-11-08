import SwiftUI

/// A battery drawn to the exact charge level (SF Symbols only come in quarter steps), with an
/// optional mark: a bolt while charging, a plug when on power but not charging. `whiteness` fades the fill toward white, for a glyph sitting on a
/// coloured pill that ends up on the black surface (as the low-battery pill expands).
struct BatteryGlyph: View {
    /// 0…1.
    let level: Double
    let color: Color
    var mark: Mark = .none
    var whiteness: Double = 0
    /// Charging: the fill grows from empty to `level` as the glyph appears.
    var fillsIn = false
    @State private var filled = false

    enum Mark: Equatable { case none, bolt, plug }

    private typealias L = BatteryLayout

    var body: some View {
        let fraction = min(max(fillsIn && !filled ? 0 : level, 0), 1)
        let inner = L.bodyWidth - 2 * L.fillInset
        HStack(spacing: L.capGap) {
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: L.bodyRadius, style: .continuous)
                    .strokeBorder(Ink.secondary, lineWidth: L.outlineWidth)
                // Never thinner than a sliver, so an almost-empty battery still reads as having charge.
                let width = fraction > 0 ? max(inner * fraction, 2) : 0
                ZStack {
                    color
                    Color.white.opacity(whiteness)
                }
                .frame(width: width, height: L.bodyHeight - 2 * L.fillInset)
                .clipShape(RoundedRectangle(cornerRadius: L.fillRadius, style: .continuous))
                .padding(.leading, L.fillInset)
            }
            .frame(width: L.bodyWidth, height: L.bodyHeight)
            .overlay {
                if let symbol = mark == .bolt ? "bolt.fill" : mark == .plug ? "powerplug.fill" : nil {
                    // A black outline keeps the mark legible over any fill.
                    ZStack {
                        Image(systemName: symbol).font(.system(size: L.boltSize + 3, weight: .black)).foregroundStyle(.black)
                        Image(systemName: symbol).font(.system(size: L.boltSize, weight: .black)).foregroundStyle(.white)
                    }
                }
            }
            RoundedRectangle(cornerRadius: 1, style: .continuous)
                .fill(Ink.secondary)
                .frame(width: L.capWidth, height: L.capHeight)
        }
        .onAppear {
            guard fillsIn else { return }
            withAnimation(L.fillAnimation) { filled = true }
        }
    }
}

/// The `.power` moment: plugged in (charging with time to full, or held by optimized charging),
/// unplugged (time left), or fully charged. Reads the live snapshot, so an estimate that arrives
/// while it's showing appears in place. Charging leaves the time to full out until macOS has it;
/// the time (to full, or left on battery) is simply left out until macOS has it.
struct PowerFeedbackView: View {
    @ObservedObject var power: PowerSource

    private typealias L = BatteryLayout

    var body: some View {
        if let s = power.snapshot {
            let content = Self.content(for: power.feedback, s, awaitingCharge: power.awaitingCharge)
            HStack(spacing: 0) {
                HStack(alignment: .firstTextBaseline, spacing: 5) {
                    Text(content.title)
                        .font(.system(size: L.feedbackTitleSize, weight: .semibold))
                        .foregroundStyle(Ink.primary)
                    if let detail = content.detail {
                        Text("· \(detail)")
                            .font(.system(size: L.feedbackTitleSize, weight: .medium).monospacedDigit())
                            .foregroundStyle(Ink.secondary)
                            .transition(.opacity)
                    }
                }
                .lineLimit(1)
                Spacer(minLength: 10)
                if content.showsPercent {
                    Text("\(s.percent)%")
                        .font(.system(size: L.feedbackTitleSize, weight: .semibold).monospacedDigit())
                        .foregroundStyle(content.accent ?? Ink.primary)
                        .contentTransition(.numericText())
                        .padding(.trailing, L.feedbackPercentToGlyph)
                }
                BatteryGlyph(level: Double(s.percent) / 100, color: content.accent ?? Ink.primary,
                             mark: content.mark, fillsIn: content.mark == .bolt)
                    // A new moment, or "Plugged in" becoming "Charging", redraws the glyph fresh (so
                    // the charging fill plays when charging actually starts).
                    .id("\(power.feedback)-\(content.mark)")
            }
            .padding(.horizontal, L.feedbackPadding)
            .animation(.easeOut(duration: 0.2), value: content)
        }
    }

    struct Content: Equatable {
        var title: String
        var detail: String?
        var accent: Color?
        var mark: BatteryGlyph.Mark = .none
        var showsPercent = true
    }

    static func content(for feedback: PowerSource.Feedback, _ s: PowerSource.Snapshot, awaitingCharge: Bool) -> Content {
        switch feedback {
        case .charged:
            return Content(title: "Charged", accent: L.chargingColor)
        case .pluggedIn where s.isFull:
            return Content(title: "Charged", accent: L.chargingColor)
        case .pluggedIn where s.isCharging:
            return Content(title: "Charging", detail: PowerSource.fullIn(s.minutesToFull),
                           accent: L.chargingColor, mark: .bolt)
        case .pluggedIn where awaitingCharge:
            // The charger is still negotiating; not yet known whether it will charge or hold.
            return Content(title: "Plugged in", mark: .plug)
        case .pluggedIn:
            // On power but not charging, below full: optimized charging (or a manual limit) is
            // holding it. The percent is in the title, so it isn't repeated beside the glyph.
            return Content(title: "Paused at \(s.percent)%", mark: .plug, showsPercent: false)
        case .unplugged:
            let accent: Color? = s.percent <= PowerSource.criticalPercent ? L.criticalColor
                : s.percent <= PowerSource.lowPercent ? L.lowColor : nil
            return Content(title: "On battery", detail: PowerSource.duration(s.minutesToEmpty).map { "\($0) left" },
                           accent: accent)
        }
    }
}

/// Low battery in the island's home: an amber (20% or less) or red (10% or less) pill with the
/// battery and its percentage; expanded, the idle layout with that status in the header (Quick
/// Launch and the page buttons are laid out by HomeLayer, as for the clock).
///
/// Laid out from the surface's live size (`t` = 0 pill … 1 expanded): the glyph and percentage glide
/// from the pill into the header as one group, the pill's colour clears early, and the detail
/// ("Low battery · 1h 5m left") eases in beside them.
struct LowBatteryView: View {
    @ObservedObject var power: PowerSource
    let warning: PowerSource.Warning
    let t: CGFloat
    let width: CGFloat
    let height: CGFloat
    let geometry: IslandGeometry

    private typealias L = BatteryLayout

    var body: some View {
        let top = IslandGeometry.topGap
        let critical = warning == .critical
        let percent = "\(power.snapshot?.percent ?? 0)%"
        let textSize = lerp(L.compactTextSize, QuickLaunchLayout.headerTimeSize, t)
        let textWidth = IdleClockFace.width(of: percent, font: .monospacedDigitSystemFont(ofSize: textSize, weight: .semibold))
        let groupWidth = L.glyphWidth + L.glyphToText + textWidth
        // The group's leading edge: centred in the pill → the header's leading edge.
        let groupX = lerp(geometry.canvasSize.width / 2 - groupWidth / 2, geometry.contentLeading(width: width), t)
        let y = lerp(top + height / 2, top + QuickLaunchLayout.headerCenterY, t)
        let fill = 1 - smoothstep(0, 0.45, t)
        let tone = critical ? L.criticalColor : L.lowColor

        ZStack(alignment: .topLeading) {
            if fill > 0 {
                (critical ? L.criticalFill : L.lowFill).opacity(fill)
            }
            BatteryGlyph(level: Double(power.snapshot?.percent ?? 0) / 100, color: tone, whiteness: fill)
                .position(x: groupX + L.glyphWidth / 2, y: y)
            Text(percent)
                .font(.system(size: textSize, weight: .semibold).monospacedDigit())
                .foregroundStyle(Ink.primary)
                .fixedSize()
                .position(x: groupX + L.glyphWidth + L.glyphToText + textWidth / 2, y: y)
            Text(detail)
                .font(.system(size: QuickLaunchLayout.headerDateSize, weight: .medium).monospacedDigit())
                .foregroundStyle(Ink.secondary)
                .lineLimit(1)
                .fixedSize()
                .frame(height: 20)
                .offset(x: groupX + groupWidth + L.headerPercentToDetail, y: y - 10)
                .opacity(smoothstep(0.55, 0.95, t))
        }
        .frame(width: geometry.canvasSize.width, height: geometry.canvasSize.height, alignment: .topLeading)
    }

    private var detail: String {
        PowerSource.duration(power.snapshot?.minutesToEmpty).map { "Low battery · \($0) left" } ?? "Low battery"
    }
}

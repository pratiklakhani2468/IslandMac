import SwiftUI

/// The drop zone that hangs below the notch while a file is dragged anywhere on screen. Three
/// stages: waiting (a faint dashed target), close by (the zone has grown, the dashes brighten and
/// start to march toward the file), and over it (solid, filled, "Release to drop"). The same view
/// stays up through all three, so nothing restarts as the file moves.
struct DropZoneView: View {
    let stage: IslandState

    private typealias L = DropLayout

    var body: some View {
        let near = stage == .dropNear, over = stage == .dropOver
        // Static SwiftUI: it changes only when the stage does. The moving part (the dashes) is a
        // Core Animation layer animation, so a drag never makes this redraw.
        ZStack {
            RoundedRectangle(cornerRadius: L.targetRadius, style: .continuous)
                .fill(Color.white.opacity(over ? 0.09 : near ? 0.04 : 0.02))
            DashedBorder(marching: near, solid: over, opacity: over ? 0.7 : near ? 0.42 : 0.2,
                         lineWidth: over ? 1.5 : 1.2, radius: L.targetRadius)
            VStack(spacing: 9) {
                ZStack {
                    Circle()
                        .fill(over ? Color.white : Color.white.opacity(near ? 0.14 : 0.08))
                    Image(systemName: over ? "arrow.down" : "arrow.down.to.line")
                        .font(.system(size: 17, weight: .bold))
                        .foregroundStyle(over ? Color.black : Ink.primary)
                        .symbolEffect(.bounce.down, value: over)
                }
                .frame(width: L.badgeSize, height: L.badgeSize)
                .offset(y: near ? 2 : 0)
                VStack(spacing: 3) {
                    Text(over ? "Release to drop" : "Drop here")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(over || near ? Ink.primary : Ink.secondary)
                        .contentTransition(.opacity)
                    Text("Convert it, or keep it in the shelf")
                        .font(.system(size: 11))
                        .foregroundStyle(Ink.tertiary)
                }
            }
            .scaleEffect(over ? 1.04 : near ? 1.02 : 1)
        }
        .padding(L.targetInset)
        .animation(.spring(response: 0.3, dampingFraction: 0.7), value: stage)
    }
}

extension DropZoneView {
    /// Draws each stage once, offscreen, so the symbols, effects and text it uses are loaded
    /// before the first drag (otherwise the first time it appears, and the first time a file is
    /// over it, each cost a frame or two while they load).
    @MainActor
    static func prewarm() {
        for stage in [IslandState.dropApproach, .dropNear, .dropOver] {
            let renderer = ImageRenderer(content: DropZoneView(stage: stage)
                .frame(width: DropLayout.zoneSize.width, height: DropLayout.zoneSize.height)
                .environment(\.colorScheme, .dark))
            _ = renderer.cgImage
        }
    }
}

/// The drop zone's outline as a `CAShapeLayer`: dashed, with the dashes marching by a repeating
/// `lineDashPhase` animation that runs in the render server (no redraws, no main-thread work), or
/// solid. Changes are applied only when a setting actually changes, so the animation never restarts.
private struct DashedBorder: NSViewRepresentable {
    let marching: Bool
    let solid: Bool
    let opacity: Double
    let lineWidth: CGFloat
    let radius: CGFloat

    func makeNSView(context: Context) -> BorderView { BorderView() }

    func updateNSView(_ view: BorderView, context: Context) {
        view.apply(marching: marching, solid: solid, opacity: opacity, lineWidth: lineWidth, radius: radius)
    }

    final class BorderView: NSView {
        private let shape = CAShapeLayer()
        private var radius: CGFloat = 0

        override init(frame: NSRect) {
            super.init(frame: frame)
            wantsLayer = true
            shape.fillColor = nil
            shape.lineCap = .round
            shape.lineDashPattern = [6, 6]
            layer?.addSublayer(shape)
        }

        required init?(coder: NSCoder) { fatalError("not used") }

        // Never in the way of the drop or a click.
        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        override func layout() {
            super.layout()
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            shape.frame = bounds
            let inset = bounds.insetBy(dx: shape.lineWidth / 2, dy: shape.lineWidth / 2)
            let r = min(radius, inset.width / 2, inset.height / 2)
            shape.path = inset.width > 0 && inset.height > 0 ? CGPath(roundedRect: inset, cornerWidth: r, cornerHeight: r, transform: nil) : nil
            CATransaction.commit()
        }

        func apply(marching: Bool, solid: Bool, opacity: Double, lineWidth: CGFloat, radius: CGFloat) {
            CATransaction.begin()
            CATransaction.setAnimationDuration(0.2)
            let color = NSColor.white.withAlphaComponent(opacity).cgColor
            if shape.strokeColor != color { shape.strokeColor = color }
            if shape.lineWidth != lineWidth { shape.lineWidth = lineWidth }
            let pattern: [NSNumber]? = solid ? nil : [6, 6]
            if shape.lineDashPattern != pattern { shape.lineDashPattern = pattern }
            CATransaction.commit()
            if self.radius != radius { self.radius = radius; needsLayout = true }
            let running = shape.animation(forKey: "march") != nil
            if marching, !solid, !running {
                let march = CABasicAnimation(keyPath: "lineDashPhase")
                march.fromValue = 0
                march.toValue = -12
                march.duration = 0.5
                march.repeatCount = .infinity
                shape.add(march, forKey: "march")
            } else if (!marching || solid), running {
                shape.removeAnimation(forKey: "march")
            }
        }
    }
}

/// Brief confirmation after a drop: a check and the file's name (or a count for several files).
struct DropReceivedView: View {
    let files: [URL]

    var body: some View {
        HStack(spacing: DropLayout.iconToText) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: DropLayout.iconSize - 2, weight: .semibold))
                .symbolRenderingMode(.palette)
                .foregroundStyle(.black, .green)
            Text(label)
                .font(.system(size: 12.5, weight: .semibold))
                .foregroundStyle(Ink.primary)
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .padding(.horizontal, DropLayout.confirmationPadding)
    }

    private var label: String {
        guard let first = files.first else { return "File received" }
        return files.count == 1 ? first.lastPathComponent : "\(first.lastPathComponent) +\(files.count - 1)"
    }
}

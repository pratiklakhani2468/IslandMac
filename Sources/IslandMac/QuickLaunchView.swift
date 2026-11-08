import SwiftUI

/// Quick Launch: one centred row of app icons with the hovered app's name beneath: the main content
/// of the expanded idle island, or a smaller row under the music player (`row` preset). Laid out and
/// revealed from the surface's live expansion `t`, so the icons arrive with the morph (from the centre
/// outwards, as the surface grows) and leave with it in reverse.
struct QuickLaunchView: View {
    @ObservedObject var apps: QuickLaunchApps
    @ObservedObject var pointer: IslandPointer
    let row: QuickLaunchLayout.Row
    let t: CGFloat
    let centerX: CGFloat
    let interactive: Bool
    let open: (QuickLaunchApps.App) -> Void

    var body: some View {
        let top = IslandGeometry.topGap
        let list = apps.apps
        let size = row.iconSize, step = size + row.iconSpacing
        let firstX = centerX - (CGFloat(list.count - 1) * step) / 2
        let rowY = top + row.rowCenterY
        // Hover from plain geometry: the icon slot under the pointer (each slot spans half the gap on
        // either side, so moving between icons never passes through "nothing").
        let hoveredIndex: Int? = {
            guard interactive, t > 0.95, let p = pointer.location, abs(p.y - rowY) <= size / 2 + row.iconSpacing / 2 else { return nil }
            let i = Int(((p.x - firstX) / step).rounded())
            return list.indices.contains(i) && abs(p.x - (firstX + CGFloat(i) * step)) <= step / 2 ? i : nil
        }()
        let hovered = hoveredIndex.map { list[$0].id }
        let name = hoveredIndex.map { list[$0].name }
        ZStack(alignment: .topLeading) {
            ForEach(Array(list.enumerated()), id: \.element.id) { index, app in
                // Ring 0 is the middle icon(s), then outwards.
                let ring = (abs(CGFloat(index) - CGFloat(list.count - 1) / 2)).rounded(.down)
                let start = row.revealFrom + ring * QuickLaunchLayout.revealStagger
                let reveal = smoothstep(start, min(1, start + 0.3), t)
                AppIconButton(app: app, size: size, isHovered: hovered == app.id) { open(app) }
                .opacity(reveal)
                .scaleEffect(lerp(0.8, 1, reveal))
                .offset(y: (1 - reveal) * 5)
                .position(x: firstX + CGFloat(index) * step, y: rowY)
            }
            // The hovered app's name, centred under the row.
            Text(name ?? " ")
                .font(.system(size: QuickLaunchLayout.nameSize, weight: .medium))
                .foregroundStyle(Ink.secondary)
                .lineLimit(1)
                .fixedSize()
                .id(name ?? "")
                .transition(.asymmetric(insertion: .opacity.combined(with: .offset(y: 2)), removal: .opacity)
                    .animation(QuickLaunchLayout.nameAnimation))
                .opacity(smoothstep(0.8, 1, t))
                .position(x: centerX, y: top + row.nameCenterY)
        }
        .animation(QuickLaunchLayout.hoverAnimation, value: hovered)
        .allowsHitTesting(interactive)
        .onAppear { apps.refreshIfStale() }
    }
}

private struct AppIconButton: View {
    let app: QuickLaunchApps.App
    let size: CGFloat
    let isHovered: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(nsImage: app.icon)
                .resizable()
                .interpolation(.high)
                .frame(width: size, height: size)
                .opacity(isHovered ? 1 : QuickLaunchLayout.restingIconOpacity)
                .scaleEffect(isHovered ? QuickLaunchLayout.hoverScale : 1)
                .offset(y: isHovered ? -QuickLaunchLayout.hoverLift : 0)
                .contentShape(Rectangle())
        }
        .buttonStyle(PressScaleStyle())
        .help(app.name)
    }
}

import SwiftUI

/// Idle home content's clock: the current time (and date when there's room), in the user's locale
/// and 12/24-hour setting. Updates on each minute boundary; nothing runs in between.
///
/// One continuous face driven by the surface's live expansion `t` (0 pill … 1 expanded) and `detail`
/// (0 at rest, 1 on hover/expanded). In the pill the time is centred (with a short date under it on
/// hover); as the island opens into Quick Launch the same text glides to the header's leading edge
/// and the full date eases in beside it. It is never a large clock.
struct IdleClockView: View {
    let t: CGFloat
    let detail: CGFloat
    let height: CGFloat
    let centerX: CGFloat
    let leading: CGFloat

    var body: some View {
        TimelineView(.everyMinute) { context in
            IdleClockFace(date: context.date, t: t, detail: detail, height: height, centerX: centerX, leading: leading)
        }
    }
}

/// The clock for one moment and one point of the morph. Separate from the timeline so it can be
/// drawn for any date.
struct IdleClockFace: View {
    let date: Date
    let t: CGFloat
    let detail: CGFloat
    /// Live surface height; `centerX` is the canvas centre and `leading` the header's left edge.
    let height: CGFloat
    let centerX: CGFloat
    let leading: CGFloat

    var body: some View {
        let top = IslandGeometry.topGap
        let time = date.formatted(date: .omitted, time: .shortened)
        let timeSize = lerp(lerp(ClockLayout.restingTimeSize, ClockLayout.hoverTimeSize, detail), QuickLaunchLayout.headerTimeSize, t)
        let timeWidth = Self.width(of: time, font: .monospacedDigitSystemFont(ofSize: timeSize, weight: .semibold))
        let pillTimeY = top + height / 2 - ClockLayout.hoverTimeLift * detail
        let headerY = top + QuickLaunchLayout.headerCenterY
        let fullDate = date.formatted(.dateTime.weekday(.wide).month(.wide).day())
        let fullDateWidth = Self.width(of: fullDate, font: .systemFont(ofSize: QuickLaunchLayout.headerDateSize, weight: .medium))
        let timeX = lerp(centerX, leading + timeWidth / 2, t)
        ZStack(alignment: .topLeading) {
            // The time: pill centre → header leading edge, one text throughout.
            Text(time)
                .font(.system(size: timeSize, weight: .semibold).monospacedDigit())
                .foregroundStyle(Ink.primary)
                .fixedSize()
                .position(x: timeX, y: lerp(pillTimeY, headerY, t))
            // Hover: a short date under the time, cleared before the island opens.
            Text(date.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day()))
                .font(.system(size: ClockLayout.hoverDateSize, weight: .medium))
                .foregroundStyle(Ink.secondary)
                .fixedSize()
                .opacity(detail * (1 - smoothstep(0.05, 0.3, t)))
                .position(x: centerX, y: top + height / 2 + ClockLayout.hoverDateDrop)
            // Open: the full date beside the time in the header, attached to the time's current
            // trailing edge so the two travel as one line and never collide mid-morph.
            Text(fullDate)
                .font(.system(size: QuickLaunchLayout.headerDateSize, weight: .medium))
                .foregroundStyle(Ink.secondary)
                .fixedSize()
                .opacity(smoothstep(0.55, 0.95, t))
                .position(x: timeX + timeWidth / 2 + QuickLaunchLayout.headerTimeToDate + fullDateWidth / 2,
                          y: lerp(pillTimeY, headerY, t))
        }
        .lineLimit(1)
    }

    /// Rendered width of `text` in `font` (matches SwiftUI's system font), for positioning by edge.
    static func width(of text: String, font: NSFont) -> CGFloat {
        ceil((text as NSString).size(withAttributes: [.font: font]).width)
    }
}

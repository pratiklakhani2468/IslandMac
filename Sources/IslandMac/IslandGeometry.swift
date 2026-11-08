import AppKit
import SwiftUI

// THE single source of truth for the island's size, shape and motion.
// Nothing else in the project may hard-code island dimensions.

struct IslandShapeSpec: Equatable, CustomStringConvertible {
    var width: CGFloat
    var height: CGFloat
    var cornerRadius: CGFloat   // height / 2 makes a full pill
    var topGap: CGFloat         // distance from the screen's top edge to the top of the surface

    var description: String {
        "\(fmt(width))×\(fmt(height)) pt, corner radius \(fmt(cornerRadius)), \(fmt(topGap)) pt below top edge"
    }
    private func fmt(_ v: CGFloat) -> String { v == v.rounded() ? "\(Int(v))" : "\(v)" }
}

struct IslandGeometry {
    /// Height of the menu bar on the island's screen (logged for reference; the pill sits inside this band).
    let menuBarHeight: CGFloat

    init(screen: NSScreen) {
        let measured = screen.frame.maxY - screen.visibleFrame.maxY
        menuBarHeight = measured > 0 ? measured : 24
    }

    /// Floating gap above the surface. Constant across states, so the pill grows down and out
    /// from the same top line instead of jumping.
    static let topGap: CGFloat = 5

    /// `fileRows` only matters for `.files` (the list grows with the session's dropped files);
    /// `activity` for home: the low-battery pill is a little wider (it carries the percentage), and
    /// the expanded size depends on what's in it (with music, the player plus a Quick Launch row
    /// beneath it).
    /// `searchRows` only for `.search`: result rows below the field. `terminalExpanded` only for
    /// `.terminal`: whether it shows its transcript or just the field. `convertHeight` only for
    /// `.convert`: the height its current content needs (from the converter).
    func spec(for state: IslandState, fileRows: Int = 0, searchRows: Int = 0,
              terminalExpanded: Bool = false, convertHeight: CGFloat = 0, activity: IslandActivity = .clock) -> IslandShapeSpec {
        switch state {
        case .resting:
            let width: CGFloat = switch activity {
            case .battery: BatteryLayout.compactWidth
            case .nowPlaying, .clock: 88
            }
            return IslandShapeSpec(width: width, height: 24, cornerRadius: 12, topGap: Self.topGap)
        case .hover:
            // A gentle nudge toward the pointer, not a jump: +8 × +2 pt, same full-round ends.
            let rest = spec(for: .resting, activity: activity)
            return IslandShapeSpec(width: rest.width + 8, height: 26, cornerRadius: 13, topGap: Self.topGap)
        case .expanded:
            let height = switch activity {
            case .nowPlaying: QuickLaunchLayout.musicRow.surfaceHeight
            // The idle layout (header + Quick Launch), with battery status in the header.
            case .battery, .clock: PlayerLayout.height
            }
            return IslandShapeSpec(width: 360, height: height, cornerRadius: 30, topGap: Self.topGap)
        case .dropApproach:
            // A big zone hanging below the notch, so a file never has to reach the screen's edge.
            return IslandShapeSpec(width: DropLayout.zoneSize.width, height: DropLayout.zoneSize.height,
                                   cornerRadius: DropLayout.zoneRadius, topGap: Self.topGap)
        case .dropNear:
            // The magnet: a little bigger as the file comes close.
            return IslandShapeSpec(width: DropLayout.zoneSize.width + 2 * DropLayout.nearGrowth, height: DropLayout.zoneSize.height + DropLayout.nearGrowth,
                                   cornerRadius: DropLayout.zoneRadius + 2, topGap: Self.topGap)
        case .dropOver:
            return IslandShapeSpec(width: DropLayout.zoneSize.width + 2 * DropLayout.overGrowth, height: DropLayout.zoneSize.height + DropLayout.overGrowth,
                                   cornerRadius: DropLayout.zoneRadius + 4, topGap: Self.topGap)
        case .dropReceived:
            return IslandShapeSpec(width: 210, height: 36, cornerRadius: 18, topGap: Self.topGap)
        case .files:
            // Same width and corners as expanded, so opening the list is a purely vertical grow.
            let e = spec(for: .expanded)
            return IslandShapeSpec(width: e.width, height: FilesLayout.height(rows: fileRows),
                                   cornerRadius: e.cornerRadius, topGap: Self.topGap)
        case .volume:
            return IslandShapeSpec(width: 184, height: 32, cornerRadius: 16, topGap: Self.topGap)
        case .power:
            // One shape for every power moment (charging, held, unplugged, charged), so going from
            // one to the next only changes the words; a little larger than the pill it grows from.
            // Wide enough for "Charging · Full in 12 hr 59 min" with the percentage and battery.
            return IslandShapeSpec(width: 296, height: 38, cornerRadius: 19, topGap: Self.topGap)
        case .quickLaunchEdit:
            let e = spec(for: .expanded)
            return IslandShapeSpec(width: e.width, height: QuickLaunchEditLayout.height,
                                   cornerRadius: e.cornerRadius, topGap: Self.topGap)
        case .terminal:
            // Wider than the other pages (command output needs the columns); a field-only pill
            // until something runs, like Quick Ask.
            return IslandShapeSpec(width: TerminalLayout.width, height: TerminalLayout.height(expanded: terminalExpanded),
                                   cornerRadius: TerminalLayout.cornerRadius, topGap: Self.topGap)
        case .convert:
            return IslandShapeSpec(width: ConvertLayout.width, height: convertHeight > 0 ? convertHeight : ConvertLayout.height(phase: .choosing, rows: 1),
                                   cornerRadius: ConvertLayout.cornerRadius, topGap: Self.topGap)
        case .terminalResult:
            return IslandShapeSpec(width: TerminalLayout.resultWidth, height: TerminalLayout.resultHeight,
                                   cornerRadius: TerminalLayout.resultHeight / 2, topGap: Self.topGap)
        case .search:
            let e = spec(for: .expanded)
            return IslandShapeSpec(width: e.width, height: FileSearchLayout.height(rows: searchRows),
                                   cornerRadius: min(e.cornerRadius, FileSearchLayout.height(rows: 0) / 2), topGap: Self.topGap)
        case .calendar:
            // Same width and corners as expanded; fixed height (always six week rows) so browsing
            // months never resizes the surface.
            let e = spec(for: .expanded)
            return IslandShapeSpec(width: e.width, height: CalendarLayout.height,
                                   cornerRadius: e.cornerRadius, topGap: Self.topGap)
        }
    }

    /// Room around the largest shape so the shadow is never clipped.
    static let shadowPadding: CGFloat = 24

    /// Fixed size of the transparent panel. The panel never resizes; only the shape inside morphs.
    var canvasSize: CGSize {
        let e = spec(for: .expanded)
        let tallest = max(e.height, spec(for: .expanded, activity: .nowPlaying).height,
                          spec(for: .files, fileRows: FilesLayout.maxVisibleRows).height, spec(for: .calendar).height,
                          spec(for: .search, searchRows: FileSearchLayout.maxResults).height, spec(for: .quickLaunchEdit).height,
                          spec(for: .terminal, terminalExpanded: true).height,
                          ConvertLayout.tallest)
        let widest = max(e.width, TerminalLayout.width, ConvertLayout.width)
        return CGSize(width: widest + 2 * Self.shadowPadding, height: e.topGap + tallest + Self.shadowPadding)
    }

    /// Screen-space rect of the surface for `state`, floating `topGap` below the top of `screen`.
    func rect(for state: IslandState, on screen: NSScreen, fileRows: Int = 0, searchRows: Int = 0,
              terminalExpanded: Bool = false, convertHeight: CGFloat = 0, activity: IslandActivity = .clock) -> NSRect {
        let s = spec(for: state, fileRows: fileRows, searchRows: searchRows,
                     terminalExpanded: terminalExpanded, convertHeight: convertHeight, activity: activity)
        return NSRect(x: screen.frame.midX - s.width / 2, y: screen.frame.maxY - s.topGap - s.height,
                      width: s.width, height: s.height)
    }

    // MARK: Live home layout
    //
    // Home content (artwork, equalizer, clock, player, page buttons) is placed from the surface's
    // *current, animated* size rather than animating on its own, so it moves in lockstep with the
    // morphing surface, including when an animation is interrupted and retargeted mid-flight.

    /// How far home is between the resting pill (0) and the expanded island (1), from the live height
    /// (the expanded height depends on the activity).
    func homeExpansion(height: CGFloat, activity: IslandActivity) -> CGFloat {
        let rest = spec(for: .resting).height, open = spec(for: .expanded, activity: activity).height
        return min(max((height - rest) / (open - rest), 0), 1)
    }

    /// Artwork frame for the live surface: centred on the left end cap when compact, in the player's
    /// slot when expanded, and continuously in between.
    func artworkFrame(width w: CGFloat, height h: CGFloat) -> (rect: CGRect, cornerRadius: CGFloat) {
        let t = homeExpansion(height: h, activity: .nowPlaying)
        let compact = CompactLayout.artworkSize
        let size = lerp(compact, PlayerLayout.artworkSize, t)
        let x = canvasSize.width / 2 - w / 2 + lerp(h / 2 - compact / 2, PlayerLayout.horizontalPadding, t)
        let y = Self.topGap + lerp(h / 2 - compact / 2, PlayerLayout.topPadding, t)
        return (CGRect(x: x, y: y, width: size, height: size), lerp(CompactLayout.artworkRadius, PlayerLayout.artworkRadius, t))
    }

    /// Equalizer centre: the right end cap of the pill. Stays near the top-right corner as the surface
    /// grows (it fades out while expanding), instead of drifting toward the middle.
    func equalizerCenter(width w: CGFloat, height h: CGFloat) -> CGPoint {
        let cap = min(h, spec(for: .hover).height) / 2
        return CGPoint(x: canvasSize.width / 2 + w / 2 - cap, y: Self.topGap + cap)
    }

    /// Page button centre, riding the live surface's right edge. Slot 0 is rightmost. With the player
    /// they sit on the progress row's line (bottom; the player reserves `PageButtonLayout.reserve`);
    /// with Quick Launch they sit in the header, as secondary actions beside the time.
    func pageButtonCenter(slot: Int, width w: CGFloat, height h: CGFloat, inHeader: Bool = false) -> CGPoint {
        let step = PageButtonLayout.size + PageButtonLayout.spacing
        let y = inHeader ? QuickLaunchLayout.headerCenterY
                         : PlayerLayout.height - PlayerLayout.bottomPadding - PlayerLayout.progressRowHeight / 2
        return CGPoint(x: canvasSize.width / 2 + w / 2 - PlayerLayout.horizontalPadding - PageButtonLayout.size / 2 - CGFloat(slot) * step,
                       y: Self.topGap + y)
    }

    /// With music, Quick Launch's customize button sits at the right end of the app row under the
    /// player (the player's own controls and progress bar stay as they are).
    func musicRowEditButtonCenter(width w: CGFloat) -> CGPoint {
        CGPoint(x: canvasSize.width / 2 + w / 2 - PlayerLayout.horizontalPadding - PageButtonLayout.size / 2,
                y: Self.topGap + QuickLaunchLayout.musicRow.rowCenterY)
    }

    /// Left edge of the live surface's content area (for header text).
    func contentLeading(width w: CGFloat) -> CGFloat {
        canvasSize.width / 2 - w / 2 + QuickLaunchLayout.horizontalPadding
    }

    /// Where a dragged file is relative to the drop zone: over it (the whole zone takes the drop,
    /// with the space above it up to the screen's edge), close to it (within `magnetDistance`), or
    /// anywhere else on screen. Once over, it stays over until it's clearly off the zone.
    func dropStage(at point: NSPoint, on screen: NSScreen, current: IslandState) -> IslandState {
        let over = rect(for: .dropOver, on: screen)
        let pad = current == .dropOver ? DropLayout.overPadding : 0
        let overZone = NSRect(x: over.minX - pad, y: over.minY - pad, width: over.width + 2 * pad, height: screen.frame.maxY - over.minY + pad + 4)
        if overZone.contains(point) { return .dropOver }
        let zone = rect(for: .dropApproach, on: screen)
        let dx = max(zone.minX - point.x, 0, point.x - zone.maxX)
        let dy = max(zone.minY - point.y, 0, point.y - zone.maxY)
        // Once close, it stays close until it's clearly farther, so the edge of that range can't flicker.
        let reach = DropLayout.magnetDistance + (current == .dropNear || current == .dropOver ? DropLayout.magnetHysteresis : 0)
        return (dx * dx + dy * dy).squareRoot() <= reach ? .dropNear : .dropApproach
    }

    /// Area the cursor must be inside to keep (or enter) `state`. Always reaches past the top
    /// edge, so a cursor pushed against the top of the screen above the pill still counts.
    func hotZone(for state: IslandState, on screen: NSScreen, fileRows: Int = 0, searchRows: Int = 0,
                 terminalExpanded: Bool = false, convertHeight: CGFloat = 0, activity: IslandActivity = .clock) -> NSRect {
        let (base, dx, dy): (IslandState, CGFloat, CGFloat) = switch state {
        // Pads keep the same zones as before hover shrank to 96×26 (behavior unchanged).
        case .resting: (.hover, 8, 7)
        case .hover: (.hover, 10, 9)
        case .expanded: (.expanded, 10, 10)
        // A dragged file "approaches" well before it reaches the island, so the target opens in time.
        case .dropApproach: (.dropApproach, 0, 0)
        case .dropNear: (.dropNear, 0, 0)
        case .dropOver: (.dropOver, DropLayout.overPadding, DropLayout.overPadding)
        case .dropReceived: (.dropReceived, 8, 8)
        case .files: (.files, 10, 10)
        case .calendar: (.calendar, 10, 10)
        case .search: (.search, 10, 10)
        case .terminal: (.terminal, 10, 10)
        case .convert: (.convert, 10, 10)
        case .terminalResult: (.terminalResult, 8, 8)
        case .quickLaunchEdit: (.quickLaunchEdit, 10, 10)
        case .volume: (.volume, 8, 8)
        case .power: (.power, 8, 8)
        }
        let r = rect(for: base, on: screen, fileRows: fileRows, searchRows: searchRows,
                     terminalExpanded: terminalExpanded, convertHeight: convertHeight, activity: activity)
        let bottom = r.minY - dy
        return NSRect(x: r.minX - dx, y: bottom, width: r.width + 2 * dx, height: screen.frame.maxY + 4 - bottom)
    }
}

enum IslandMotion {
    /// Time the cursor must rest on the island before hover turns into expanded.
    static let expandDwell: TimeInterval = 0.18
    /// Grace period after the cursor leaves an expanded island before it collapses.
    static let collapseGrace: TimeInterval = 0.10
    /// After the mouse is released over the drop target, how long to wait for AppKit to deliver
    /// the drop before treating the drag as cancelled.
    static let dropDeliveryGrace: TimeInterval = 0.35
    /// How long the "received" confirmation stays before the island returns to rest.
    static let dropConfirmation: TimeInterval = 1.6
    /// How long volume feedback stays after the last change before home returns.
    static let systemFeedbackDuration: TimeInterval = 1.5
    /// How long a power moment (plugged in, unplugged, charged) stays.
    static let powerFeedbackDuration: TimeInterval = 3

    // A small, consistent set of springs. SwiftUI springs retarget mid-flight with preserved
    // velocity, and home content follows the surface's live size, so interruptions stay continuous.
    /// Pointer nudge (resting ↔ hover): soft, no visible bounce.
    static let hoverSpring = Animation.spring(response: 0.3, dampingFraction: 0.9)
    /// Growing into an open surface (expanded, pages): quick, with a barely perceptible settle.
    static let openSpring = Animation.spring(response: 0.38, dampingFraction: 0.8)
    /// Collapsing back to the pill: slightly quicker than opening, critically damped.
    static let closeSpring = Animation.spring(response: 0.3, dampingFraction: 0.92)
    /// The drop zone reaching for a file that comes close: quick, with a small overshoot.
    static let magnetSpring = Animation.spring(response: 0.32, dampingFraction: 0.62)
    /// Brief system/drag responses (drop target, confirmation, volume, power).
    static let transientSpring = Animation.spring(response: 0.3, dampingFraction: 0.86)

    /// Spring used when animating *into* `state`.
    static func animation(into state: IslandState) -> Animation {
        switch state {
        case .resting: return closeSpring
        case .hover: return hoverSpring
        case .expanded, .files, .calendar, .search, .quickLaunchEdit, .terminal, .convert: return openSpring
        case .dropNear, .dropOver: return magnetSpring
        case .dropApproach, .dropReceived, .volume, .power, .terminalResult: return transientSpring
        }
    }
}

extension IslandMotion {
    /// Expanded content fades/scales in just after the surface starts growing, and leaves
    /// quickly on collapse so it never lingers outside the shrinking surface.
    /// Handovers are sequenced, not cross-faded: the old content clears in 70 ms, the new starts
    /// arriving at 70 ms, so two layouts are never visible on top of each other while the surface
    /// morphs, and the surface is never left empty for long.
    static let contentTransition: AnyTransition = .asymmetric(
        insertion: .opacity.combined(with: .scale(scale: 0.97, anchor: .top))
            .animation(.spring(response: 0.28, dampingFraction: 0.92).delay(0.07)),
        removal: .opacity.animation(.easeOut(duration: 0.07)))
}

/// Layout of the media player inside the expanded surface. The player's outer size is
/// always `spec(for: .expanded)`; these are only its insets and element sizes.
enum PlayerLayout {
    /// The player's own height (the expanded surface is taller with the Quick Launch row beneath).
    static let height: CGFloat = 112
    static let horizontalPadding: CGFloat = 20
    static let topPadding: CGFloat = 16
    static let bottomPadding: CGFloat = 15
    static let artworkSize: CGFloat = 52
    static let artworkRadius: CGFloat = 12
    static let artworkToText: CGFloat = 12
    static let controlHitSize: CGFloat = 30
    static let progressBarHeight: CGFloat = 4
    static let progressBarScrubHeight: CGFloat = 6
    static let progressRowHeight: CGFloat = 14
}

/// Now-playing indicator inside the resting/hover pill: artwork on the left end cap, equalizer on the right.
enum CompactLayout {
    static let artworkSize: CGFloat = 16
    /// A small rounded square (album art), not a circle.
    static let artworkRadius: CGFloat = 4.5
    static let barCount = 4
    static let barWidth: CGFloat = 2
    static let barSpacing: CGFloat = 1.5
    static let barMaxHeight: CGFloat = 9
    static let barMinHeight: CGFloat = 2
}

extension IslandMotion {
    /// Home content returning after a page or transient: settles in with the surface; leaves quickly.
    static let homeTransition: AnyTransition = .asymmetric(
        insertion: .opacity.combined(with: .scale(scale: 0.94))
            .animation(.spring(response: 0.28, dampingFraction: 0.92).delay(0.07)),
        removal: .opacity.animation(.easeOut(duration: 0.07)))
}

/// The drop zone (shown below the notch while a file is dragged anywhere) and the drop
/// confirmation. Outer sizes come from `spec(for:)` for the drop states.
enum DropLayout {
    static let iconSize: CGFloat = 17
    static let iconToText: CGFloat = 8
    static let confirmationPadding: CGFloat = 14
    /// The zone as a drag begins.
    static let zoneSize = CGSize(width: 380, height: 150)
    static let zoneRadius: CGFloat = 34
    /// How much it grows (per side, and downwards) when the file is close, and when it's over it.
    static let nearGrowth: CGFloat = 8
    static let overGrowth: CGFloat = 12
    /// "Close": within this distance of the zone.
    static let magnetDistance: CGFloat = 150
    static let magnetHysteresis: CGFloat = 20
    /// Once over the zone, the file can stray this far past its edge before it counts as off it.
    static let overPadding: CGFloat = 8
    /// The dashed target inside the zone.
    static let targetInset: CGFloat = 12
    static let targetRadius: CGFloat = 24
    static let badgeSize: CGFloat = 44
    /// Inner outline of the surface: faint while a file is dragged, brighter close by and over it.
    static let outlineWidth: CGFloat = 1
    static let outlineOpacityApproach: Double = 0.14
    static let outlineOpacityNear: Double = 0.24
    static let outlineOpacityOver: Double = 0.4
}

/// The session dropped-files list and the small button that opens it from the expanded island.
enum FilesLayout {
    static let headerHeight: CGFloat = 40
    static let rowHeight: CGFloat = 38
    static let bottomPadding: CGFloat = 10
    static let horizontalPadding: CGFloat = 18
    static let maxVisibleRows = 4
    static let iconSize: CGFloat = 24
    static let iconToText: CGFloat = 10
    static let actionSize: CGFloat = 24

    /// Height of the list surface; an empty list still gets one row for "No dropped files".
    static func height(rows: Int) -> CGFloat {
        headerHeight + CGFloat(min(max(rows, 1), maxVisibleRows)) * rowHeight + bottomPadding
    }
}

/// Small buttons in the expanded home that open pages (Files, Calendar, Search), laid out right to left.
enum PageButtonLayout {
    static let size: CGFloat = 22
    static let spacing: CGFloat = 4
    /// Buttons beside the player's progress row (the Quick Launch customize button isn't among them).
    static let count = 3
    static let filesSlot = 0
    static let calendarSlot = 1
    static let searchSlot = 2
    /// Only in the idle Quick Launch header (not beside the music player).
    static let editSlot = 3
    /// Trailing space the player's progress row leaves for the page buttons (with a clear gap after
    /// the remaining time).
    static let reserve: CGFloat = CGFloat(count) * size + CGFloat(count - 1) * spacing + 12
}

/// Small controls shared by the pages: header back buttons, capsule buttons, glyph buttons.
enum ControlLayout {
    static let headerTitleSize: CGFloat = 13
    static let headerChevronSize: CGFloat = 11
    static let headerChevronSpacing: CGFloat = 6
    static let glyphButtonSize: CGFloat = 22
    static let glyphSize: CGFloat = 11.5
    static let capsuleHeight: CGFloat = 20
    static let capsulePadding: CGFloat = 8
    static let capsuleTextSize: CGFloat = 11
    /// Selected list row / selected icon: one radius everywhere.
    static let selectionRadius: CGFloat = 10
    /// Pressed buttons: a light, quick squeeze.
    static let pressedScale: CGFloat = 0.9
    static let pressedOpacity: Double = 0.7
}

/// The Calendar page: header, weekday labels and a six-week date grid.
enum CalendarLayout {
    static let headerHeight: CGFloat = 38
    static let weekdayRowHeight: CGFloat = 16
    static let weekRows = 6
    static let rowHeight: CGFloat = 22
    static let bottomPadding: CGFloat = 12
    static let horizontalPadding: CGFloat = 18
    static let dayMarkSize: CGFloat = 20
    /// Month change: the grid shifts this far in the direction of travel while cross-fading.
    static let monthSlide: CGFloat = 20
    static let monthAnimation = Animation.spring(response: 0.32, dampingFraction: 0.92)

    static var height: CGFloat {
        headerHeight + weekdayRowHeight + CGFloat(weekRows) * rowHeight + bottomPadding
    }
}

/// The idle clock in the pill. When the island opens it becomes Quick Launch's header (see
/// `QuickLaunchLayout`), so there is no large clock.
enum ClockLayout {
    static let restingTimeSize: CGFloat = 11.5
    static let hoverTimeSize: CGFloat = 10.5
    static let hoverDateSize: CGFloat = 8
    /// On hover the time rises and a short date sits under it (offsets from the pill's centre).
    static let hoverTimeLift: CGFloat = 5.5
    static let hoverDateDrop: CGFloat = 6.5
}

/// Volume feedback content. Outer size comes from `spec(for: .volume)`.
enum SystemFeedbackLayout {
    static let horizontalPadding: CGFloat = 16
    static let iconWidth: CGFloat = 22
    static let iconToBar: CGFloat = 10
    static let barHeight: CGFloat = 4
}

func lerp(_ a: CGFloat, _ b: CGFloat, _ t: CGFloat) -> CGFloat { a + (b - a) * t }

/// 0 below `lower`, 1 above `upper`, smooth in between: used to fade content over part of a morph.
func smoothstep(_ lower: CGFloat, _ upper: CGFloat, _ x: CGFloat) -> CGFloat {
    let t = min(max((x - lower) / (upper - lower), 0), 1)
    return t * t * (3 - 2 * t)
}

/// The surface's material: black, a hairline edge and a restrained shadow that deepens as it rises.
enum SurfaceStyle {
    static let hairlineOpacity: Double = 0.07
    static let hairlineWidth: CGFloat = 0.5
    static let restingShadow = (opacity: 0.18, radius: CGFloat(4), y: CGFloat(1.5))
    static let hoverShadow = (opacity: 0.22, radius: CGFloat(7), y: CGFloat(2.5))
    static let liftedShadow = (opacity: 0.3, radius: CGFloat(18), y: CGFloat(8))
}

/// Tones for text and glyphs on the black surface: one small scale, used everywhere.
enum Ink {
    /// Titles, the time, values.
    static let primary = Color.white.opacity(0.94)
    /// Subtitles, artist, dates, file locations.
    static let secondary = Color.white.opacity(0.55)
    /// Hints, placeholders, weekday labels, time labels.
    static let tertiary = Color.white.opacity(0.36)
    /// Disabled controls, days outside the month.
    static let quaternary = Color.white.opacity(0.2)
    /// Glyph buttons at rest.
    static let control = Color.white.opacity(0.7)
    /// Hairline separators inside the surface.
    static let separator = Color.white.opacity(0.1)
    /// Selected row / selected icon backing.
    static let selection = Color.white.opacity(0.1)
    /// Capsule buttons and progress-track backgrounds.
    static let fill = Color.white.opacity(0.14)
}

/// Quick Launch: the expanded idle island. A header (time and date on the left, page buttons on the
/// right) and one centred row of app icons with the hovered app's name beneath. Fits the standard
/// expanded surface (360×112); all y values are from the surface's top edge.
enum QuickLaunchLayout {
    static let maxApps = 6
    static let horizontalPadding: CGFloat = 20
    static let headerCenterY: CGFloat = 22
    static let headerTimeSize: CGFloat = 13
    static let headerDateSize: CGFloat = 11.5
    static let headerTimeToDate: CGFloat = 7
    static let nameSize: CGFloat = 11

    /// One row of app icons: sizes and vertical positions (from the surface's top), and where in
    /// the morph (`t`) the icons start arriving.
    struct Row {
        let iconSize: CGFloat
        let iconSpacing: CGFloat
        let rowCenterY: CGFloat
        let nameCenterY: CGFloat
        let revealFrom: CGFloat
        /// Expanded surface height when this row is the last thing in it.
        let surfaceHeight: CGFloat
    }
    /// Idle: the row is the main content, centred under the header.
    static let idleRow = Row(iconSize: 36, iconSpacing: 12, rowCenterY: 64, nameCenterY: 96, revealFrom: 0.45,
                             surfaceHeight: PlayerLayout.height)
    /// With music: a smaller row under the player, past a hairline; arrives last, after the player.
    /// Spaced like the idle row: 8 pt from the hairline to the icons, and the name as far from the
    /// bottom edge as the idle name is.
    static let musicRow = Row(iconSize: 30, iconSpacing: 12, rowCenterY: 127, nameCenterY: 153, revealFrom: 0.6,
                              surfaceHeight: 168)
    /// Hairline between the player and the app row (y from the surface top).
    static let musicSeparatorY: CGFloat = 104
    /// Hovered icon: a small lift, never a Dock-style magnification.
    static let hoverScale: CGFloat = 1.08
    static let hoverLift: CGFloat = 2
    static let restingIconOpacity: Double = 0.9
    /// Icons arrive from the centre outwards, following the surface as it grows from its centre;
    /// each ring starts this much later (fraction of the morph).
    static let revealStagger: CGFloat = 0.06
    static let hoverAnimation = Animation.spring(response: 0.24, dampingFraction: 0.82)
    /// The hovered app's name: a quick cross-fade with a slight rise.
    static let nameAnimation = Animation.easeOut(duration: 0.14)
}

/// Charging and low battery: the battery glyph, the `.power` moments and the low-battery pill.
/// Outer sizes come from `spec(for:)` (`.power`, and home with the `.battery` activity).
enum BatteryLayout {
    // The glyph: a rounded body with a small cap, filled to the charge level.
    static let bodyWidth: CGFloat = 22
    static let bodyHeight: CGFloat = 11
    static let bodyRadius: CGFloat = 3.5
    static let outlineWidth: CGFloat = 1
    static let fillInset: CGFloat = 2
    static let fillRadius: CGFloat = 1.5
    static let capWidth: CGFloat = 1.5
    static let capHeight: CGFloat = 4
    static let capGap: CGFloat = 1
    static let boltSize: CGFloat = 8
    static var glyphWidth: CGFloat { bodyWidth + capGap + capWidth }
    /// Charging: the fill grows from empty to the level as the moment appears.
    static let fillAnimation = Animation.spring(response: 0.9, dampingFraction: 0.86).delay(0.15)

    // The `.power` moment.
    static let feedbackPadding: CGFloat = 16
    static let feedbackTitleSize: CGFloat = 12.5
    static let feedbackPercentToGlyph: CGFloat = 7

    // The low-battery pill ("[glyph] 18%") and its header when expanded.
    static let compactWidth: CGFloat = 96
    static let compactTextSize: CGFloat = 11.5
    static let glyphToText: CGFloat = 6
    static let headerPercentToDetail: CGFloat = 8

    static let chargingColor = Color(nsColor: .systemGreen)
    static let lowColor = Color(nsColor: .systemOrange)
    static let criticalColor = Color(nsColor: .systemRed)
    /// Pill fills: a deep amber and a deep red; white reads well on both.
    static let lowFill = Color(red: 0.74, green: 0.42, blue: 0.04)
    static let criticalFill = Color(red: 0.72, green: 0.1, blue: 0.09)
}

/// File Search: a search field that can grow a short list of results. Same width and corners as the
/// expanded island. Heights from the surface's top edge.
enum FileSearchLayout {
    static let fieldHeight: CGFloat = 46
    static let rowHeight: CGFloat = 40
    /// Hairline under the field, then this gap before the first result.
    static let listTopGap: CGFloat = 6
    static let bottomPadding: CGFloat = 8
    static let horizontalPadding: CGFloat = 18
    static let iconSize: CGFloat = 26
    static let iconToText: CGFloat = 10
    static let fieldIconSize: CGFloat = 13
    /// The field row is `fieldHeight` tall at the top of a `height(rows: 0)` pill; this centres it.
    static var fieldCenteringOffset: CGFloat { (height(rows: 0) - fieldHeight) / 2 }
    /// Extra downward nudge for the text/placeholder only, tuned by eye on the real screen.
    static let textNudge: CGFloat = 1
    static let maxResults = 5
    /// Search work: wait for a pause in typing, and consider at most this many Spotlight candidates.
    static let debounce: TimeInterval = 0.15
    static let maxCandidates = 4000
    /// Only show progress if Spotlight is noticeably slow.
    static let progressAfter: TimeInterval = 0.3

    /// Surface height for `rows` visible result rows (0 = just the field).
    static func height(rows: Int) -> CGFloat {
        rows == 0 ? fieldHeight + bottomPadding / 2
                  : fieldHeight + listTopGap + CGFloat(min(rows, maxResults)) * rowHeight + bottomPadding
    }
}

/// Convert: the dropped file's ticket, then rows of keycaps (choosing), a progress track
/// (working), or the stamp and actions (done). Heights from the surface's top edge; the surface
/// grows and shrinks with the content.
enum ConvertLayout {
    static let width: CGFloat = 404
    static let cornerRadius: CGFloat = 28
    static let horizontalPadding: CGFloat = 18
    static let topPadding: CGFloat = 15
    static let bottomPadding: CGFloat = 15
    static let ticketHeight: CGFloat = 44
    static let tileSize: CGFloat = 44
    static let tileRadius: CGFloat = 11
    static let sectionGap: CGFloat = 13
    static let keyHeight: CGFloat = 30
    /// How far a keycap's face presses into its base.
    static let keyDepth: CGFloat = 2.5
    static let keyRadius: CGFloat = 8
    static let keyPadding: CGFloat = 12
    static let keySpacing: CGFloat = 8
    static let rowGap: CGFloat = 8
    static let hintTopPadding: CGFloat = 7
    static let hintHeight: CGFloat = 22
    static let trackHeight: CGFloat = 26
    static let statusGap: CGFloat = 6
    static let statusHeight: CGFloat = 16
    static let noteHeight: CGFloat = 19
    static let dotCount = 26
    /// A finished result stays this long when the pointer is elsewhere, then the island closes.
    static let doneLinger: TimeInterval = 8
    /// Leaving a finished result: a moment before it closes.
    static let leaveGrace: TimeInterval = 0.6
    static let shrankColor = Color(red: 0.5, green: 0.9, blue: 0.58)

    /// Buttons per row: all of them up to three, two by two for four, three then two for five.
    static func columns(for count: Int) -> Int {
        count <= 3 ? max(count, 1) : count == 4 ? 2 : 3
    }

    static func rows(for count: Int) -> Int {
        max(1, Int((Double(count) / Double(columns(for: count))).rounded(.up)))
    }

    static func height(phase: Converter.Phase, rows: Int, hasHint: Bool = false, hasNote: Bool = false) -> CGFloat {
        let top = topPadding + ticketHeight + sectionGap
        switch phase {
        case .idle, .choosing:
            let keys = CGFloat(rows) * keyHeight + CGFloat(max(rows - 1, 0)) * rowGap
            return top + keys + (hasHint ? hintHeight : 0) + bottomPadding
        case .working:
            return top + trackHeight + statusGap + statusHeight + bottomPadding
        case .done:
            return top + keyHeight + (hasNote ? noteHeight : 0) + bottomPadding
        }
    }

    /// The tallest the converter gets (two rows of buttons and a hint).
    static var tallest: CGFloat { height(phase: .choosing, rows: 2, hasHint: true) }

    static func mono(_ size: CGFloat, weight: Font.Weight = .regular) -> Font {
        .system(size: size, weight: weight, design: .monospaced)
    }
}

/// Quick Terminal: a command field and, once something has run, the transcript beneath it (and any
/// question about the command under that). Wider than the other pages, for command output. Also the
/// pill's running spinner and the "Done ✓ / Failed ✕" moment.
enum TerminalLayout {
    static let width: CGFloat = 480
    static let fieldHeight: CGFloat = FileSearchLayout.fieldHeight
    static let expandedHeight: CGFloat = 320
    static let cornerRadius: CGFloat = 24
    static let horizontalPadding: CGFloat = FileSearchLayout.horizontalPadding
    static let fieldIconSize: CGFloat = FileSearchLayout.fieldIconSize
    static let fieldTextSize: CGFloat = 12.5
    /// The current folder in the field; longer paths are cut from the front.
    static let folderMaxWidth: CGFloat = 150
    static let textSize: CGFloat = 11.5
    static let statusTextSize: CGFloat = 10.5
    static let lineSpacing: CGFloat = 1
    static let commandTopPadding: CGFloat = 6
    static let transcriptPadding: CGFloat = 6
    static let cardRadius: CGFloat = 12
    static let cardBottomPadding: CGFloat = 12
    /// The field-only pill is a touch taller than the field row; this centres the row in it.
    static var fieldCenteringOffset: CGFloat { (height(expanded: false) - fieldHeight) / 2 }

    static let spinnerSize: CGFloat = 10
    static let spinnerLineWidth: CGFloat = 1.6
    static let resultWidth: CGFloat = 236
    static let resultHeight: CGFloat = 32
    static let resultPadding: CGFloat = 14
    /// How long "Done ✓ / Failed ✕" stays.
    static let resultDuration: TimeInterval = 2

    static func height(expanded: Bool) -> CGFloat {
        expanded ? expandedHeight : fieldHeight + FileSearchLayout.bottomPadding / 2
    }

    static func mono(_ size: CGFloat, weight: Font.Weight = .regular) -> Font {
        .system(size: size, weight: weight, design: .monospaced)
    }

    static func color(for outcome: QuickTerminal.Outcome) -> Color {
        switch outcome {
        case .success: Color(red: 0.45, green: 0.86, blue: 0.5)
        case .failure: Color(red: 1, green: 0.42, blue: 0.4)
        case .stopped: Color(red: 0.98, green: 0.7, blue: 0.35)
        }
    }
}

/// The Quick Launch editor: your apps (select one to move or remove it) and a list of installed
/// apps to add. Same width and corners as the expanded island; heights from the surface's top.
enum QuickLaunchEditLayout {
    static let horizontalPadding: CGFloat = 18
    static let headerHeight: CGFloat = 38
    static let currentRowHeight: CGFloat = 50
    static let currentIconSize: CGFloat = 32
    static let currentIconSpacing: CGFloat = 10
    static let controlsHeight: CGFloat = 26
    static let addTitleHeight: CGFloat = 22
    static let listRowHeight: CGFloat = 28
    static let listIconSize: CGFloat = 20
    static let visibleListRows = 4
    static let bottomPadding: CGFloat = 8

    static var height: CGFloat {
        headerHeight + currentRowHeight + controlsHeight + addTitleHeight + CGFloat(visibleListRows) * listRowHeight + bottomPadding
    }
}

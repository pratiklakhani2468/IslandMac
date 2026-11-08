import SwiftUI

/// The island's presentation state only. Feature data lives with each feature
/// (NowPlaying for music, DroppedFiles for files); see IslandState.swift for the model.
final class IslandModel: ObservableObject {
    @Published var state: IslandState = .resting
    /// Set by IslandController so buttons inside the island can switch its state.
    var requestState: ((IslandState) -> Void)?
    /// Set by IslandController: collapse after an action that sends the user elsewhere.
    var dismiss: (() -> Void)?
}

/// Where the pointer is over the island, in canvas coordinates (top-left origin), or nil when it
/// isn't. Published by IslandController from the mouse events it already tracks, because hover
/// tracking areas aren't reliable in a panel that never becomes key. Only views that need it observe it.
final class IslandPointer: ObservableObject {
    @Published var location: CGPoint?
}

/// Black floating surface: a pill at rest that grows into a rounded panel.
/// Size and radius are animatable, so a state change is one continuous morph of the same shape.
struct IslandShape: Shape {
    var spec: IslandShapeSpec

    var animatableData: AnimatablePair<AnimatablePair<CGFloat, CGFloat>, CGFloat> {
        get { .init(.init(spec.width, spec.height), spec.cornerRadius) }
        set {
            spec.width = newValue.first.first
            spec.height = newValue.first.second
            spec.cornerRadius = newValue.second
        }
    }

    func path(in rect: CGRect) -> Path {
        let w = min(spec.width, rect.width)
        let h = min(spec.height, rect.height - spec.topGap)
        let r = max(0, min(spec.cornerRadius, w / 2, h / 2))
        let surface = CGRect(x: rect.midX - w / 2, y: rect.minY + spec.topGap, width: w, height: h)
        return Self.withoutDegenerateLines(Path(roundedRect: surface, cornerRadius: r, style: .continuous))
    }

    /// At (near) full-pill radii the continuous rounded rect contains zero-length line segments at
    /// the end caps, which a stroke renders as a stray vertical line beside the pill. Filling is
    /// unaffected; the edge hairline and drop outline need them gone.
    private static func withoutDegenerateLines(_ path: Path) -> Path {
        var result = Path()
        var current = CGPoint.zero
        path.forEach { element in
            switch element {
            case .move(let to): result.move(to: to); current = to
            case .line(let to):
                if abs(to.x - current.x) > 0.001 || abs(to.y - current.y) > 0.001 { result.addLine(to: to) }
                current = to
            case .curve(let to, let c1, let c2): result.addCurve(to: to, control1: c1, control2: c2); current = to
            case .quadCurve(let to, let c): result.addQuadCurve(to: to, control: c); current = to
            case .closeSubpath: result.closeSubpath()
            }
        }
        return result
    }
}

struct IslandView: View {
    @ObservedObject var model: IslandModel
    @ObservedObject var nowPlaying: NowPlaying
    @ObservedObject var files: DroppedFiles
    /// Not observed here: only VolumeFeedbackView redraws on volume changes.
    let volume: SystemVolume
    /// Not observed here: only QuickLaunchView redraws when the app list changes.
    let apps: QuickLaunchApps
    /// Not observed here: only QuickLaunchView redraws as the pointer moves.
    let pointer: IslandPointer
    @ObservedObject var search: FileSearch
    /// Not observed here: only its page redraws as output arrives.
    let terminal: QuickTerminal
    /// Observed: whether a command runs (the pill's spinner) and the page's size.
    @ObservedObject var terminalStatus: TerminalStatus
    /// Not observed here: only its page redraws as the user types or a conversion runs.
    let converter: Converter
    /// Observed: the converter page's height and tint.
    @ObservedObject var convertLayout: ConvertLayoutState
    /// Observed: a low battery decides the activity, and the `.power` moment reads it.
    @ObservedObject var power: PowerSource
    let geometry: IslandGeometry

    var body: some View {
        let state = model.state
        let activity = IslandActivity.current(nowPlaying: nowPlaying, power: power)
        let spec = geometry.spec(for: state, fileRows: files.items.count, searchRows: search.visibleRows,
                                 terminalExpanded: terminalStatus.expanded, convertHeight: convertLayout.height, activity: activity)
        let shadow = state.isLifted ? SurfaceStyle.liftedShadow : state == .hover ? SurfaceStyle.hoverShadow : SurfaceStyle.restingShadow
        let outline = state == .dropOver ? DropLayout.outlineOpacityOver
            : state == .dropNear ? DropLayout.outlineOpacityNear
            : state == .dropApproach ? DropLayout.outlineOpacityApproach : SurfaceStyle.hairlineOpacity
        // The converter's edge takes the tint of the file it holds.
        let edge = state == .convert ? convertLayout.tint.opacity(0.4) : Color.white.opacity(outline)
        ZStack(alignment: .top) {
            IslandShape(spec: spec)
                .fill(Color.black)
                .shadow(color: .black.opacity(shadow.opacity), radius: shadow.radius, y: shadow.y)
            // Hairline edge: separates the surface from dark backgrounds; the drop target brightens it.
            IslandShape(spec: spec)
                .stroke(edge,
                        lineWidth: state.isDropTarget ? DropLayout.outlineWidth : SurfaceStyle.hairlineWidth)

            // Content lives inside the surface: masked by the same animated shape, so it is
            // revealed and hidden by the morph rather than floating on top of it.
            // Layers (IslandState.swift): transients > pages > home, and home shows the activity.
            ZStack(alignment: .top) {
                // Transients.
                if state.isDropTarget {
                    DropZoneView(stage: state)
                        .frame(width: spec.width, height: spec.height)
                        .padding(.top, spec.topGap)
                        .transition(IslandMotion.contentTransition)
                }
                if state == .dropReceived {
                    DropReceivedView(files: files.lastDrop)
                        .frame(width: spec.width, height: spec.height)
                        .padding(.top, spec.topGap)
                        .transition(IslandMotion.contentTransition)
                }
                if state == .volume {
                    VolumeFeedbackView(volume: volume)
                        .frame(width: spec.width, height: spec.height)
                        .padding(.top, spec.topGap)
                        .transition(IslandMotion.contentTransition)
                }
                if state == .power {
                    PowerFeedbackView(power: power)
                        .frame(width: spec.width, height: spec.height)
                        .padding(.top, spec.topGap)
                        .transition(IslandMotion.contentTransition)
                }
                if state == .terminalResult {
                    TerminalResultView(status: terminalStatus)
                        .frame(width: spec.width, height: spec.height)
                        .padding(.top, spec.topGap)
                        .transition(IslandMotion.contentTransition)
                }
                // Pages.
                if state == .files {
                    DroppedFilesView(files: files) { model.requestState?(.expanded) }
                        .frame(width: spec.width, height: spec.height)
                        .padding(.top, spec.topGap)
                        .transition(IslandMotion.contentTransition)
                }
                if state == .search {
                    SearchPageView(search: search) { result in
                        search.open(result)
                        model.dismiss?()
                    } onExit: {
                        model.requestState?(.expanded)
                    }
                    .frame(width: spec.width, height: spec.height, alignment: .top)
                    .padding(.top, spec.topGap)
                    .transition(IslandMotion.contentTransition)
                }
                if state == .terminal {
                    QuickTerminalPageView(terminal: terminal, status: terminalStatus) { model.requestState?(.resting) }
                        .frame(width: spec.width, height: spec.height, alignment: .top)
                        .padding(.top, spec.topGap)
                        .transition(IslandMotion.contentTransition)
                }
                if state == .convert {
                    ConvertPageView(converter: converter)
                        .frame(width: spec.width, height: spec.height, alignment: .top)
                        .padding(.top, spec.topGap)
                        .transition(IslandMotion.contentTransition)
                }
                if state == .quickLaunchEdit {
                    QuickLaunchEditView(apps: apps) { model.requestState?(.expanded) }
                        .frame(width: spec.width, height: spec.height, alignment: .top)
                        .padding(.top, spec.topGap)
                        .transition(IslandMotion.contentTransition)
                }
                if state == .calendar {
                    CalendarPageView { model.requestState?(.expanded) }
                        .frame(width: spec.width, height: spec.height)
                        .padding(.top, spec.topGap)
                        .transition(IslandMotion.contentTransition)
                }
                // Home: the live activity (music or clock) and page buttons, laid out from the
                // surface's animated size so they move with it (see HomeLayer).
                if state.kind == .home {
                    HomeLayer(width: spec.width, height: spec.height, detail: state == .resting ? 0 : 1,
                              state: state, activity: activity, nowPlaying: nowPlaying, power: power, quickLaunch: apps, pointer: pointer,
                              fileCount: files.items.count, hidesEqualizer: terminalStatus.isRunning, geometry: geometry,
                              requestState: { model.requestState?($0) }, dismiss: { model.dismiss?() })
                        .transition(IslandMotion.homeTransition)
                }
                // A Quick Terminal command still running with the island closed: a spinner on the
                // pill's right end cap (where the equalizer would be).
                if state.isCompact && terminalStatus.isRunning {
                    TerminalSpinner()
                        .position(geometry.equalizerCenter(width: spec.width, height: spec.height))
                        .frame(width: geometry.canvasSize.width, height: geometry.canvasSize.height)
                        .transition(.opacity.animation(.easeOut(duration: 0.15)))
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .mask(IslandShape(spec: spec))
        }
        .frame(width: geometry.canvasSize.width, height: geometry.canvasSize.height, alignment: .top)
        .animation(IslandMotion.animation(into: state), value: state)
        .animation(IslandMotion.animation(into: .files), value: files.items.count)
        .animation(IslandMotion.openSpring, value: search.visibleRows)
        .animation(IslandMotion.openSpring, value: terminalStatus.expanded)
        .animation(IslandMotion.openSpring, value: convertLayout.height)
        // Music starting/stopping (or a low battery appearing/clearing) changes the home's size.
        .animation(IslandMotion.openSpring, value: activity)
    }
}

/// Small icon button in the expanded home that opens a page, with an optional count badge.
struct PageButton: View {
    let symbol: String
    let badge: Int
    let help: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Ink.control)
                .frame(width: PageButtonLayout.size, height: PageButtonLayout.size)
                .overlay(alignment: .topTrailing) {
                    if badge > 0 {
                        Text("\(badge)")
                            .font(.system(size: 8.5, weight: .bold).monospacedDigit())
                            .foregroundStyle(.black)
                            .padding(.horizontal, 3.5)
                            .frame(minWidth: 12)
                            .background(Capsule().fill(.white))
                            // A thin ring of the surface colour keeps the badge off the glyph.
                            .background(Capsule().stroke(.black, lineWidth: 1.5))
                            .offset(x: 5, y: -3)
                    }
                }
                .contentShape(Rectangle())
        }
        .buttonStyle(PressScaleStyle())
        .help(help)
    }
}

/// Page header's leading control: a back chevron and the page title, one style on every page.
struct PageBackButton: View {
    let title: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: ControlLayout.headerChevronSpacing) {
                Image(systemName: "chevron.left")
                    .font(.system(size: ControlLayout.headerChevronSize, weight: .bold))
                    .foregroundStyle(Ink.secondary)
                Text(title)
                    .font(.system(size: ControlLayout.headerTitleSize, weight: .semibold))
                    .foregroundStyle(Ink.primary)
                    .contentTransition(.opacity)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(PressScaleStyle())
    }
}

/// A small capsule button label ("Today", "Remove").
struct CapsuleLabel: View {
    let title: String

    var body: some View {
        Text(title)
            .font(.system(size: ControlLayout.capsuleTextSize, weight: .semibold))
            .foregroundStyle(Ink.primary)
            .padding(.horizontal, ControlLayout.capsulePadding)
            .frame(height: ControlLayout.capsuleHeight)
            .background(Capsule().fill(Ink.fill))
            .contentShape(Capsule())
    }
}

/// A square glyph button (month navigation, move left/right).
struct GlyphButton: View {
    let symbol: String
    var help: String = ""
    var enabled = true
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: ControlLayout.glyphSize, weight: .semibold))
                .foregroundStyle(enabled ? Ink.control : Ink.quaternary)
                .frame(width: ControlLayout.glyphButtonSize, height: ControlLayout.glyphButtonSize)
                .contentShape(Rectangle())
        }
        .buttonStyle(PressScaleStyle())
        .disabled(!enabled)
        .help(help)
    }
}

import Foundation

/// The island's state model.
///
/// What the surface shows is decided in three layers, strongest first:
///  1. **Transient** events own the whole surface until they finish: a file drag near/over the
///     island, then the brief "received" confirmation; or brief system feedback (volume, power). Hover
///     tracking is ignored meanwhile. File drags outrank system feedback (see `acceptsSystemFeedback`).
///  2. **Pages** the user opens deliberately (Files, Calendar, Search and the Quick Launch editor
///     from the expanded island; Quick Terminal from its global hotkey; Convert when files are
///     dropped on it) replace its home.
///  3. **Home** otherwise, at the size the pointer asks for: resting → hover → expanded. Home is
///     filled by the current live activity (`IslandActivity`): low battery, music, or the idle clock.
///
/// `IslandState` is the resolved surface: one case per distinct shape, which is what geometry sizes
/// and IslandView renders. Code asks the properties below rather than listing cases, so a new page
/// or transient is added here (plus its size in IslandGeometry) without touching the rest.
enum IslandState: String {
    // Home, sized by the pointer.
    case resting, hover, expanded
    // Pages opened from the expanded home, Quick Terminal (opened by its hotkey from anywhere), and
    // Convert (files dropped on the island).
    case files, calendar, search, quickLaunchEdit, terminal, convert
    // Transients: a file is being dragged somewhere on screen (the drop zone hangs below the
    // notch), it's close to the zone, it's over it; or it was just dropped on it.
    case dropApproach, dropNear, dropOver, dropReceived
    // Transient system feedback: the output volume just changed; power was connected/disconnected,
    // or the battery finished charging; a Quick Terminal command finished while the island was closed.
    case volume, power, terminalResult

    enum Kind { case home, page, transient }

    var kind: Kind {
        switch self {
        case .resting, .hover, .expanded: return .home
        case .files, .calendar, .search, .quickLaunchEdit, .terminal, .convert: return .page
        case .dropApproach, .dropNear, .dropOver, .dropReceived, .volume, .power, .terminalResult: return .transient
        }
    }

    /// The small pill (at rest or hovered): shows the activity's compact indicator.
    var isCompact: Bool { self == .resting || self == .hover }
    /// Open surfaces take clicks (controls, list rows) and collapse when the pointer leaves.
    var isOpen: Bool { self == .expanded || kind == .page }
    /// Open surfaces normally collapse when the pointer leaves; the typing pages (Search, Quick Terminal, Convert)
    /// don't, because the user is typing into them (they close on Escape, on opening a result, or
    /// when another app takes focus).
    var collapsesOnPointerExit: Bool { isOpen && !takesKeyboard }
    /// The only states in which the island may take keyboard focus.
    var takesKeyboard: Bool { self == .search || self == .terminal || self == .convert }
    /// Owned by an event, not the pointer.
    var isTransient: Bool { kind == .transient }
    /// A file drag is in progress and the drop zone is showing.
    var isDropTarget: Bool { self == .dropApproach || self == .dropNear || self == .dropOver }
    /// Brief feedback about the system (volume, power, a finished command), as opposed to a file drag.
    var isSystemFeedback: Bool { self == .volume || self == .power || self == .terminalResult }
    /// Whether background system feedback (a volume change, power plugged in…) may take over the
    /// surface now: only the compact home pill, or feedback that is already showing (to update or
    /// replace it). It never interrupts a page, the expanded island the user is working in, or a
    /// file drag/drop.
    var acceptsSystemFeedback: Bool { isCompact || isSystemFeedback }
    /// Raised surfaces get the deeper shadow.
    var isLifted: Bool { isOpen || isDropTarget }
}

/// A live activity that fills the island's home: a compact indicator inside the pill (resting,
/// hover) and the expanded home content. One shows at a time, chosen by priority in `current`.
///
/// To add one (a timer, a call…): add a case, give it a line in `current` in priority order, and
/// render its compact and expanded content in IslandView's home layer. Pages and transients
/// already take precedence over any activity, and the activity returns when they finish.
enum IslandActivity: Equatable {
    /// Running on a low battery (20% or less; critical at 10%). Never while plugged in.
    case battery(PowerSource.Warning)
    /// A track is loaded in Music (playing or paused).
    case nowPlaying
    /// Idle fallback: the current time and date, so home is never an empty surface.
    case clock

    /// The highest-priority activity that has something to show; the clock when nothing else does.
    static func current(nowPlaying: NowPlaying, power: PowerSource) -> IslandActivity {
        if let warning = power.warning { return .battery(warning) }
        if nowPlaying.track != nil { return .nowPlaying }
        return .clock
    }
}

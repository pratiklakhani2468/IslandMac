import AppKit
import Combine
import SwiftUI

/// Borderless, non-activating panel. It never becomes key or main, so hovering or
/// clicking the island never takes keyboard focus from the app you're using.
final class IslandPanel: NSPanel {
    /// Only while a typing page (File Search, Quick Terminal) is open may the panel take keyboard focus
    /// (as a non-activating panel, without activating IslandMac). The rest of the time it never
    /// becomes key.
    var allowsKeyboard = false
    override var canBecomeKey: Bool { allowsKeyboard }
    override var canBecomeMain: Bool { false }
    // Keep AppKit from pushing the panel below the menu bar.
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { frameRect }
}

/// Transparent content view: takes clicks, right-clicks and drags for the island.
final class IslandContentView: NSView {
    /// While expanded, left clicks go to the SwiftUI content (player controls) instead of this view.
    var routesClicksToContent = false
    var onClick: (() -> Void)?
    var onRightClick: ((NSEvent) -> Void)?
    var dragOperation: (() -> NSDragOperation)?
    var onDrop: (([URL]) -> Bool)?

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? {
        guard frame.contains(point) else { return nil }
        let isRightClick = NSApp.currentEvent.map { $0.type == .rightMouseDown || $0.type == .rightMouseUp } ?? false
        return routesClicksToContent && !isRightClick ? super.hitTest(point) : self
    }
    override func mouseDown(with event: NSEvent) { onClick?() }
    override func rightMouseDown(with event: NSEvent) { onRightClick?(event) }

    // File drops. The controller decides from the island's state; this view only reports the URLs.
    // `.copy` never lets Finder alter the source (unlike `.move`), and nothing here opens the files.
    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation { dragOperation?() ?? [] }
    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation { dragOperation?() ?? [] }
    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        let urls = sender.draggingPasteboard.readObjects(
            forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
        return onDrop?(urls) ?? false
    }
}

/// The panel never becomes key, so the first click must act immediately instead of "activating".
final class IslandHostingView: NSHostingView<IslandView> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

final class IslandController {
    private let model = IslandModel()
    private let nowPlaying = NowPlaying()
    private let droppedFiles = DroppedFiles()
    private let systemVolume = SystemVolume()
    private let quickLaunch = QuickLaunchApps()
    private let pointer = IslandPointer()
    private let fileSearch = FileSearch()
    private let power = PowerSource()
    private let terminal = QuickTerminal()
    private let converter = Converter()
    private let settings = AppSettings.shared
    private var settingsObservers: Set<AnyCancellable> = []
    /// The app that had focus when a typing page opened, to hand focus back on Escape.
    private var appBeforeKeyboard: NSRunningApplication?
    /// After an action collapses the island (launching an app), hover stays off until the pointer
    /// leaves; otherwise the island would reopen under the still-resting cursor.
    private var holdUntilPointerLeaves = false
    private var screen: NSScreen
    private var geometry: IslandGeometry
    private let panel: IslandPanel
    private let contentView = IslandContentView()
    private var hostingView: IslandHostingView
    private var monitors: [Any] = []
    private var pendingTransition: Timer?
    /// Drag-pasteboard change count when the mouse button went down; a change while it's held means a drag began.
    private var dragBaseline = 0
    /// What the current press turned out to be: still unknown (since when, from where), not a file
    /// drag, or a file drag. The pasteboard is only read until this is known.
    private enum PressKind { case undecided(since: CFTimeInterval, from: NSPoint), notFileDrag, fileDrag }
    private var press: PressKind = .notFileDrag
    /// Whether the panel currently takes mouse events; nil until first set.
    private var capturesMouse: Bool?
    /// Runs only while the mouse button is held, to follow file drags from other apps.
    private var dragWatch: Timer?
    private let pinnedState: IslandState?
    /// Set only by `--simulate-drag`, to log when the stage changes.
    private var simulating = false
    private var simulationStart: CFTimeInterval = 0
    /// Where the pointer is and whether the main button is down. Only `--simulate-drag` swaps them.
    private var pointerLocation: () -> NSPoint = { NSEvent.mouseLocation }
    private var primaryButtonDown: () -> Bool = { NSEvent.pressedMouseButtons & 1 != 0 }

    /// `pinnedState` freezes the island in one state (used only by `--state` for verification).
    init(pinnedState: IslandState? = nil) {
        self.pinnedState = pinnedState
        screen = NSScreen.screens.first ?? NSScreen.main!
        geometry = IslandGeometry(screen: screen)
        hostingView = IslandHostingView(rootView: IslandView(model: model, nowPlaying: nowPlaying, files: droppedFiles,
                                                             volume: systemVolume, apps: quickLaunch, pointer: pointer,
                                                             search: fileSearch, terminal: terminal,
                                                             terminalStatus: terminal.status, converter: converter,
                                          convertLayout: converter.layout, power: power, geometry: geometry))

        panel = IslandPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel],
                            backing: .buffered, defer: false)
        panel.isFloatingPanel = true
        panel.level = NSWindow.Level(rawValue: NSWindow.Level.mainMenu.rawValue + 3) // above the menu bar
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = false
        panel.hidesOnDeactivate = false
        panel.isMovable = false
        panel.isReleasedWhenClosed = false
        panel.animationBehavior = .none
        panel.acceptsMouseMovedEvents = true
        setCapturesMouse(false)

        contentView.wantsLayer = true
        contentView.addSubview(hostingView)
        contentView.registerForDraggedTypes([.fileURL, .URL, .string, .tiff, .png])
        contentView.onClick = { [weak self] in self?.setState(.expanded) }
        contentView.onRightClick = { [weak self] event in self?.showMenu(for: event) }
        // The whole drop zone takes the file (the panel only catches the mouse while it's over it).
        contentView.dragOperation = { [weak self] in self?.model.state == .dropOver ? .copy : [] }
        contentView.onDrop = { [weak self] urls in self?.receiveDrop(urls) ?? false }
        model.requestState = { [weak self] state in self?.setState(state) }
        model.dismiss = { [weak self] in self?.dismissAfterAction() }
        systemVolume.onChange = { [weak self] in self?.showSystemFeedback(.volume, for: IslandMotion.systemFeedbackDuration) }
        power.onFeedback = { [weak self] untilDecided in
            // While the charger negotiates, stay up until the model decides (it calls again).
            self?.showSystemFeedback(.power, for: untilDecided ? PowerSource.chargeStartGrace + 1 : IslandMotion.powerFeedbackDuration)
        }
        // A command that finishes while its page is closed says so briefly ("Done ✓", "Failed ✕").
        // Files dropped on the island open the converter; "Keep in shelf" sends them to Dropped Files.
        converter.onClose = { [weak self] in self?.setState(.resting) }
        converter.onKeepInShelf = { [weak self] urls in self?.keepInShelf(urls) }
        converter.onFinished = { [weak self] in self?.conversionFinished() }
        // The page grows and shrinks with its content: keep catching clicks over all of it.
        converter.layout.$height.dropFirst()
            .sink { [weak self] _ in DispatchQueue.main.async { self?.refreshMouseCapture() } }
            .store(in: &settingsObservers)
        terminal.onFinish = { [weak self] _ in
            guard let self, self.model.state != .terminal else { return }
            self.showSystemFeedback(.terminalResult, for: TerminalLayout.resultDuration)
        }
        panel.contentView = contentView

        layout()
        panel.orderFrontRegardless()

        if let pinnedState {
            model.state = pinnedState
            contentView.routesClicksToContent = pinnedState.isOpen
            setCapturesMouse(true)
        } else {
            startTracking()
        }

        // Clicking into another app while typing takes focus away: close the search / Quick Terminal.
        NotificationCenter.default.addObserver(forName: NSWindow.didResignKeyNotification, object: panel, queue: .main) { [weak self] _ in
            guard let self, self.model.state.takesKeyboard else { return }
            // A conversion in progress, or its result, stays until it's dismissed or times out.
            if self.model.state == .convert, self.converter.phase != .choosing { return }
            self.appBeforeKeyboard = nil
            self.setState(.resting)
        }
        observeShortcuts()
        // Load what the drop zone draws now, rather than during the first drag.
        DispatchQueue.main.async { DropZoneView.prewarm() }
        NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification,
                                               object: nil, queue: .main) { [weak self] _ in self?.screenChanged() }
        logGeometry()
    }

    // MARK: Layout

    private func layout() {
        let size = geometry.canvasSize
        let frame = NSRect(x: (screen.frame.midX - size.width / 2).rounded(), y: screen.frame.maxY - size.height,
                           width: size.width, height: size.height)
        panel.setFrame(frame, display: true)
        hostingView.frame = NSRect(origin: .zero, size: size)
    }

    private func screenChanged() {
        screen = NSScreen.screens.first ?? screen
        geometry = IslandGeometry(screen: screen)
        hostingView.rootView = IslandView(model: model, nowPlaying: nowPlaying, files: droppedFiles,
                                          volume: systemVolume, apps: quickLaunch, pointer: pointer,
                                          search: fileSearch, terminal: terminal,
                                          terminalStatus: terminal.status, converter: converter,
                                          convertLayout: converter.layout, power: power, geometry: geometry)
        layout()
        logGeometry()
    }

    // MARK: Hover tracking

    private func startTracking() {
        let mask: NSEvent.EventTypeMask = [.mouseMoved, .leftMouseDragged, .rightMouseDragged]
        // Global monitors see the cursor while other apps are frontmost; local ones while it's over the island.
        if let global = NSEvent.addGlobalMonitorForEvents(matching: mask, handler: { [weak self] _ in self?.cursorMoved() }) {
            monitors.append(global)
        }
        if let local = NSEvent.addLocalMonitorForEvents(matching: mask, handler: { [weak self] event in
            self?.cursorMoved()
            return event
        }) {
            monitors.append(local)
        }
        if let down = NSEvent.addGlobalMonitorForEvents(matching: .leftMouseDown, handler: { [weak self] _ in self?.watchForFileDrag() }) {
            monitors.append(down)
        }
    }

    private func cursorMoved() {
        let state = model.state
        // Transients (file drags, the drop confirmation) own the island until they finish.
        guard !state.isTransient else { return }
        let inside = geometry.hotZone(for: state, on: screen, fileRows: droppedFiles.items.count,
                                      searchRows: fileSearch.visibleRows,
                                      terminalExpanded: terminal.status.expanded, convertHeight: converter.layout.height,
                                      activity: IslandActivity.current(nowPlaying: nowPlaying, power: power))
            .contains(pointerLocation())
        // Only capture the mouse while it's over the island; everywhere else clicks pass straight through.
        setCapturesMouse(inside)
        publishPointer(inside && state == .expanded)
        if holdUntilPointerLeaves {
            if !inside { holdUntilPointerLeaves = false }
            return
        }

        if inside {
            if state == .resting {
                setState(.hover)
                schedule(.expanded, after: IslandMotion.expandDwell)
            } else if state.isOpen, pendingTransition != nil {
                cancelPending() // came back before the collapse fired
            }
        } else if state.collapsesOnPointerExit {
            if pendingTransition == nil { schedule(.resting, after: IslandMotion.collapseGrace) }
        } else if state == .convert, converter.phase == .done {
            // A finished conversion closes once the pointer has moved off it.
            if pendingTransition == nil { schedule(.resting, after: ConvertLayout.leaveGrace) }
        } else if state == .hover {
            setState(.resting)
        }
    }

    // MARK: File drags

    /// The mouse went down somewhere on screen: it may be the start of a file drag.
    private func watchForFileDrag() {
        dragBaseline = NSPasteboard(name: .drag).changeCount
        press = .undecided(since: CACurrentMediaTime(), from: pointerLocation())
        dragWatch?.invalidate()
        let timer = Timer(timeInterval: 1.0 / 60, repeats: true) { [weak self] _ in self?.followFileDrag() }
        RunLoop.main.add(timer, forMode: .common)
        dragWatch = timer
    }

    /// Runs 60 times a second while the button is down, and does as little as possible:
    ///  - until the press is known to be a file drag, it waits for the pointer to move, then asks
    ///    the drag pasteboard once whether a drag of files began (and gives up on presses that
    ///    turn out not to be one, stopping the timer);
    ///  - during a file drag it only reads the pointer position and works out the zone stage
    ///    (far / close / over). The island changes only when that stage changes: a few times per
    ///    drag, not every tick. Nothing here touches the window unless something actually changed.
    private func followFileDrag() {
        let dragging = model.state.isDropTarget
        guard primaryButtonDown() else {
            stopWatchingDrag()
            // Released. A drop on the zone arrives via performDragOperation; if none comes, the file
            // went somewhere else or the drag was cancelled: the zone folds away.
            if dragging { schedule(.resting, after: IslandMotion.dropDeliveryGrace) }
            return
        }
        let point = pointerLocation()
        switch press {
        case .notFileDrag:
            stopWatchingDrag()
            return
        case .undecided(let since, let origin):
            // A press that hasn't moved isn't a drag yet: nothing to ask.
            guard abs(point.x - origin.x) + abs(point.y - origin.y) > 3 else { return }
            let pasteboard = NSPasteboard(name: .drag)
            if pasteboard.changeCount != dragBaseline {
                press = pasteboard.types?.contains(.fileURL) == true ? .fileDrag : .notFileDrag
            } else if CACurrentMediaTime() - since > 1 {
                press = .notFileDrag // moving for a while with no drag: selecting text, moving a window…
            }
            guard case .fileDrag = press else { return }
            // A running conversion keeps the island (a drop then would be declined anyway).
            if model.state == .convert, converter.isWorking { press = .notFileDrag; return }
            print("file drag started: drop zone shown")
        case .fileDrag:
            break
        }

        let stage = geometry.dropStage(at: point, on: screen, current: model.state)
        guard stage != model.state else { return }
        // Catch the mouse (and so the drop) only over the zone; everywhere else stays click-through,
        // so the file can still be dropped on other apps.
        setCapturesMouse(stage == .dropOver)
        if simulating { print(String(format: "stage → %@ at %.2f s", stage.rawValue, CACurrentMediaTime() - simulationStart)) }
        setState(stage)
    }

    private func stopWatchingDrag() {
        dragWatch?.invalidate()
        dragWatch = nil
        press = .notFileDrag
    }

    /// Whether the panel takes mouse events, changed only when it actually changes: every change
    /// is a window-server transaction, and one made while Core Animation is committing a frame
    /// makes that frame wait for the window server (measured as 300–770 ms stalls during a drag
    /// when this was set on every tick).
    private func setCapturesMouse(_ capture: Bool) {
        guard capturesMouse != capture else { return }
        capturesMouse = capture
        panel.ignoresMouseEvents = !capture
    }

    private func receiveDrop(_ urls: [URL]) -> Bool {
        guard model.state == .dropOver, !urls.isEmpty else {
            print("drop rejected (state \(model.state.rawValue), \(urls.count) file URL(s))")
            return false
        }
        print("drop received: \(urls.count) item(s)")
        for url in urls { print("  \(url.path)") }
        guard converter.load(urls) else {
            // One conversion at a time: show the one that's running, and hand the files back.
            print("drop declined: a conversion is running")
            setState(.convert)
            return false
        }
        setState(.convert)
        return true
    }

    /// "Keep in shelf": the files go to Dropped Files, with the usual confirmation.
    private func keepInShelf(_ urls: [URL]) {
        droppedFiles.add(urls)
        setState(.dropReceived)
        schedule(.resting, after: IslandMotion.dropConfirmation)
    }

    /// A conversion ended. Its result is shown even if the island has closed meanwhile (when it's
    /// free), and goes away on its own if the pointer isn't on it.
    private func conversionFinished() {
        guard converter.phase == .done, pinnedState == nil else { return }
        if model.state != .convert {
            guard model.state.isCompact else { return }
            setState(.convert)
        }
        let inside = geometry.hotZone(for: .convert, on: screen, convertHeight: converter.layout.height).contains(NSEvent.mouseLocation)
        if !inside { schedule(.resting, after: ConvertLayout.doneLinger) }
    }

    // MARK: Keyboard (File Search, Quick Terminal)

    private func beginKeyboardSession(for state: IslandState) {
        // The converter only needs the keyboard while choosing; showing a result or progress
        // shouldn't take focus from the app in front.
        if state == .convert, converter.phase != .choosing {
            panel.allowsKeyboard = true
            return
        }
        switch state {
        case .search:
            fileSearch.reset()
            fileSearch.checkFolderAccess()
        default:
            break
        }
        if appBeforeKeyboard == nil { appBeforeKeyboard = NSWorkspace.shared.frontmostApplication }
        panel.allowsKeyboard = true
        panel.makeKey()
        print("\(state.rawValue): keyboard focus taken (was \(appBeforeKeyboard?.localizedName ?? "none"))")
    }

    /// Gives keyboard focus back. After Escape the previous app is refocused; after opening a file the
    /// file's app takes focus itself; after a click elsewhere that app already has it.
    private func endKeyboardSession() {
        panel.allowsKeyboard = false
        if panel.isKeyWindow { panel.resignKey() }
        if let app = appBeforeKeyboard, app != NSRunningApplication.current { app.activate() }
        appBeforeKeyboard = nil
        fileSearch.reset()
        print("keyboard focus released")
    }

    /// Pointer position in canvas coordinates (top-left origin) for hover effects inside the
    /// expanded island; nil whenever it isn't over it. Only publishes actual changes.
    private func publishPointer(_ over: Bool) {
        let mouse = NSEvent.mouseLocation
        let location = over ? CGPoint(x: mouse.x - panel.frame.minX, y: panel.frame.maxY - mouse.y) : nil
        if pointer.location != location { pointer.location = location }
    }

    /// Collapse to the pill after an action inside the island, without reopening under the cursor.
    private func dismissAfterAction() {
        holdUntilPointerLeaves = true
        appBeforeKeyboard = nil // an opened file or app takes focus itself
        setState(.resting)
    }

    // MARK: System feedback

    /// Shows (or keeps alive) system feedback (volume, power), if the island is in a state that
    /// allows it, and restarts its timeout. Home comes back afterwards; the activity underneath is
    /// untouched.
    private func showSystemFeedback(_ feedback: IslandState, for duration: TimeInterval) {
        guard pinnedState == nil, model.state.acceptsSystemFeedback else { return }
        if model.state != feedback { setState(feedback) }
        schedule(.resting, after: duration)
    }

    private func schedule(_ state: IslandState, after delay: TimeInterval) {
        cancelPending()
        pendingTransition = Timer.scheduledTimer(withTimeInterval: delay, repeats: false) { [weak self] _ in
            self?.pendingTransition = nil
            self?.setState(state)
        }
    }

    private func cancelPending() {
        pendingTransition?.invalidate()
        pendingTransition = nil
    }

    private func setState(_ state: IslandState) {
        guard pinnedState == nil else { return }
        cancelPending()
        guard model.state != state else { return }
        let previous = model.state
        model.state = state
        if previous == .convert, state != .convert { converter.reset() }
        if state.takesKeyboard { beginKeyboardSession(for: state) }
        if previous.takesKeyboard, !state.takesKeyboard { endKeyboardSession() }
        contentView.routesClicksToContent = state.isOpen
        let rows = droppedFiles.items.count
        print("state → \(state.rawValue): \(geometry.spec(for: state, fileRows: rows, terminalExpanded: terminal.status.expanded, convertHeight: converter.layout.height, activity: IslandActivity.current(nowPlaying: nowPlaying, power: power)))"
              + (state == .files ? " — \(rows) dropped item(s)" : ""))
        // Re-evaluate right away: the hot zone just changed size.
        refreshMouseCapture()
    }

    /// Catch the mouse only while it's over the island's current shape.
    private func refreshMouseCapture() {
        guard pinnedState == nil, !model.state.isDropTarget else { return }
        setCapturesMouse(geometry.hotZone(for: model.state, on: screen, fileRows: droppedFiles.items.count,
                                          searchRows: fileSearch.visibleRows, terminalExpanded: terminal.status.expanded,
                                          convertHeight: converter.layout.height,
                                          activity: IslandActivity.current(nowPlaying: nowPlaying, power: power))
            .contains(pointerLocation()))
    }

    // MARK: Hotkeys (Quick Terminal)

    /// Registers the Quick Terminal hotkey, and again whenever it is changed in Settings (suspended while
    /// Settings records a new one).
    private func observeShortcuts() {
        guard pinnedState == nil else { return }
        settings.$terminalShortcut.combineLatest(settings.$isRecordingShortcut)
            .sink { [weak self] shortcut, recording in
                guard let self else { return }
                if recording {
                    GlobalHotKeys.shared.unregister(.terminal)
                    return
                }
                let ok = GlobalHotKeys.shared.register(.terminal, shortcut) { [weak self] in self?.togglePage(.terminal) }
                print("terminal: hotkey \(shortcut.displayString) \(ok ? "registered" : "UNAVAILABLE (another app owns it)")")
                if self.settings.terminalShortcutUnavailable != !ok { self.settings.terminalShortcutUnavailable = !ok }
            }
            .store(in: &settingsObservers)
    }

    /// A hotkey opens its page from anywhere, or closes it if it's open. A file drag in progress
    /// keeps the island.
    private func togglePage(_ page: IslandState) {
        guard pinnedState == nil else { return }
        if model.state == page {
            setState(.resting)
        } else if !model.state.isDropTarget && model.state != .dropReceived {
            holdUntilPointerLeaves = false
            setState(page)
        }
    }

    // MARK: Menu

    private func showMenu(for event: NSEvent) {
        let menu = NSMenu()
        let settingsItem = NSMenuItem(title: "Settings…", action: #selector(SettingsWindowController.showSettings(_:)), keyEquivalent: ",")
        settingsItem.target = SettingsWindowController.shared
        menu.addItem(settingsItem)
        let terminalItem = NSMenuItem(title: "Quick Terminal  \(settings.terminalShortcut.displayString)",
                                      action: #selector(MenuAction.run), keyEquivalent: "")
        let openTerminal = MenuAction { [weak self] in self?.togglePage(.terminal) }
        terminalItem.target = openTerminal
        terminalItem.representedObject = openTerminal // the item keeps its target alive
        menu.addItem(terminalItem)
        menu.addItem(.separator())
        menu.addItem(withTitle: "Quit IslandMac", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        NSMenu.popUpContextMenu(menu, with: event, for: contentView)
    }

    // MARK: Diagnostics

    private func logGeometry() {
        print("""
        IslandMac geometry
          screen:     \(screen.frame) visible \(screen.visibleFrame) scale \(screen.backingScaleFactor)
          menu bar:   \(geometry.menuBarHeight) pt
          panel:      \(panel.frame) level \(panel.level.rawValue)
          resting:    \(geometry.spec(for: .resting))
          hover:      \(geometry.spec(for: .hover))
          expanded:   \(geometry.spec(for: .expanded)) idle, \(geometry.spec(for: .expanded, activity: .nowPlaying)) with music
          drop zone:  \(geometry.spec(for: .dropApproach)), close by \(geometry.spec(for: .dropNear)), over \(geometry.spec(for: .dropOver))
          received:   \(geometry.spec(for: .dropReceived))
          calendar:   \(geometry.spec(for: .calendar))
          volume:     \(geometry.spec(for: .volume))
          power:      \(geometry.spec(for: .power)), low battery \(geometry.spec(for: .resting, activity: .battery(.low)))
          terminal:   \(geometry.spec(for: .terminal)) field, \(geometry.spec(for: .terminal, terminalExpanded: true)) with output
          convert:    \(geometry.spec(for: .convert, convertHeight: ConvertLayout.height(phase: .choosing, rows: 1))) choosing, \(geometry.spec(for: .convert, convertHeight: ConvertLayout.height(phase: .working, rows: 1))) working
          pinned:     \(pinnedState?.rawValue ?? "no")
        """)
    }
}

/// A menu item's target that runs a closure (IslandController isn't an NSObject).
private final class MenuAction: NSObject {
    private let action: () -> Void
    init(_ action: @escaping () -> Void) { self.action = action }
    @objc func run() { action() }
}

// MARK: - Profiling

extension IslandController {
    /// Profiling only (`--simulate-drag <seconds>`): plays a file drag along a scripted path
    /// through the same code a real one runs (the drag pasteboard, mouse-dragged events at 120 Hz,
    /// the drop zone and its stages) and logs how long the main thread was ever unavailable.
    func simulateFileDrag(seconds: Double) {
        let start = Date()
        simulating = true
        simulationStart = CACurrentMediaTime()
        let frame = NSScreen.screens.first?.frame ?? .zero
        // Far away, up toward the notch, across the zone, away again, back over it, away.
        let stops: [NSPoint] = [NSPoint(x: frame.minX + 200, y: frame.minY + 200), NSPoint(x: frame.midX - 400, y: frame.maxY - 300),
                                NSPoint(x: frame.midX, y: frame.maxY - 80), NSPoint(x: frame.midX + 300, y: frame.maxY - 260),
                                NSPoint(x: frame.midX - 20, y: frame.maxY - 60), NSPoint(x: frame.maxX - 200, y: frame.minY + 300)]
        let leg = seconds / Double(stops.count - 1)
        pointerLocation = {
            let t = min(Date().timeIntervalSince(start), seconds - 0.001)
            let i = Int(t / leg), f = (t - Double(i) * leg) / leg
            let a = stops[i], b = stops[i + 1]
            return NSPoint(x: a.x + (b.x - a.x) * f, y: a.y + (b.y - a.y) * f)
        }
        primaryButtonDown = { Date().timeIntervalSince(start) < seconds }
        // Mouse down, then the drag pasteboard changes as the drag begins.
        watchForFileDrag()
        let pasteboard = NSPasteboard(name: .drag)
        pasteboard.clearContents()
        pasteboard.writeObjects([FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Desktop") as NSURL])
        // A real drag sends mouse-dragged events the whole way.
        let events = Timer(timeInterval: 1.0 / 120, repeats: true) { [weak self] timer in
            guard Date().timeIntervalSince(start) < seconds else { timer.invalidate(); return }
            self?.cursorMoved()
        }
        RunLoop.main.add(events, forMode: .common)
        StallMeter.run(for: seconds + 1)
    }
}

/// Profiling only: a 240 Hz timer on the main run loop. Any gap well over 1/240 s is time the main
/// thread couldn't respond (and so couldn't draw).
enum StallMeter {
    static func run(for seconds: Double) {
        let start = CACurrentMediaTime()
        var last = start, gaps: [Double] = [], ticks = 0
        let timer = Timer(timeInterval: 1.0 / 240, repeats: true) { timer in
            let now = CACurrentMediaTime()
            if now - last > 1.0 / 60 { print(String(format: "stall meter: %.0f ms gap at %.2f s", (now - last) * 1000, last - start)) }
            gaps.append(now - last); last = now; ticks += 1
            guard now - start >= seconds else { return }
            timer.invalidate()
            let sorted = gaps.sorted()
            let over = { (limit: Double) in gaps.filter { $0 > limit }.count }
            print(String(format: "stall meter: %d ticks in %.1f s; gaps >16.7 ms: %d, >33 ms: %d, >100 ms: %d; worst %.0f ms, p99 %.1f ms",
                         ticks, now - start, over(1.0 / 60), over(1.0 / 30), over(0.1), (sorted.last ?? 0) * 1000,
                         sorted[Int(Double(sorted.count - 1) * 0.99)] * 1000))
        }
        RunLoop.main.add(timer, forMode: .common)
    }
}

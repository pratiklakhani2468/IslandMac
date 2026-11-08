import AppKit

struct Track: Equatable {
    var id: String
    var title: String
    var artist: String
    var duration: TimeInterval
}

/// Now Playing for Music.app.
///
/// macOS 15.4+ refuses the system-wide Now Playing info (MediaRemote) to third-party apps, so this
/// talks to Music directly: its `com.apple.Music.playerInfo` broadcast (no permission needed) tells
/// us when anything changes, and Apple Events (Automation permission, asked once) read the state,
/// position and artwork and send the transport commands.
final class NowPlaying: ObservableObject {
    @Published private(set) var track: Track?
    @Published private(set) var artwork: NSImage?
    @Published private(set) var isPlaying = false
    /// Playback position sampled at `positionDate`; `position(at:)` extrapolates while playing.
    @Published private(set) var position: TimeInterval = 0
    @Published private(set) var positionDate = Date()

    /// All Apple Events go through this serial queue so the UI never waits on Music.
    private let queue = DispatchQueue(label: "islandmac.music-events")
    private var refreshInFlight = false
    private var refreshAgain = false
    /// After play/pause or seek, Music acknowledges before its state catches up. Until this time
    /// the optimistic `isPlaying`/`position` win over what reads report, so the UI doesn't flicker back.
    private var optimisticUntil = Date.distantPast
    private var artworkTrackID: String?
    /// Catches position changes Music doesn't broadcast (e.g. scrubbing inside Music itself).
    private var resyncTimer: Timer?

    init() {
        DistributedNotificationCenter.default().addObserver(
            forName: .init("com.apple.Music.playerInfo"), object: nil, queue: .main) { [weak self] _ in self?.refresh() }
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didTerminateApplicationNotification, object: nil, queue: .main) { [weak self] note in
            let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            if app?.bundleIdentifier == MusicEvents.bundleID { self?.clear() }
        }
        refresh()
        if CommandLine.arguments.contains("--debug-media") { listenForDebugCommands() }
    }

    func position(at date: Date) -> TimeInterval {
        guard let track else { return 0 }
        let p = isPlaying ? position + date.timeIntervalSince(positionDate) : position
        return min(max(0, p), track.duration)
    }

    // MARK: Reading

    func refresh() {
        guard !NSRunningApplication.runningApplications(withBundleIdentifier: MusicEvents.bundleID).isEmpty else {
            clear()
            return
        }
        // Music broadcasts in bursts; coalesce so at most one read is queued behind the current one.
        guard !refreshInFlight else { refreshAgain = true; return }
        refreshInFlight = true
        queue.async {
            let snapshot = MusicEvents.attempt("read state") { try MusicEvents.snapshot() }
            DispatchQueue.main.async {
                self.refreshInFlight = false
                self.apply(snapshot)
                if self.refreshAgain { self.refreshAgain = false; self.refresh() }
            }
        }
    }

    private func apply(_ snapshot: MusicEvents.Snapshot?) {
        guard let snapshot, let t = snapshot.track else { clear(); return }
        let settled = Date() >= optimisticUntil
        let playing = settled ? snapshot.isPlaying : isPlaying
        let changed = t != track || playing != isPlaying
        track = t
        isPlaying = playing
        if settled {
            position = snapshot.position
            positionDate = Date()
        }
        if changed {
            print("media: \(t.title) — \(t.artist) [\(isPlaying ? "playing" : "paused")] \(Int(position))s / \(Int(t.duration))s")
        }
        if artworkTrackID != t.id { loadArtwork(for: t.id) }
        updateResyncTimer()
    }

    private func loadArtwork(for trackID: String) {
        artworkTrackID = trackID
        queue.async {
            let data = MusicEvents.attempt("read artwork") { try MusicEvents.artworkData() } ?? nil
            let image = data.flatMap(NSImage.init(data:))
            DispatchQueue.main.async {
                guard self.track?.id == trackID else { return }
                self.artwork = image
                let size = image.map { "\(Int($0.size.width))×\(Int($0.size.height))" } ?? "none"
                print("artwork: \(size) for \(self.track?.title ?? "")")
            }
        }
    }

    private func updateResyncTimer() {
        if isPlaying, resyncTimer == nil {
            resyncTimer = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { [weak self] _ in self?.refresh() }
        } else if !isPlaying {
            resyncTimer?.invalidate()
            resyncTimer = nil
        }
    }

    private func clear() {
        resyncTimer?.invalidate()
        resyncTimer = nil
        artworkTrackID = nil
        artwork = nil
        guard track != nil else { return }
        track = nil
        isPlaying = false
        print("media: none")
    }

    // MARK: Controls

    func togglePlayPause() {
        // Flip immediately so the button responds; Music's broadcast confirms a moment later.
        position = position(at: Date())
        positionDate = Date()
        isPlaying.toggle()
        holdOptimisticState()
        command("playpause") { try MusicEvents.send("hook", "PlPs") }
    }

    func nextTrack() { command("next track") { try MusicEvents.send("hook", "Next") } }
    func previousTrack() { command("previous track") { try MusicEvents.send("hook", "Prev") } }

    func seek(to seconds: TimeInterval) {
        guard let track else { return }
        let target = min(max(0, seconds), track.duration)
        position = target
        positionDate = Date()
        holdOptimisticState()
        command("seek to \(Int(target))s") { try MusicEvents.setPlayerPosition(target) }
    }

    private func holdOptimisticState() {
        let window: TimeInterval = 0.8
        optimisticUntil = Date().addingTimeInterval(window)
        DispatchQueue.main.asyncAfter(deadline: .now() + window + 0.05) { [weak self] in self?.refresh() }
    }

    private func command(_ name: String, _ body: @escaping () throws -> Void) {
        print("command: \(name)")
        queue.async {
            _ = MusicEvents.attempt(name) { try body() }
            DispatchQueue.main.async { self.refresh() }
        }
    }

    /// `--debug-media` only: lets a script drive the same methods the buttons call, by posting
    /// `local.islandmac.debug` with object "toggle" | "next" | "previous" | "seek:<seconds>".
    private func listenForDebugCommands() {
        DistributedNotificationCenter.default().addObserver(
            forName: .init("local.islandmac.debug"), object: nil, queue: .main) { [weak self] note in
            guard let self, let command = note.object as? String else { return }
            switch command {
            case "toggle": self.togglePlayPause()
            case "next": self.nextTrack()
            case "previous": self.previousTrack()
            case let c where c.hasPrefix("seek:"): self.seek(to: Double(c.dropFirst(5)) ?? 0)
            default: break
            }
        }
        print("debug media commands enabled")
    }
}

/// Raw Apple Events to Music (codes from Music's scripting dictionary). Unlike NSAppleScript,
/// sending events is safe off the main thread, and an event to an app that isn't running fails
/// with procNotFound instead of launching it.
private enum MusicEvents {
    static let bundleID = "com.apple.Music"

    struct Snapshot {
        var isPlaying: Bool
        var track: Track?
        var position: TimeInterval
    }

    static func snapshot() throws -> Snapshot {
        let state = try get(property("pPlS"))?.enumCodeValue
        guard state != code("kPSS") else { return Snapshot(isPlaying: false, track: nil, position: 0) }
        let props = try get(property("pALL", of: property("pTrk")))
        // Between tracks or while stopping, Music can report an empty current track: treat as nothing playing.
        guard let id = props?.forKeyword(code("pPIS"))?.stringValue, !id.isEmpty else {
            return Snapshot(isPlaying: false, track: nil, position: 0)
        }
        let track = Track(id: id,
                          title: props?.forKeyword(code("pnam"))?.stringValue ?? "",
                          artist: props?.forKeyword(code("pArt"))?.stringValue ?? "",
                          duration: props?.forKeyword(code("pDur"))?.doubleValue ?? 0)
        let position = try get(property("pPos"))?.doubleValue ?? 0
        return Snapshot(isPlaying: state == code("kPSP"), track: track, position: position)
    }

    /// Raw bytes of the current track's first artwork, or nil if it has none.
    static func artworkData() throws -> Data? {
        let firstArtwork = element("cArt", index: 1, of: property("pTrk"))
        do {
            return try get(property("pRaw", of: firstArtwork))?.data
        } catch let error as NSError where error.code == -1728 { // errAENoSuchObject: no artwork
            return nil
        }
    }

    static func setPlayerPosition(_ seconds: TimeInterval) throws {
        try send("core", "setd", directObject: property("pPos"), data: NSAppleEventDescriptor(double: seconds))
    }

    @discardableResult
    static func send(_ eventClass: String, _ eventID: String, directObject: NSAppleEventDescriptor? = nil,
                     data: NSAppleEventDescriptor? = nil) throws -> NSAppleEventDescriptor? {
        let event = NSAppleEventDescriptor.appleEvent(
            withEventClass: code(eventClass), eventID: code(eventID),
            targetDescriptor: NSAppleEventDescriptor(bundleIdentifier: bundleID),
            returnID: AEReturnID(kAutoGenerateReturnID), transactionID: AETransactionID(kAnyTransactionID))
        if let directObject { event.setParam(directObject, forKeyword: code("----")) }
        if let data { event.setParam(data, forKeyword: code("data")) }
        // .canInteract lets macOS show the one-time "IslandMac wants to control Music" prompt.
        let reply = try event.sendEvent(options: [.waitForReply, .canInteract], timeout: 3)
        return reply.paramDescriptor(forKeyword: code("----"))
    }

    /// Runs `body`, logging failures. -1743 means Automation permission for Music was denied
    /// (System Settings › Privacy & Security › Automation › IslandMac).
    static func attempt<T>(_ what: String, _ body: () throws -> T) -> T? {
        do { return try body() } catch {
            print("music \(what) failed: \((error as NSError).code) \(error.localizedDescription)")
            return nil
        }
    }

    private static func get(_ specifier: NSAppleEventDescriptor) throws -> NSAppleEventDescriptor? {
        try send("core", "getd", directObject: specifier)
    }

    private static func property(_ name: String, of container: NSAppleEventDescriptor = .null()) -> NSAppleEventDescriptor {
        specifier(want: "prop", form: "prop", data: NSAppleEventDescriptor(typeCode: code(name)), from: container)
    }

    private static func element(_ cls: String, index: Int32, of container: NSAppleEventDescriptor) -> NSAppleEventDescriptor {
        specifier(want: cls, form: "indx", data: NSAppleEventDescriptor(int32: index), from: container)
    }

    private static func specifier(want: String, form: String, data: NSAppleEventDescriptor,
                                  from container: NSAppleEventDescriptor) -> NSAppleEventDescriptor {
        let spec = NSAppleEventDescriptor.record().coerce(toDescriptorType: code("obj "))!
        spec.setDescriptor(NSAppleEventDescriptor(typeCode: code(want)), forKeyword: code("want"))
        spec.setDescriptor(NSAppleEventDescriptor(enumCode: code(form)), forKeyword: code("form"))
        spec.setDescriptor(data, forKeyword: code("seld"))
        spec.setDescriptor(container, forKeyword: code("from"))
        return spec
    }

    private static func code(_ s: String) -> FourCharCode {
        s.utf8.reduce(0) { $0 << 8 | FourCharCode($1) }
    }
}

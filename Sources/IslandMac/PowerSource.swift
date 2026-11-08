import Foundation
import IOKit.ps
import notify

/// The internal battery and whether the Mac is on power: the Charging feature's data, as
/// NowPlaying is music's.
///
/// Event-driven: `IOPSNotificationCreateRunLoopSource` calls back whenever any power source changes
/// (plugged in, unplugged, percentage, charging state), and macOS's time-remaining notification
/// (`kIOPSTimeRemainingNotificationKey`) as soon as it publishes a new time estimate; the state is
/// then read with the public IOPowerSources API. Nothing polls, nothing is estimated here, and no
/// permission is needed. A Mac without an internal battery never has a snapshot, so the island
/// never shows anything for it.
///
/// Two outputs:
///  - `onFeedback` for brief moments (plugged in, unplugged, fully charged), shown by the `.power`
///    transient; the transient reads the live snapshot, so a time estimate arriving mid-display
///    appears in place. macOS takes anywhere from ~10 s to 2 minutes (measured) to publish one
///    after power is connected or disconnected:
///    the time (to full while charging, left on battery) is left out until macOS has it; if it
///    arrives within `estimateWindow` after the moment has gone, the moment shows once more with
///    it, otherwise the moment simply stays without it;
///  - `warning` for a low battery while on battery power (the `.battery` activity's pill).
final class PowerSource: ObservableObject {
    struct Snapshot: Equatable {
        var percent: Int
        var onAC: Bool
        var isCharging: Bool
        /// The system's own "fully charged" flag (it only appears once charging has finished).
        var isCharged: Bool
        /// nil while macOS is still estimating (right after plugging in or unplugging), or when it
        /// doesn't apply.
        var minutesToFull: Int?
        var minutesToEmpty: Int?

        var isFull: Bool { isCharged || percent >= 100 }
    }

    /// Which brief moment the `.power` transient is showing.
    enum Feedback: Equatable {
        /// Just plugged in: charging, or held (optimized charging) — decided from the live snapshot
        /// and `awaitingCharge`.
        case pluggedIn
        case unplugged
        case charged
    }

    enum Warning: Int, Comparable {
        case low, critical
        static func < (a: Warning, b: Warning) -> Bool { a.rawValue < b.rawValue }
    }

    static let lowPercent = 20
    static let criticalPercent = 10
    /// After plugging in, the charger negotiates and the Mac reports "not charging" for a while
    /// before charging starts (measured: up to ~10 s on this MacBook). Only once it still isn't
    /// charging after this long is it "paused" (held by optimized charging or a charge limit).
    static let chargeStartGrace: TimeInterval = 10
    /// How long after a moment (charging, on battery) a late time estimate may still bring it
    /// back. Past this, it's left without the time (no late interruptions).
    static let estimateWindow: TimeInterval = 15

    @Published private(set) var snapshot: Snapshot?
    @Published private(set) var feedback: Feedback = .pluggedIn
    /// Plugged in, not charging yet, still within `chargeStartGrace`: "Plugged in" for now.
    @Published private(set) var awaitingCharge = false
    /// Called on the main queue when a moment should show. `untilDecided`: keep it up until the
    /// next call (the charger is still negotiating), rather than for the usual brief moment.
    var onFeedback: ((_ untilDecided: Bool) -> Void)?

    /// Low battery, only while running on it (plugged in is never a warning).
    var warning: Warning? {
        guard let snapshot, !snapshot.onAC else { return nil }
        if snapshot.percent <= Self.criticalPercent { return .critical }
        if snapshot.percent <= Self.lowPercent { return .low }
        return nil
    }

    private var runLoopSource: CFRunLoopSource?
    private var timeRemainingToken: Int32 = NOTIFY_TOKEN_INVALID
    private var chargeStartDeadline: DispatchWorkItem?
    /// The moment that went up without a time, while still waiting for macOS's estimate.
    private var awaitingEstimate: (moment: Feedback, since: Date)?
    /// `--debug-power` only: replaces what IOKit reports, so transitions can be exercised on demand.
    private var simulated: Snapshot?

    init() {
        let context = Unmanaged.passUnretained(self).toOpaque()
        if let source = IOPSNotificationCreateRunLoopSource({ context in
            guard let context else { return }
            Unmanaged<PowerSource>.fromOpaque(context).takeUnretainedValue().refresh()
        }, context)?.takeRetainedValue() {
            CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
            runLoopSource = source
        }
        // The power-source notification above also fires on most estimate changes; this one is
        // macOS's own "time remaining changed" signal, so a fresh estimate is picked up at once.
        notify_register_dispatch(kIOPSTimeRemainingNotificationKey, &timeRemainingToken, .main) { [weak self] _ in
            self?.refresh()
        }
        snapshot = Self.read()
        if CommandLine.arguments.contains("--debug-power") { listenForDebugCommands() }
        print("power: " + (snapshot.map { "\(Self.describe($0)), notifications \(runLoopSource != nil ? "on" : "UNAVAILABLE")" } ?? "no internal battery, hidden"))
    }

    deinit {
        if let runLoopSource { CFRunLoopRemoveSource(CFRunLoopGetMain(), runLoopSource, .commonModes) }
        if timeRemainingToken != NOTIFY_TOKEN_INVALID { notify_cancel(timeRemainingToken) }
    }

    // MARK: Changes

    private func refresh() {
        guard let new = simulated ?? Self.read() else { return }
        let old = snapshot
        guard new != old else { return }
        snapshot = new
        guard let old else { return }
        if new.onAC != old.onAC || new.isCharging != old.isCharging || new.isFull != old.isFull {
            print("power: \(Self.describe(new))")
        }

        if let waiting = awaitingEstimate,
           Date().timeIntervalSince(waiting.since) > Self.estimateWindow {
            print("power: no time estimate within \(Int(Self.estimateWindow)) s, left out")
            awaitingEstimate = nil
        }

        if new.onAC && !old.onAC {
            pluggedIn(new)
        } else if !new.onAC && old.onAC {
            stopAwaitingCharge()
            emit(.unplugged)
        } else if awaitingCharge, new.isCharging || new.isFull {
            // The charger has settled and charging began: the moment already showing becomes
            // "Charging" (or "Charged") and now collapses on the usual timer.
            stopAwaitingCharge()
            emit(new.isFull ? .charged : .pluggedIn)
        } else if new.onAC && new.isFull && !old.isFull {
            // Finished charging while plugged in.
            emit(.charged)
        } else if let waiting = awaitingEstimate, estimate(for: waiting.moment, in: new) != nil {
            // macOS has finished calculating: show the moment again, this time with the time.
            print("power: estimate arrived after \(Int(Date().timeIntervalSince(waiting.since))) s")
            emit(waiting.moment)
        }
    }

    /// The time a moment would show, if macOS has published it: time to full while charging,
    /// time left on battery. nil for moments that show no time, or while still calculating.
    private func estimate(for moment: Feedback, in s: Snapshot) -> Int? {
        switch moment {
        case .pluggedIn where s.onAC && s.isCharging && !s.isFull: s.minutesToFull
        case .unplugged where !s.onAC: s.minutesToEmpty
        default: nil
        }
    }

    /// Responds at once. If the Mac isn't charging yet, says "Plugged in" and stays up until it
    /// starts (→ "Charging") or the grace runs out (→ "Paused at X%").
    private func pluggedIn(_ s: Snapshot) {
        stopAwaitingCharge()
        if s.isFull || s.isCharging {
            emit(s.isFull ? .charged : .pluggedIn)
            return
        }
        awaitingCharge = true
        emit(.pluggedIn, untilDecided: true)
        let deadline = DispatchWorkItem { [weak self] in
            guard let self, self.awaitingCharge else { return }
            self.awaitingCharge = false
            guard self.snapshot?.onAC == true else { return }
            print("power: still not charging after \(Int(Self.chargeStartGrace)) s: held")
            self.emit(.pluggedIn)
        }
        chargeStartDeadline = deadline
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.chargeStartGrace, execute: deadline)
    }

    private func stopAwaitingCharge() {
        chargeStartDeadline?.cancel()
        chargeStartDeadline = nil
        awaitingCharge = false
    }

    private func emit(_ moment: Feedback, untilDecided: Bool = false) {
        feedback = moment
        // A moment that would show a time but has none yet keeps waiting for it; any other (or one
        // with its time) ends the wait. "Plugged in" is still undecided, so it doesn't wait yet.
        if let s = snapshot, !untilDecided,
           (moment == .unplugged && !s.onAC) || (moment == .pluggedIn && s.isCharging && !s.isFull),
           estimate(for: moment, in: s) == nil {
            awaitingEstimate = (moment, awaitingEstimate?.moment == moment ? awaitingEstimate!.since : Date())
        } else {
            awaitingEstimate = nil
        }
        print("power: showing \(moment)\(untilDecided ? " (waiting for charging to start)" : "")")
        onFeedback?(untilDecided)
    }

    // MARK: Reading

    /// The internal battery's state, or nil if this Mac has none.
    private static func read() -> Snapshot? {
        let info = IOPSCopyPowerSourcesInfo().takeRetainedValue()
        guard let sources = IOPSCopyPowerSourcesList(info)?.takeRetainedValue() as? [CFTypeRef] else { return nil }
        for source in sources {
            guard let d = IOPSGetPowerSourceDescription(info, source)?.takeUnretainedValue() as? [String: Any],
                  d[kIOPSTypeKey] as? String == kIOPSInternalBatteryType,
                  d[kIOPSIsPresentKey] as? Bool ?? true else { continue }
            let current = d[kIOPSCurrentCapacityKey] as? Int ?? 0
            let max = d[kIOPSMaxCapacityKey] as? Int ?? 100
            let percent = max > 0 ? Int((Double(current) / Double(max) * 100).rounded()) : current
            let onAC = d[kIOPSPowerSourceStateKey] as? String == kIOPSACPowerValue
            let charging = d[kIOPSIsChargingKey] as? Bool ?? false
            return Snapshot(percent: min(Swift.max(percent, 0), 100), onAC: onAC, isCharging: charging,
                            isCharged: d[kIOPSIsChargedKey] as? Bool ?? false,
                            // -1 (or 0) means "still estimating".
                            minutesToFull: (d[kIOPSTimeToFullChargeKey] as? Int).flatMap { $0 > 0 && charging ? $0 : nil },
                            minutesToEmpty: (d[kIOPSTimeToEmptyKey] as? Int).flatMap { $0 > 0 && !onAC ? $0 : nil })
        }
        return nil
    }

    /// "Full in 45 min", "Full in 1 hr 20 min", "Full in 2 hr": macOS's own time to full; nil
    /// (not published yet) stays nil, and the caller leaves it out.
    static func fullIn(_ minutes: Int?) -> String? {
        guard let minutes, minutes > 0 else { return nil }
        if minutes < 60 { return "Full in \(minutes) min" }
        return minutes % 60 == 0 ? "Full in \(minutes / 60) hr" : "Full in \(minutes / 60) hr \(minutes % 60) min"
    }

    /// "1h 20m", "2h", "45m"; nil stays nil (the caller leaves the estimate out).
    static func duration(_ minutes: Int?) -> String? {
        guard let minutes, minutes > 0 else { return nil }
        if minutes < 60 { return "\(minutes)m" }
        return minutes % 60 == 0 ? "\(minutes / 60)h" : "\(minutes / 60)h \(minutes % 60)m"
    }

    private static func describe(_ s: Snapshot) -> String {
        let state = !s.onAC ? "on battery" : s.isFull ? "charged" : s.isCharging ? "charging" : "plugged in, not charging"
        let time = s.onAC ? duration(s.minutesToFull).map { ", \($0) to full" } : duration(s.minutesToEmpty).map { ", \($0) left" }
        return "\(s.percent)% \(state)\(time ?? "")"
    }

    // MARK: Debug

    /// `--debug-power` only: post `local.islandmac.debug.power` with an object such as
    /// "ac=1 pct=74 charging=1 full=85" (keys: ac, pct, charging, charged, full, empty; minutes, -1
    /// = unknown) to replace IOKit's report, or "live" to go back to it. Transitions are detected
    /// exactly as for real ones.
    private func listenForDebugCommands() {
        DistributedNotificationCenter.default().addObserver(
            forName: .init("local.islandmac.debug.power"), object: nil, queue: .main) { [weak self] note in
            guard let self, let command = note.object as? String else { return }
            if command == "live" {
                self.simulated = nil
            } else {
                var s = self.simulated ?? self.snapshot ?? Snapshot(percent: 50, onAC: false, isCharging: false, isCharged: false)
                for pair in command.split(separator: " ") {
                    let kv = pair.split(separator: "=", maxSplits: 1).map(String.init)
                    guard kv.count == 2, let n = Int(kv[1]) else { continue }
                    switch kv[0] {
                    case "ac": s.onAC = n != 0
                    case "pct": s.percent = n
                    case "charging": s.isCharging = n != 0
                    case "charged": s.isCharged = n != 0
                    case "full": s.minutesToFull = n > 0 ? n : nil
                    case "empty": s.minutesToEmpty = n > 0 ? n : nil
                    default: break
                    }
                }
                self.simulated = s
            }
            print("power: debug \(command)")
            self.refresh()
        }
        print("debug power commands enabled")
    }
}

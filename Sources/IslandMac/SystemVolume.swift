import CoreAudio
import AudioToolbox

/// The default output device's volume and mute: the system volume feature's data, as NowPlaying is
/// music's. Observed with public CoreAudio property listeners (event-driven, nothing polls) and
/// follows the default output device when it changes (e.g. headphones connected).
///
/// Devices with no software volume (some HDMI/USB outputs) simply never report a change.
final class SystemVolume: ObservableObject {
    /// 0...1, the same value as the system volume slider.
    @Published private(set) var level: Float = 0
    @Published private(set) var isMuted = false
    /// Called on the main queue when volume or mute changes on the current device. Not called on
    /// launch or when the default device switches, only for actual changes.
    var onChange: (() -> Void)?

    private var device = AudioObjectID(kAudioObjectUnknown)
    private var watched: [AudioObjectPropertyAddress] = []
    private var lastLogged = ""
    /// Stored once so the same block can be removed when the default device changes.
    private lazy var listener: AudioObjectPropertyListenerBlock = { [weak self] _, _ in self?.read(notify: true) }

    init() {
        var defaultDevice = Self.address(kAudioHardwarePropertyDefaultOutputDevice, scope: kAudioObjectPropertyScopeGlobal)
        AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &defaultDevice, .main) { [weak self] _, _ in
            self?.attachToDefaultDevice()
        }
        attachToDefaultDevice()
    }

    private func attachToDefaultDevice() {
        for var address in watched { AudioObjectRemovePropertyListenerBlock(device, &address, .main, listener) }
        watched = []

        var id = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        var address = Self.address(kAudioHardwarePropertyDefaultOutputDevice, scope: kAudioObjectPropertyScopeGlobal)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &id) == noErr else { return }
        device = id

        for var candidate in [Self.volumeAddress, Self.muteAddress] where AudioObjectHasProperty(device, &candidate) {
            AudioObjectAddPropertyListenerBlock(device, &candidate, .main, listener)
            watched.append(candidate)
        }
        read(notify: false)
        print("volume: watching output device \(device) (\(watched.count) propert\(watched.count == 1 ? "y" : "ies")), level \(percent)%\(isMuted ? " muted" : "")")
    }

    private func read(notify: Bool) {
        var newLevel = level
        var volumeAddress = Self.volumeAddress
        if AudioObjectHasProperty(device, &volumeAddress) {
            var value = Float32(0)
            var size = UInt32(MemoryLayout<Float32>.size)
            if AudioObjectGetPropertyData(device, &volumeAddress, 0, nil, &size, &value) == noErr { newLevel = min(max(value, 0), 1) }
        }
        var newMuted = isMuted
        var muteAddress = Self.muteAddress
        if AudioObjectHasProperty(device, &muteAddress) {
            var value = UInt32(0)
            var size = UInt32(MemoryLayout<UInt32>.size)
            if AudioObjectGetPropertyData(device, &muteAddress, 0, nil, &size, &value) == noErr { newMuted = value != 0 }
        }
        // CoreAudio reports each change more than once; only act on real changes.
        guard newLevel != level || newMuted != isMuted else { return }
        level = newLevel
        isMuted = newMuted
        guard notify else { return }
        let summary = "\(percent)%\(isMuted ? " muted" : "")"
        if summary != lastLogged { lastLogged = summary; print("volume: \(summary)") }
        onChange?()
    }

    private var percent: Int { Int((level * 100).rounded()) }

    /// The system's main (virtual) output volume, as used by the volume keys and Control Center.
    private static let volumeAddress = address(AudioObjectPropertySelector(kAudioHardwareServiceDeviceProperty_VirtualMainVolume),
                                               scope: kAudioDevicePropertyScopeOutput)
    private static let muteAddress = address(kAudioDevicePropertyMute, scope: kAudioDevicePropertyScopeOutput)

    private static func address(_ selector: AudioObjectPropertySelector, scope: AudioObjectPropertyScope) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain)
    }
}

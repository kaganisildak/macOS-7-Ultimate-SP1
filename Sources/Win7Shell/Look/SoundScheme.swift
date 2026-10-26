import AppKit
import IOKit
import IOKit.usb
import Win7Core

/// Plays the Windows 7 sound scheme's event sounds from imported assets only (Assets/sounds/, see
/// scripts/win7-asset-map.txt). A missing file is silence. Nothing plays when macOS's "Play user
/// interface sound effects" is off or `defaults write com.win7mac.shell W7SoundsDisabled -bool YES`.
@MainActor
enum SoundPlayer {
    private static var playing: [NSSound] = []

    /// "Play user interface sound effects" lives in com.apple.systemsound (then the global domain), which
    /// UserDefaults.standard doesn't search, so it is read with CFPreferences.
    static var isEnabled: Bool {
        let setting = SoundScheme.uiSoundsSetting { key, domain in
            let app: CFString = domain == SoundScheme.globalDomain ? kCFPreferencesAnyApplication : domain as CFString
            return CFPreferencesCopyAppValue(key as CFString, app)
        }
        return SoundScheme.shouldPlay(uiSoundsSetting: setting, disabled: UserDefaults.standard.bool(forKey: SoundScheme.disabledKey))
    }

    /// Plays `event`'s sound; `done` runs when it finishes, or at once when nothing plays.
    static func play(_ event: SoundEvent, done: (() -> Void)? = nil) {
        guard isEnabled, let url = AssetStore.shared.url(event.assetPath),
              let sound = NSSound(contentsOf: url, byReference: true) else {
            done?()
            return
        }
        let delegate = SoundDone(sound: sound, done: done)
        sound.delegate = delegate
        objc_setAssociatedObject(sound, &SoundDone.key, delegate, .OBJC_ASSOCIATION_RETAIN)
        playing.append(sound)
        if !sound.play() { delegate.sound(sound, didFinishPlaying: false) }
    }

    fileprivate static func finished(_ sound: NSSound) { playing.removeAll { $0 === sound } }
}

private final class SoundDone: NSObject, NSSoundDelegate {
    nonisolated(unsafe) static var key = 0
    private let done: (() -> Void)?
    init(sound: NSSound, done: (() -> Void)?) { self.done = done }

    func sound(_ sound: NSSound, didFinishPlaying flag: Bool) {
        MainActor.assumeIsolated {
            SoundPlayer.finished(sound)
            done?()
        }
    }
}

/// Plays Device Connect / Disconnect when a USB device is attached or removed (IOKit matching
/// notifications on IOUSBHostDevice), debounced to one sound per kind per second and silent for 5 s after
/// wake, from willSleep on (DeviceSoundGate). Devices present at start are drained silently.
@MainActor
final class DeviceSoundMonitor {
    private var port: IONotificationPortRef?
    private var added: io_iterator_t = 0
    private var removed: io_iterator_t = 0
    private var gate = DeviceSoundGate()
    private var sleepTokens: [NSObjectProtocol] = []

    func start() {
        guard port == nil, let p = IONotificationPortCreate(kIOMainPortDefault) else { return }
        port = p
        let nc = NSWorkspace.shared.notificationCenter
        sleepTokens = [
            nc.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.gate.willSleep(at: Date()) }
            },
            nc.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.gate.didWake(at: Date()) }
            },
        ]
        CFRunLoopAddSource(CFRunLoopGetMain(), IONotificationPortGetRunLoopSource(p).takeUnretainedValue(), .defaultMode)
        let me = Unmanaged.passUnretained(self).toOpaque()
        let callback: IOServiceMatchingCallback = { refcon, iterator in
            guard let refcon else { return }
            let monitor = Unmanaged<DeviceSoundMonitor>.fromOpaque(refcon).takeUnretainedValue()
            MainActor.assumeIsolated { monitor.fired(iterator) }
        }
        IOServiceAddMatchingNotification(p, kIOFirstMatchNotification, IOServiceMatching("IOUSBHostDevice"), callback, me, &added)
        IOServiceAddMatchingNotification(p, kIOTerminatedNotification, IOServiceMatching("IOUSBHostDevice"), callback, me, &removed)
        // Arm both iterators; what is already there makes no sound.
        _ = Self.drain(added)
        _ = Self.drain(removed)
    }

    private func fired(_ iterator: io_iterator_t) {
        guard Self.drain(iterator) > 0 else { return }
        let event: SoundEvent = iterator == added ? .deviceConnect : .deviceDisconnect
        if gate.shouldPlay(event, at: Date()) { SoundPlayer.play(event) }
    }

    private static func drain(_ iterator: io_iterator_t) -> Int {
        var n = 0
        while case let obj = IOIteratorNext(iterator), obj != 0 {
            IOObjectRelease(obj)
            n += 1
        }
        return n
    }
}

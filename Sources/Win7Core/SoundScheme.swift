import Foundation

/// The Windows 7 sound scheme events the shell plays. Sounds come only from imported assets
/// (scripts/win7-asset-map.txt); a missing file is silence.
public enum SoundEvent: String, CaseIterable, Sendable {
    case navigation, emptyRecycleBin, deviceConnect, deviceDisconnect, logoff, shutdown

    /// Path under Assets/.
    public var assetPath: String {
        switch self {
        case .navigation: "sounds/navigation.wav"
        case .emptyRecycleBin: "sounds/recycle.wav"
        case .deviceConnect: "sounds/hardware-insert.wav"
        case .deviceDisconnect: "sounds/hardware-remove.wav"
        case .logoff: "sounds/logoff.wav"
        case .shutdown: "sounds/shutdown.wav"
        }
    }

    /// Log off plays the logoff sound; Shut down and Restart the shutdown sound; the rest nothing.
    public static func forPowerAction(_ action: PowerAction) -> SoundEvent? {
        switch action {
        case .logOff: .logoff
        case .shutDown, .restart: .shutdown
        case .sleep, .lock, .switchUser: nil
        }
    }
}

public enum SoundScheme {
    /// Global default behind System Settings > Sound > "Play user interface sound effects" (on when unset).
    public static let uiSoundsKey = "com.apple.sound.uiaudio.enabled"
    /// The shell's own switch: `defaults write com.win7mac.shell W7SoundsDisabled -bool YES`.
    public static let disabledKey = "W7SoundsDisabled"

    /// Where System Settings stores `uiSoundsKey`; read first.
    public static let systemSoundDomain = "com.apple.systemsound"
    /// Stands for the global domain (kCFPreferencesAnyApplication); read second.
    public static let globalDomain = "kCFPreferencesAnyApplication"

    /// The raw `uiSoundsKey` value: `read(key, domain)` in `systemSoundDomain`, then `globalDomain`.
    public static func uiSoundsSetting(_ read: (_ key: String, _ domain: String) -> Any?) -> Any? {
        read(uiSoundsKey, systemSoundDomain) ?? read(uiSoundsKey, globalDomain)
    }

    /// `uiSoundsSetting` is the raw value of `uiSoundsKey` (nil when unset).
    public static func shouldPlay(uiSoundsSetting: Any?, disabled: Bool) -> Bool {
        if disabled { return false }
        if let n = uiSoundsSetting as? NSNumber { return n.boolValue }
        if let b = uiSoundsSetting as? Bool { return b }
        return true
    }
}

/// Coalesces bursts of one event (a USB device fires a notification per interface): an event plays only
/// after `interval` seconds without another notification of the same kind.
public struct SoundDebouncer: Sendable {
    public let interval: TimeInterval
    private var last: [SoundEvent: Date] = [:]

    public init(interval: TimeInterval = 1) {
        self.interval = interval
    }

    public mutating func shouldPlay(_ event: SoundEvent, at now: Date) -> Bool {
        defer { last[event] = now }
        guard let prev = last[event] else { return true }
        return now.timeIntervalSince(prev) >= interval
    }
}

/// Device Connect / Disconnect: debounced, and silent from the moment the Mac goes to sleep until
/// `wakeQuiet` seconds after it wakes (USB devices drop and re-enumerate then). Notifications in the quiet
/// time still count for the debounce.
public struct DeviceSoundGate: Sendable {
    public static let wakeQuiet: TimeInterval = 5
    private var debouncer = SoundDebouncer(interval: 1)
    private var quietUntil = Date.distantPast

    public init() {}

    /// NSWorkspace.willSleepNotification: quiet until the wake.
    public mutating func willSleep(at now: Date) {
        quietUntil = .distantFuture
    }

    public mutating func didWake(at now: Date) {
        quietUntil = now.addingTimeInterval(Self.wakeQuiet)
    }

    public mutating func shouldPlay(_ event: SoundEvent, at now: Date) -> Bool {
        let debounced = debouncer.shouldPlay(event, at: now)
        return debounced && now >= quietUntil
    }
}

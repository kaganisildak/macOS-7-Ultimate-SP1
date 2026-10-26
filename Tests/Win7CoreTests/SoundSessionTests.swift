import Foundation
import Testing
@testable import Win7Core

@Suite struct SoundSchemeTests {
    @Test func eventAssets() {
        #expect(SoundEvent.navigation.assetPath == "sounds/navigation.wav")
        #expect(SoundEvent.emptyRecycleBin.assetPath == "sounds/recycle.wav")
        #expect(SoundEvent.deviceConnect.assetPath == "sounds/hardware-insert.wav")
        #expect(SoundEvent.deviceDisconnect.assetPath == "sounds/hardware-remove.wav")
        #expect(SoundEvent.logoff.assetPath == "sounds/logoff.wav")
        #expect(SoundEvent.shutdown.assetPath == "sounds/shutdown.wav")
    }

    @Test func powerActionSounds() {
        #expect(SoundEvent.forPowerAction(.logOff) == .logoff)
        #expect(SoundEvent.forPowerAction(.shutDown) == .shutdown)
        #expect(SoundEvent.forPowerAction(.restart) == .shutdown)
        #expect(SoundEvent.forPowerAction(.sleep) == nil)
        #expect(SoundEvent.forPowerAction(.lock) == nil)
    }

    /// macOS's "Play user interface sound effects" (com.apple.sound.uiaudio.enabled, on when unset) and
    /// the shell's W7SoundsDisabled both gate every event.
    @Test func playPolicy() {
        #expect(SoundScheme.shouldPlay(uiSoundsSetting: nil, disabled: false))
        #expect(SoundScheme.shouldPlay(uiSoundsSetting: 1, disabled: false))
        #expect(!SoundScheme.shouldPlay(uiSoundsSetting: 0, disabled: false))
        #expect(!SoundScheme.shouldPlay(uiSoundsSetting: false, disabled: false))
        #expect(!SoundScheme.shouldPlay(uiSoundsSetting: nil, disabled: true))
        #expect(SoundScheme.uiSoundsKey == "com.apple.sound.uiaudio.enabled")
        #expect(SoundScheme.disabledKey == "W7SoundsDisabled")
    }

    /// One USB device fires several notifications: one sound per kind per second.
    @Test func deviceDebounce() {
        var d = SoundDebouncer(interval: 1)
        let t = Date(timeIntervalSince1970: 1000)
        let plays = [(SoundEvent.deviceConnect, 0.0), (.deviceConnect, 0.5), (.deviceDisconnect, 0.6),
                     (.deviceConnect, 1.2), (.deviceConnect, 2.3)].map { d.shouldPlay($0.0, at: t.addingTimeInterval($0.1)) }
        // The quiet second counts from the last notification, so a burst stays one sound.
        #expect(plays == [true, false, true, false, true])
    }
}

@Suite struct SessionMarkerTests {
    @Test func markerFromBootUUIDAndLoginTime() {
        let login = Date(timeIntervalSince1970: 1_792_000_000.7)
        #expect(SessionMarker.marker(bootSessionUUID: "ABC", loginTime: login) == "ABC|1792000000")
        #expect(SessionMarker.marker(bootSessionUUID: "ABC", loginTime: nil) == "ABC")
        #expect(SessionMarker.marker(bootSessionUUID: "", loginTime: login) == nil)
        #expect(SessionMarker.marker(bootSessionUUID: nil, loginTime: login) == nil)
    }

    /// Welcome shows on the LaunchAgent's launch, once per login session: a crash respawn in the same
    /// session, or a launch by hand, stays quiet; a new login (or a reboot) shows it again.
    @Test func welcomeOncePerSession() {
        #expect(SessionMarker.shouldShow(isLoginLaunch: true, current: "A|1", lastShown: nil))
        #expect(!SessionMarker.shouldShow(isLoginLaunch: true, current: "A|1", lastShown: "A|1"))
        #expect(SessionMarker.shouldShow(isLoginLaunch: true, current: "A|2", lastShown: "A|1"))
        #expect(SessionMarker.shouldShow(isLoginLaunch: true, current: "B|1", lastShown: "A|1"))
        #expect(!SessionMarker.shouldShow(isLoginLaunch: false, current: "B|1", lastShown: "A|1"))
        #expect(!SessionMarker.shouldShow(isLoginLaunch: true, current: nil, lastShown: nil))
    }

    @Test func splashTexts() {
        #expect(SessionSplashKind.welcome.text == "Welcome")
        #expect(SessionSplashKind.loggingOff.text == "Logging off…")
        #expect(SessionSplashKind.shuttingDown.text == "Shutting down…")
        #expect(SessionSplashKind.forPowerAction(.logOff) == .loggingOff)
        #expect(SessionSplashKind.forPowerAction(.restart) == .shuttingDown)
        #expect(SessionSplashKind.forPowerAction(.shutDown) == .shuttingDown)
        #expect(SessionSplashKind.forPowerAction(.sleep) == nil)
        #expect(SessionSplashKind.minimumDuration == 1.2)
        #expect(SessionSplashKind.failureTimeout == 10)
    }
}

import AppKit

/// Plays the imported startup sound once, only when launched by the LaunchAgent at login
/// (which sets W7_LOGIN=1), so relaunching the shell by hand stays quiet.
@MainActor
enum StartupSound {
    static let sessionKey = "startupSoundSession"
    private static var sound: NSSound?

    /// Plays at most once per login session (boot session UUID + login time, LoginSession), so a
    /// crash-loop respawn of the LaunchAgent doesn't replay the sound.
    static func playIfLogin() {
        guard let url = AssetStore.shared.url("sounds/startup.wav"), LoginSession.firstTime(sessionKey),
              let s = NSSound(contentsOf: url, byReference: true) else { return }
        sound = s
        s.play()
    }
}

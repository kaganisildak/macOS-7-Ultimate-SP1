import Testing
import Win7ChromeCore

@Test func loadsInOrdinaryApp() { #expect(W7ShouldLoadInProcess("com.apple.TextEdit", [:], [], false)) }
@Test func noBundleID() { #expect(!W7ShouldLoadInProcess(nil, [:], [], false)) }
@Test func killSwitch() { #expect(!W7ShouldLoadInProcess("com.apple.TextEdit", [:], [], true)) }
@Test func defaultDenylist() { #expect(!W7ShouldLoadInProcess("com.apple.dock", [:], [], false)) }
@Test func userDenylist() { #expect(!W7ShouldLoadInProcess("com.apple.TextEdit", [:], ["com.apple.TextEdit"], false)) }
@Test func agentApps() {
    #expect(!W7ShouldLoadInProcess("x.y", ["LSUIElement": true], [], false))
    #expect(!W7ShouldLoadInProcess("x.y", ["LSUIElement": "1"], [], false))
    #expect(!W7ShouldLoadInProcess("x.y", ["LSBackgroundOnly": true], [], false))
}
@Test func defaultDenylistContents() {
    #expect(W7DefaultDenylist() == ["com.apple.loginwindow", "com.apple.dock", "com.apple.WindowManager", "com.apple.controlcenter", "com.apple.systemuiserver", "com.apple.notificationcenterui", "com.apple.Spotlight", "com.apple.SecurityAgent", "com.apple.screensaver.engine", "com.apple.osascript", "com.win7mac.shell"] + W7SettingsExcludedExtensionIDs())
}

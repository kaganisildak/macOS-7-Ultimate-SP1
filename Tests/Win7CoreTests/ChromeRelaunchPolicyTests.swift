import Foundation
import Testing
@testable import Win7Core

// apps that started before Ammonia injected are relaunched at login or offered a restart.

private let login = Date(timeIntervalSince1970: 1_800_000_000)

private func app(_ id: String, _ name: String, at seconds: TimeInterval?, chrome: Bool? = false,
                 denylisted: Bool = false, regular: Bool = true, arm64: Bool = true) -> ChromeRelaunchApp {
    ChromeRelaunchApp(bundleID: id, name: name, launchDate: seconds.map { login.addingTimeInterval($0) },
                      hasChrome: chrome, denylisted: denylisted, isRegular: regular, isNativeARM64: arm64)
}

private let terminal = app("com.apple.Terminal", "Terminal", at: 0.5)
private let safari = app("com.apple.Safari", "Safari", at: 0.6)
private let notes = app("com.apple.Notes", "Notes", at: 0.7)
private let finderWithChrome = app("com.apple.finder", "Finder", at: 1.0, chrome: true)
private let textEdit = app("com.apple.TextEdit", "TextEdit", at: 200, chrome: true)

private func decide(shellAt shell: TimeInterval, now: TimeInterval? = nil, sessionStart: Date? = login,
                    _ apps: [ChromeRelaunchApp]) -> [ChromeRelaunchDecision] {
    ChromeRelaunchPolicy.decide(sessionStart: sessionStart, shellLaunch: login.addingTimeInterval(shell),
                                now: login.addingTimeInterval(now ?? shell + 8), apps: apps)
}

@Test func atLoginTheAppsWithoutChromeAreRelaunched() {
    #expect(decide(shellAt: 3, [terminal, safari, notes, finderWithChrome, textEdit])
            == [.relaunch([terminal, safari, notes])])
}

@Test func aShellStartedLaterOnlyNotifies() {
    // The shell restarted (make install, a crash respawn) long after login: the user may have typed in Terminal.
    #expect(decide(shellAt: 3600, [terminal, safari, notes, finderWithChrome])
            == [.notify([terminal, safari, notes])])
    #expect(decide(shellAt: 121, [terminal]) == [.notify([terminal])])
    // The decision itself must come within 60 s of the login record (the 8 s timer after a shell start at 52 s).
    #expect(decide(shellAt: 52, [terminal]) == [.relaunch([terminal])])
    #expect(decide(shellAt: 53, [terminal]) == [.notify([terminal])])
}

@Test func windowsAreOneSidedWithAFewSecondsOfSlack() {
    // A shell or an app that started before the login record is "at login" only within 5 s of slack
    // (the record is read to whole seconds).
    #expect(decide(shellAt: -60, now: 10, [terminal]) == [.notify([terminal])])
    #expect(decide(shellAt: -5, now: 10, [terminal]) == [.relaunch([terminal])])
    #expect(decide(shellAt: -6, now: 10, [terminal]) == [.notify([terminal])])
    let early = app("com.example.Early", "Early", at: -15)
    let slack = app("com.example.Slack", "Slack", at: -4)
    #expect(decide(shellAt: 3, [early, slack]) == [.relaunch([slack]), .notify([early])])
    // A clock that reads before the login record is not "at login" either.
    #expect(decide(shellAt: 3, now: -30, [terminal]) == [.notify([terminal])])
}

@Test func appsThatCannotLoadTheArm64DylibAreLeftAlone() {
    // An x86_64 app under Rosetta can never map the arm64/arm64e dylib: relaunching it would not help.
    let rosetta = app("com.example.Intel", "Intel", at: 0.5, arm64: false)
    #expect(decide(shellAt: 3, [rosetta, terminal]) == [.relaunch([terminal])])
    #expect(decide(shellAt: 3600, [rosetta]).isEmpty)
}

@Test func theAutomaticLoopStopsAtTheDeadlineOrAfterSleep() {
    // Re-checked before every quit: within 60 s of the login record and no sleep since the decision.
    #expect(ChromeRelaunchPolicy.mayStillRelaunch(sessionStart: login, now: login.addingTimeInterval(30), sleptSinceDecision: false))
    #expect(ChromeRelaunchPolicy.mayStillRelaunch(sessionStart: login, now: login.addingTimeInterval(60), sleptSinceDecision: false))
    #expect(!ChromeRelaunchPolicy.mayStillRelaunch(sessionStart: login, now: login.addingTimeInterval(61), sleptSinceDecision: false))
    #expect(!ChromeRelaunchPolicy.mayStillRelaunch(sessionStart: login, now: login.addingTimeInterval(30), sleptSinceDecision: true))
    #expect(!ChromeRelaunchPolicy.mayStillRelaunch(sessionStart: nil, now: login, sleptSinceDecision: false))
    #expect(!ChromeRelaunchPolicy.mayStillRelaunch(sessionStart: login, now: login.addingTimeInterval(-30), sleptSinceDecision: false))
    // Sleep: the wall clock ran on while the monotonic uptime stood still (2 s of tolerance).
    #expect(!ChromeRelaunchPolicy.slept(wallElapsed: 20, uptimeElapsed: 19))
    #expect(ChromeRelaunchPolicy.slept(wallElapsed: 300, uptimeElapsed: 20))
    #expect(ChromeRelaunchPolicy.slept(wallElapsed: 5, uptimeElapsed: 20))   // a clock stepped back: treated as unsafe too
}

@Test func anAppLaunchedThirtySecondsAfterLoginIsOnlyOffered() {
    let late = app("com.example.Editor", "Editor", at: 30)
    #expect(decide(shellAt: 3, [late]) == [.notify([late])])
    // At login, the early apps are still relaunched; the late one is offered from the balloon.
    #expect(decide(shellAt: 3, [terminal, late]) == [.relaunch([terminal]), .notify([late])])
    let edge = app("com.example.Edge", "Edge", at: 20)
    #expect(decide(shellAt: 3, [edge]) == [.relaunch([edge])])
}

@Test func appsWithChromeUnknownOrDenylistedAreLeftAlone() {
    let unknown = app("com.example.Locked", "Locked", at: 0.5, chrome: nil)
    let denied = app("com.example.Denied", "Denied", at: 0.5, denylisted: true)
    let agent = app("com.example.Agent", "Agent", at: 0.5, regular: false)
    let withChrome = app("com.example.Fine", "Fine", at: 0.5, chrome: true)
    for shell in [3.0, 3600] {
        #expect(decide(shellAt: shell, [unknown, denied, agent, withChrome]).isEmpty)
    }
}

@Test func finderLoginwindowAndTheShellAreNeverTouched() {
    let finder = app("com.apple.finder", "Finder", at: 0.5)
    let loginwindow = app("com.apple.loginwindow", "loginwindow", at: 0)
    let shell = app("com.win7mac.shell", "Win7Shell", at: 0.5)
    #expect(decide(shellAt: 3, [finder, loginwindow, shell]).isEmpty)
    #expect(decide(shellAt: 3600, [finder, loginwindow, shell]).isEmpty)
}

@Test func withoutASessionStartOrALaunchDateItOnlyNotifies() {
    #expect(decide(shellAt: 3, sessionStart: nil, [terminal]) == [.notify([terminal])])
    let undated = app("com.example.Undated", "Undated", at: nil)
    #expect(decide(shellAt: 3, [undated]) == [.notify([undated])])
}

@Test func aLateDecisionOnlyNotifies() {
    // The 8 s timer fired long after the shell started (the Mac slept at the login screen): no relaunch.
    #expect(decide(shellAt: 3, now: 900, [terminal]) == [.notify([terminal])])
}

@Test func denylistMatchesProcessNamesAndFailsOpenToSystemApps() {
    let list = ChromeRelaunchPolicy.parseBlacklist("loginwindow\n  Dock \n\n# a comment\nTouch ID & Password\n")
    #expect(list == ["loginwindow", "Dock", "Touch ID & Password"])
    #expect(ChromeRelaunchPolicy.isDenylisted(bundleID: "com.apple.dock", executableName: "Dock",
                                              localizedName: "Dock", blacklist: list))
    #expect(ChromeRelaunchPolicy.isDenylisted(bundleID: "com.apple.x", executableName: "x",
                                              localizedName: "Touch ID & Password", blacklist: list))
    #expect(!ChromeRelaunchPolicy.isDenylisted(bundleID: "com.apple.Terminal", executableName: "Terminal",
                                               localizedName: "Terminal", blacklist: list))
    // Unreadable blacklist: treated as empty, but the system UI apps are still never relaunched.
    #expect(!ChromeRelaunchPolicy.isDenylisted(bundleID: "com.apple.Terminal", executableName: "Terminal",
                                               localizedName: "Terminal", blacklist: nil))
    for id in ["com.apple.systemuiserver", "com.apple.dock", "com.apple.controlcenter",
               "com.apple.notificationcenterui", "com.apple.Spotlight"] {
        #expect(ChromeRelaunchPolicy.isDenylisted(bundleID: id, executableName: "", localizedName: nil, blacklist: nil))
    }
}

@Test func balloonTextIsSingularOrPluralWithShortNameLists() {
    let one = ChromeRelaunchPolicy.balloonText(names: ["Terminal"])
    #expect(one.title == "1 program started before the Windows 7 frames were ready")
    #expect(one.names == "Terminal")
    #expect(one.action == "Click to restart it")
    let three = ChromeRelaunchPolicy.balloonText(names: ["Terminal", "Safari", "Notes"])
    #expect(three.title == "3 programs started before the Windows 7 frames were ready")
    #expect(three.names == "Terminal, Safari, Notes")
    #expect(three.action == "Click to restart them")
    let four = ChromeRelaunchPolicy.balloonText(names: ["Terminal", "Safari", "Notes", "Mail"])
    #expect(four.title == "4 programs started before the Windows 7 frames were ready")
    #expect(four.names == nil)
}

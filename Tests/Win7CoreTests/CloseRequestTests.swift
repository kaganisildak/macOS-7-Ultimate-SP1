import Testing
import Foundation
@testable import Win7Core

/// the taskbar's "Close window" / "Close all windows" go through the app itself when the dylib
/// is in it (`.askApp`), fall back to Accessibility or the hint/confirmation when the app did not answer,
/// and exit the program afterwards as Windows 7 does (never Finder).
@Suite struct CloseRequestTests {
    private func input(windows: Int, ax: Bool) -> JumpListInput {
        JumpListInput(appName: "TextEdit", isPinned: true, isRunning: true, windowCount: windows,
                      accessibility: ax, recent: nil)
    }

    /// trusted/untrusted × decorated/undecorated × one/many windows.
    @Test func closeEffectTable() {
        typealias Row = (ax: Bool, decorated: Bool, windows: Int, effect: JumpListCloseEffect)
        let table: [Row] = [
            (false, false, 1, .hintAccessibility), (true, false, 1, .closeFrontWindow),
            (false, true, 1, .askApp), (true, true, 1, .askApp),
            (false, false, 3, .confirmQuit), (true, false, 3, .closeEachWindow),
            (false, true, 3, .askApp), (true, true, 3, .askApp),
        ]
        for row in table {
            let items = JumpList.sections(input(windows: row.windows, ax: row.ax)).flatMap(\.items)
            let effects = items.compactMap { JumpList.closeEffect($0.action, accessibility: row.ax, decorated: row.decorated) }
            #expect(effects == [row.effect], "ax \(row.ax), decorated \(row.decorated), windows \(row.windows)")
        }
        for decorated in [true, false] {
            #expect(JumpList.closeEffect(.launch, accessibility: true, decorated: decorated) == nil)
            #expect(JumpList.closeEffect(.pin, accessibility: false, decorated: decorated) == nil)
        }
    }

    /// Asking the app never shows the confirmation box first, so the jump list gives focus back.
    @Test func askingTheAppDoesNotTakeFocus() {
        for ax in [true, false] {
            #expect(!JumpList.choiceTakesFocus(.closeAllWindows, accessibility: ax, decorated: true))
            #expect(!JumpList.choiceTakesFocus(.closeWindow, accessibility: ax, decorated: true))
            #expect(JumpList.choiceTakesFocus(.launch, accessibility: ax, decorated: true))
        }
        #expect(JumpList.choiceTakesFocus(.closeAllWindows, accessibility: false, decorated: false))
    }

    /// After asking: nothing more when the app answered or a window went away; otherwise the
    /// undecorated path (Accessibility when trusted, else the hint or the confirmation).
    @Test func fallbackAfterAskingTheApp() {
        for action in [JumpListAction.closeWindow, .closeAllWindows] {
            for ax in [true, false] {
                #expect(JumpList.closeFallback(action, acknowledged: true, windowsBefore: 2, windowsAfter: 2, accessibility: ax) == nil)
                #expect(JumpList.closeFallback(action, acknowledged: false, windowsBefore: 2, windowsAfter: 1, accessibility: ax) == nil)
                #expect(JumpList.closeFallback(action, acknowledged: false, windowsBefore: 2, windowsAfter: 0, accessibility: ax) == nil)
            }
        }
        #expect(JumpList.closeFallback(.closeWindow, acknowledged: false, windowsBefore: 1, windowsAfter: 1, accessibility: true) == .closeFrontWindow)
        #expect(JumpList.closeFallback(.closeWindow, acknowledged: false, windowsBefore: 1, windowsAfter: 1, accessibility: false) == .hintAccessibility)
        #expect(JumpList.closeFallback(.closeAllWindows, acknowledged: false, windowsBefore: 3, windowsAfter: 3, accessibility: true) == .closeEachWindow)
        #expect(JumpList.closeFallback(.closeAllWindows, acknowledged: false, windowsBefore: 3, windowsAfter: 4, accessibility: false) == .confirmQuit)
        #expect(JumpList.closeFallback(.launch, acknowledged: false, windowsBefore: 1, windowsAfter: 1, accessibility: true) == nil)
    }

    @Test func terminateAfterClosingOnlyWhenNoWindowIsLeftAndNeverFinder() {
        #expect(JumpList.shouldTerminate(bundleID: "com.apple.TextEdit", windowsLeft: 0))
        #expect(!JumpList.shouldTerminate(bundleID: "com.apple.TextEdit", windowsLeft: 1))
        #expect(!JumpList.shouldTerminate(bundleID: "com.apple.finder", windowsLeft: 0))
        #expect(!JumpList.shouldTerminate(bundleID: "com.apple.finder", windowsLeft: 2))
        #expect(JumpList.keepAliveBundleIDs == ["com.apple.finder"])
    }

    /// AX lists only the current Space's windows, so the shell also counts the app's CG windows
    /// (`.optionAll`, any Space, eligible ones) and takes the larger: it never quits an app that may still
    /// have a window elsewhere.
    @Test func windowsLeftIsTheLargerOfAXAndCG() {
        #expect(JumpList.windowsLeft(ax: 0, cg: 1) == 1)
        #expect(JumpList.windowsLeft(ax: 2, cg: 0) == 2)
        #expect(JumpList.windowsLeft(ax: 0, cg: 0) == 0)
        #expect(!JumpList.shouldTerminate(bundleID: "com.apple.TextEdit", windowsLeft: JumpList.windowsLeft(ax: 0, cg: 1),
                                          keepAlive: []))
        #expect(JumpList.shouldTerminate(bundleID: "com.apple.TextEdit", windowsLeft: JumpList.windowsLeft(ax: 0, cg: 0),
                                         keepAlive: []))
    }

    /// The CG side of `windowsLeft`: layer-0 windows of at least the minimum size, on screen or not
    /// (another Space, a full-screen Space).
    @Test func eligibleCGWindowCountIncludesOffScreenWindows() {
        let windows = [
            CGWindowInfo(id: 1, name: nil, bounds: CGRect(x: 0, y: 0, width: 500, height: 400), layer: 0, isOnScreen: false),
            CGWindowInfo(id: 2, name: nil, bounds: CGRect(x: 0, y: 0, width: 500, height: 400), layer: 0, isOnScreen: true),
            CGWindowInfo(id: 3, name: nil, bounds: CGRect(x: 0, y: 0, width: 20, height: 400), layer: 0, isOnScreen: true),
            CGWindowInfo(id: 4, name: nil, bounds: CGRect(x: 0, y: 0, width: 500, height: 400), layer: 3, isOnScreen: true),
        ]
        #expect(WindowList.eligibleCount(windows) == 2)
        #expect(WindowList.eligibleCount([]) == 0)
    }

    /// `W7CloseKeepAlive` (global defaults, bundle ids) keeps more apps running; Finder always.
    @Test func keepAliveListFromDefaults() {
        #expect(JumpList.keepAliveDefaultsKey == "W7CloseKeepAlive")
        #expect(!JumpList.shouldTerminate(bundleID: "com.apple.Music", windowsLeft: 0, keepAlive: ["com.apple.Music"]))
        #expect(JumpList.shouldTerminate(bundleID: "com.apple.TextEdit", windowsLeft: 0, keepAlive: ["com.apple.Music"]))
        #expect(!JumpList.shouldTerminate(bundleID: "com.apple.finder", windowsLeft: 0, keepAlive: []))
        #expect(!JumpList.shouldTerminate(bundleID: "com.apple.Music", windowsLeft: 1, keepAlive: []))
        // What `defaults write -g W7CloseKeepAlive -array …` gives; anything not a string is ignored.
        #expect(JumpList.keepAlive(fromDefaultsValue: ["com.apple.Music", 3, "com.apple.mail"] as [Any])
                == ["com.apple.Music", "com.apple.mail"])
        #expect(JumpList.keepAlive(fromDefaultsValue: nil) == [])
        #expect(JumpList.keepAlive(fromDefaultsValue: "com.apple.Music") == [])
    }

    /// Only the Accessibility closes are followed by the shell's own exit check; asking the app leaves
    /// that to the app (the dylib), and the hint and the confirmation close nothing themselves.
    @Test func whichEffectsAreFollowedByTheExitCheck() {
        #expect(JumpList.shellChecksExit(after: .closeFrontWindow))
        #expect(JumpList.shellChecksExit(after: .closeEachWindow))
        for e in [JumpListCloseEffect.askApp, .hintAccessibility, .confirmQuit] { #expect(!JumpList.shellChecksExit(after: e)) }
    }
}

/// item 4: the shell asks for a missing grant at most once per launch unprompted and at most once
/// per 60 s when something that needs it is used.
@Suite struct PermissionPromptTests {
    private let none = PermissionSnapshot(axTrusted: false, screenCapture: false)
    private let axOnly = PermissionSnapshot(axTrusted: true, screenCapture: false)
    private let all = PermissionSnapshot(axTrusted: true, screenCapture: true)
    private let t0 = Date(timeIntervalSinceReferenceDate: 1_000_000)

    @Test func missingKinds() {
        #expect(none.missing == [.accessibility, .screenCapture])
        #expect(axOnly.missing == [.screenCapture])
        #expect(all.missing.isEmpty)
        #expect(axOnly.isGranted(.accessibility) && !axOnly.isGranted(.screenCapture))
    }

    @Test func launchPromptsOnceWhenSomethingIsMissing() {
        #expect(PermissionGate.shouldPrompt(snapshot: none, lastPromptAt: nil, now: t0, trigger: .launch))
        #expect(PermissionGate.shouldPrompt(snapshot: axOnly, lastPromptAt: nil, now: t0, trigger: .launch))
        #expect(!PermissionGate.shouldPrompt(snapshot: all, lastPromptAt: nil, now: t0, trigger: .launch))
        // Once per launch: any earlier prompt in this launch, however long ago, rules it out.
        #expect(!PermissionGate.shouldPrompt(snapshot: none, lastPromptAt: t0, now: t0 + 3600, trigger: .launch))
    }

    @Test func usePromptsAtMostEverySixtySeconds() {
        let use = PermissionPromptTrigger.use(.accessibility)
        #expect(PermissionGate.shouldPrompt(snapshot: none, lastPromptAt: nil, now: t0, trigger: use))
        #expect(!PermissionGate.shouldPrompt(snapshot: none, lastPromptAt: t0, now: t0 + 10, trigger: use))
        #expect(!PermissionGate.shouldPrompt(snapshot: none, lastPromptAt: t0, now: t0 + 59.9, trigger: use))
        #expect(PermissionGate.shouldPrompt(snapshot: none, lastPromptAt: t0, now: t0 + 60, trigger: use))
        // Granted: never asks for it.
        #expect(!PermissionGate.shouldPrompt(snapshot: axOnly, lastPromptAt: nil, now: t0, trigger: use))
        #expect(PermissionGate.shouldPrompt(snapshot: axOnly, lastPromptAt: nil, now: t0, trigger: .use(.screenCapture)))
        #expect(!PermissionGate.shouldPrompt(snapshot: all, lastPromptAt: nil, now: t0, trigger: .use(.screenCapture)))
        #expect(PermissionGate.promptInterval == 60)
    }

    /// item 4: the Screen Recording balloon. A taskbar window list opened with a click while the
    /// grant is missing (its previews cannot be drawn) asks, with the same 60 s cadence; hovering never asks,
    /// and nothing asks once the grant is there.
    @Test func screenCaptureIsAskedForOnAClickedListWithoutPreviews() {
        let use = PermissionPromptTrigger.use(.screenCapture)
        #expect(PermissionGate.shouldPrompt(snapshot: axOnly, lastPromptAt: nil, now: t0, trigger: use))
        #expect(!PermissionGate.shouldPrompt(snapshot: axOnly, lastPromptAt: t0, now: t0 + 30, trigger: use))
        #expect(PermissionGate.shouldPrompt(snapshot: axOnly, lastPromptAt: t0, now: t0 + 60, trigger: use))
        #expect(!PermissionGate.shouldPrompt(snapshot: all, lastPromptAt: nil, now: t0, trigger: use))

        #expect(PermissionGate.previewTrigger(features: [.snap, .switcher], openedByClick: true) == use)
        #expect(PermissionGate.previewTrigger(features: [], openedByClick: true) == use)
        #expect(PermissionGate.previewTrigger(features: [.snap, .switcher], openedByClick: false) == nil)
        #expect(PermissionGate.previewTrigger(features: [.snap, .switcher, .thumbnails, .windowTitles],
                                              openedByClick: true) == nil)
    }

    /// item 7: a shell respawned within 60 s of the last launch prompt (a KeepAlive crash loop)
    /// does not prompt again at launch.
    @Test func launchPromptSkippedAfterARecentRespawn() {
        #expect(PermissionGate.shouldPromptAtLaunch(snapshot: none, previousLaunchPromptAt: nil, now: t0))
        #expect(!PermissionGate.shouldPromptAtLaunch(snapshot: none, previousLaunchPromptAt: t0 - 10, now: t0))
        #expect(!PermissionGate.shouldPromptAtLaunch(snapshot: none, previousLaunchPromptAt: t0 - 59, now: t0))
        #expect(PermissionGate.shouldPromptAtLaunch(snapshot: none, previousLaunchPromptAt: t0 - 60, now: t0))
        #expect(!PermissionGate.shouldPromptAtLaunch(snapshot: all, previousLaunchPromptAt: nil, now: t0))
        // A clock that went backwards (or a bogus stored value in the future): ask.
        #expect(PermissionGate.shouldPromptAtLaunch(snapshot: none, previousLaunchPromptAt: t0 + 3600, now: t0))
        #expect(PermissionGate.launchPromptDefaultsKey == "W7LastLaunchPromptAt")
    }
}

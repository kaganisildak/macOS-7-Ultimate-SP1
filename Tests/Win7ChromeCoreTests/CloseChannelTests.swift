import Testing
import AppKit
import Win7ChromeCore

/// A window whose visibility and sheet state are set by the test (nothing is put on screen) and whose
/// performClose: is recorded. `closes`: performClose: takes it away (false: it stays, as behind a save sheet).
final class FakeCloseWindow: NSWindow {
    var fakeVisible = true
    var fakeSheet = false
    var fakeMiniaturized = false
    var closes = true
    var performCloseCount = 0
    override var isVisible: Bool { fakeVisible }
    override var isSheet: Bool { fakeSheet }
    override var isMiniaturized: Bool { fakeMiniaturized }
    override func performClose(_ sender: Any?) {
        performCloseCount += 1
        if closes { fakeVisible = false; fakeMiniaturized = false }
    }
}

/// performClose: runs a nested run loop for `blockFor` seconds, as an app's windowShouldClose: does
/// with a synchronous runModal alert. It records what the channel had acknowledged when it was entered.
final class BlockingCloseWindow: NSWindow {
    var fakeVisible = true
    var blockFor: TimeInterval = 1
    var acknowledgementsAtEntry: (() -> Int)?
    var seenAtEntry = -1
    var blockEndedAt: Date?
    override var isVisible: Bool { fakeVisible }
    override func performClose(_ sender: Any?) {
        seenAtEntry = acknowledgementsAtEntry?() ?? -1
        RunLoop.main.run(until: Date(timeIntervalSinceNow: blockFor))
        blockEndedAt = Date()
        fakeVisible = false
    }
}

final class FakeClosePanel: NSPanel {
    var performCloseCount = 0
    override var isVisible: Bool { true }
    override func performClose(_ sender: Any?) { performCloseCount += 1 }
}

@MainActor private func window(_ mask: NSWindow.StyleMask = [.titled, .closable, .miniaturizable, .resizable]) -> FakeCloseWindow {
    let w = FakeCloseWindow(contentRect: NSRect(x: 0, y: 0, width: 200, height: 120), styleMask: mask,
                            backing: .buffered, defer: true)
    w.isReleasedWhenClosed = false
    return w
}

@MainActor private func panel() -> FakeClosePanel {
    let p = FakeClosePanel(contentRect: NSRect(x: 0, y: 0, width: 100, height: 80), styleMask: [.titled, .closable],
                           backing: .buffered, defer: true)
    p.isReleasedWhenClosed = false
    return p
}

/// Builds a channel over `windows` (also the front-to-back order unless `ordered` is given).
@MainActor private final class Harness {
    var windows: [NSWindow]
    var ordered: [NSWindow]
    var key: NSWindow?
    var main: NSWindow?
    var terminations = 0
    var channel: W7CloseChannel!

    init(_ windows: [NSWindow], ordered: [NSWindow]? = nil, key: NSWindow? = nil, main: NSWindow? = nil,
         bundleID: String = "com.apple.TextEdit", disabled: Bool = false, settle: TimeInterval = 0.05) {
        self.windows = windows; self.ordered = ordered ?? windows; self.key = key; self.main = main
        channel = W7CloseChannel(bundleID: bundleID,
                                 windows: { [unowned self] in self.windows },
                                 orderedWindows: { [unowned self] in self.ordered },
                                 keyWindow: { [unowned self] in self.key },
                                 mainWindow: { [unowned self] in self.main },
                                 terminate: { [unowned self] in self.terminations += 1 },
                                 settleDelay: settle, disabled: disabled)
    }

    func settle() { RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.25)) }
}

@MainActor @Suite(.serialized) struct CloseChannelTests {
    init() { _ = NSApplication.shared }

    @Test func notificationNamesCarryThePid() {
        #expect(W7CloseChannelNotificationName(.window, 4242) == "com.win7mac.closeWindow.4242")
        #expect(W7CloseChannelNotificationName(.allWindows, 7) == "com.win7mac.closeAllWindows.7")
        #expect(W7CloseChannelAckName(4242) == "com.win7mac.closeHandled.4242")
    }

    @Test func eligibleWindows() {
        let std: NSWindow.StyleMask = [.titled, .closable]
        #expect(W7CloseChannelWindowEligible(std, false, false, true, false))
        #expect(W7CloseChannelWindowEligible(std, false, false, false, true))   // minimized
        #expect(!W7CloseChannelWindowEligible(std, false, false, false, false))  // ordered out
        #expect(!W7CloseChannelWindowEligible([.titled], false, false, true, false))  // no close button
        #expect(!W7CloseChannelWindowEligible(std, true, false, true, false))   // panel
        #expect(!W7CloseChannelWindowEligible(std, false, true, true, false))   // sheet
        #expect(!W7CloseChannelWindowEligible([.borderless], false, false, true, false))
    }

    @Test func keepAliveIsFinderOnly() {
        #expect(W7CloseChannelKeepsAlive("com.apple.finder"))
        #expect(!W7CloseChannelKeepsAlive("com.apple.TextEdit"))
        #expect(!W7CloseChannelKeepsAlive(nil))
    }

    /// `W7CloseKeepAlive` (global defaults array of bundle ids) adds apps that are never quit; Finder
    /// is always implied, and entries that are not strings are ignored.
    @Test func keepAliveListAddsApps() {
        #expect(W7CloseChannelKeepsAliveInList("com.apple.Music", ["com.apple.Music"]))
        #expect(W7CloseChannelKeepsAliveInList("com.apple.finder", []))
        #expect(W7CloseChannelKeepsAliveInList("com.apple.finder", nil))
        #expect(!W7CloseChannelKeepsAliveInList("com.apple.TextEdit", ["com.apple.Music", 3]))
        #expect(!W7CloseChannelKeepsAliveInList(nil, ["com.apple.Music"]))
        #expect(W7CloseKeepAliveDefaultsKey == "W7CloseKeepAlive")
    }

    /// The channel reads the list from the defaults (here the registration domain) at its exit check.
    @Test func keepAliveListKeepsTheAppRunning() {
        UserDefaults.standard.register(defaults: ["W7CloseKeepAlive": ["com.example.keepalive"]])
        defer { UserDefaults.standard.register(defaults: ["W7CloseKeepAlive": [String]()]) }
        let a = window()
        let h = Harness([a], key: a, bundleID: "com.example.keepalive")
        #expect(h.channel.closeWindow() == 1)
        h.settle()
        #expect(h.terminations == 0)
        let b = window()
        let other = Harness([b], key: b, bundleID: "com.example.other")
        #expect(other.channel.closeWindow() == 1)
        other.settle()
        #expect(other.terminations == 1)
    }

    /// (review item 5): the exit check counts visible titled windows whether or not they have a close
    /// button; panels, sheets, borderless and ordered-out windows do not keep the app running.
    @Test func windowsThatKeepTheAppRunning() {
        #expect(W7CloseChannelWindowKeepsAppRunning([.titled, .closable], false, false, true, false))
        #expect(W7CloseChannelWindowKeepsAppRunning([.titled], false, false, true, false))
        #expect(W7CloseChannelWindowKeepsAppRunning([.titled], false, false, false, true))
        #expect(!W7CloseChannelWindowKeepsAppRunning([.titled], false, false, false, false))
        #expect(!W7CloseChannelWindowKeepsAppRunning([.titled, .closable], true, false, true, false))
        #expect(!W7CloseChannelWindowKeepsAppRunning([.titled, .closable], false, true, true, false))
        #expect(!W7CloseChannelWindowKeepsAppRunning([.borderless], false, false, true, false))
    }

    @Test func aWindowWithoutACloseButtonKeepsTheAppRunning() {
        let a = window(), fixed = window([.titled, .miniaturizable])
        let h = Harness([a, fixed], key: a)
        #expect(h.channel.closeAllWindows() == 1)
        #expect(fixed.performCloseCount == 0)
        h.settle()
        #expect(h.terminations == 0)
    }

    /// (review item 2): the acknowledgement goes out as soon as a target is chosen, before
    /// performClose:, so a modal alert in windowShouldClose: does not hold it past the shell's 0.7 s check.
    @Test func acknowledgementGoesOutBeforePerformClose() throws {
        let w = BlockingCloseWindow(contentRect: NSRect(x: 0, y: 0, width: 200, height: 120),
                                    styleMask: [.titled, .closable], backing: .buffered, defer: true)
        w.isReleasedWhenClosed = false
        let h = Harness([w], key: w)
        // The count goes up in the same step that posts the notification (the test process does not receive
        // its own distributed notifications, so the count is what is observed).
        w.acknowledgementsAtEntry = { [unowned h] in h.channel.acknowledgements }
        let start = Date()
        h.channel.handleCloseWindowNotification(Notification(name: Notification.Name("com.win7mac.closeWindow.1")))
        // Already acknowledged when performClose: began, a whole second before it returned.
        #expect(w.seenAtEntry == 1)
        let ended = try #require(w.blockEndedAt)
        #expect(ended.timeIntervalSince(start) >= 0.9)
        #expect(h.channel.acknowledgements == 1)
        h.settle()
    }

    @Test func closeWindowPicksKeyThenMainThenFront() {
        let a = window(), b = window(), c = window()
        var h = Harness([a, b, c], ordered: [c, b, a], key: b, main: a)
        #expect(h.channel.targetWindow() === b)
        h = Harness([a, b, c], ordered: [c, b, a], key: nil, main: a)
        #expect(h.channel.targetWindow() === a)
        h = Harness([a, b, c], ordered: [c, b, a])
        #expect(h.channel.targetWindow() === c)
        // A key panel or sheet, a main window that is not eligible: the next choice.
        let p = panel(), s = window(); s.fakeSheet = true
        let hidden = window(); hidden.fakeVisible = false
        h = Harness([a, p, s, hidden], ordered: [s, hidden, a], key: p, main: hidden)
        #expect(h.channel.targetWindow() === a)
        h = Harness([p, s], ordered: [s], key: s)
        #expect(h.channel.targetWindow() == nil)
    }

    @Test func closeWindowClosesOneAndTerminatesWhenItWasTheLast() {
        let a = window()
        let h = Harness([a], key: a)
        #expect(h.channel.closeWindow() == 1)
        #expect(a.performCloseCount == 1)
        #expect(h.terminations == 0)   // not before the run loop settles
        h.settle()
        #expect(h.terminations == 1)
    }

    @Test func closeWindowLeavesTheAppRunningWhenWindowsRemain() {
        let a = window(), b = window()
        let h = Harness([a, b], key: a)
        #expect(h.channel.closeWindow() == 1)
        #expect(a.performCloseCount == 1 && b.performCloseCount == 0)
        h.settle()
        #expect(h.terminations == 0)
    }

    @Test func closeAllSkipsSheetsAndPanelsAndTerminatesWhenNoneLeft() {
        let a = window(), b = window(), m = window(); m.fakeVisible = false; m.fakeMiniaturized = true
        let s = window(); s.fakeSheet = true
        let p = panel()
        let h = Harness([a, s, p, b, m])
        #expect(h.channel.closeAllWindows() == 3)
        #expect(a.performCloseCount == 1 && b.performCloseCount == 1 && m.performCloseCount == 1)
        #expect(s.performCloseCount == 0 && p.performCloseCount == 0)
        h.settle()
        #expect(h.terminations == 1)
    }

    /// A window that stays (its save sheet is up) keeps the app running.
    @Test func closeAllDoesNotTerminateWhileAWindowRemains() {
        let a = window(), b = window(); b.closes = false
        let h = Harness([a, b])
        #expect(h.channel.closeAllWindows() == 2)
        h.settle()
        #expect(h.terminations == 0)
        #expect(h.channel.eligibleWindowCount() == 1)
    }

    @Test func finderIsNeverTerminated() {
        let a = window(), b = window()
        let h = Harness([a, b], bundleID: "com.apple.finder")
        #expect(h.channel.closeAllWindows() == 2)
        h.settle()
        #expect(h.terminations == 0)
        let c = window()
        let h2 = Harness([c], key: c, bundleID: "com.apple.finder")
        #expect(h2.channel.closeWindow() == 1)
        h2.settle()
        #expect(h2.terminations == 0)
    }

    @Test func nothingClosedNothingTerminated() {
        let p = panel()
        let h = Harness([p])
        #expect(h.channel.closeWindow() == 0)
        #expect(h.channel.closeAllWindows() == 0)
        h.settle()
        #expect(h.terminations == 0 && p.performCloseCount == 0)
    }

    @Test func killSwitchDoesNothing() {
        let a = window()
        let h = Harness([a], key: a, disabled: true)
        #expect(h.channel.closeWindow() == -1)
        #expect(h.channel.closeAllWindows() == -1)
        h.settle()
        #expect(a.performCloseCount == 0 && h.terminations == 0)
    }

    @Test func notificationHandlersCloseOnTheMainThread() {
        let a = window(), b = window()
        let h = Harness([a, b], key: a)
        h.channel.handleCloseWindowNotification(Notification(name: Notification.Name("com.win7mac.closeWindow.1")))
        #expect(a.performCloseCount == 1 && b.performCloseCount == 0)
        h.channel.handleCloseAllWindowsNotification(Notification(name: Notification.Name("com.win7mac.closeAllWindows.1")))
        #expect(b.performCloseCount == 1)
        #expect(h.channel.acknowledgements == 2)
        h.settle()
        #expect(h.terminations >= 1)
    }

    /// Nothing to close (a hidden or windowless app), or the kill switch: no acknowledgement, so the
    /// shell takes its fallback.
    @Test func noAcknowledgementWhenNothingWasClosed() {
        let p = panel()
        let h = Harness([p])
        h.channel.handleCloseWindowNotification(Notification(name: Notification.Name("com.win7mac.closeWindow.1")))
        h.channel.handleCloseAllWindowsNotification(Notification(name: Notification.Name("com.win7mac.closeAllWindows.1")))
        #expect(h.channel.acknowledgements == 0)
        let a = window()
        let off = Harness([a], key: a, disabled: true)
        off.channel.handleCloseWindowNotification(Notification(name: Notification.Name("com.win7mac.closeWindow.1")))
        #expect(off.channel.acknowledgements == 0 && a.performCloseCount == 0)
    }

    /// A provider that throws must not escape (fail open).
    @Test func exceptionsAreContained() {
        let c = W7CloseChannel(bundleID: "x",
                               windows: { NSException(name: .genericException, reason: "test: windows", userInfo: nil).raise(); return [] },
                               orderedWindows: { [] }, keyWindow: { nil }, mainWindow: { nil },
                               terminate: {}, settleDelay: 0.01, disabled: false)
        #expect(c.closeAllWindows() == 0)
        #expect(c.eligibleWindowCount() == 0)
    }
}

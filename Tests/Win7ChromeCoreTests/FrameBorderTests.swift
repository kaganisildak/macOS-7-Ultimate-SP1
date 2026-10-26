import AppKit
import Testing
import Win7ChromeCore

/// the 8 pt glass frame overlay of decorated windows.
@Suite(.serialized) struct FrameBorderTests {
    @Test func overlayFrameGrowsLeftRightAndBottom() {
        #expect(W7FrameBorderOverlayFrame(CGRect(x: 100, y: 200, width: 400, height: 300))
                == CGRect(x: 92, y: 192, width: 416, height: 308))
        #expect(W7FrameBorderOverlayFrame(CGRect(x: -1500, y: -40, width: 10, height: 10))
                == CGRect(x: -1508, y: -48, width: 26, height: 18))
    }

    @Test func holeIsTheWindowInOverlayCoordinates() {
        #expect(W7FrameBorderHoleRect(CGRect(x: 0, y: 0, width: 416, height: 308)) == CGRect(x: 8, y: 8, width: 400, height: 300))
        #expect(W7FrameBorderHoleRect(CGRect(x: 0, y: 0, width: 10, height: 5)).isEmpty)
    }

    /// Shown only for a visible, not minimized, not full-screen, not occluded, not maximized window.
    @Test func showStateTable() {
        for bits in 0..<32 {
            let visible = bits & 1 != 0, mini = bits & 2 != 0, fs = bits & 4 != 0, occluded = bits & 8 != 0, maxed = bits & 16 != 0
            let expected = visible && !mini && !fs && !occluded && !maxed
            #expect(W7FrameBorderShouldShow(visible, mini, fs, occluded, maxed) == expected, "bits \(bits)")
        }
    }

    @MainActor private func makeWindow() -> NSWindow {
        _ = NSApplication.shared
        let w = NSWindow(contentRect: .init(x: 0, y: 0, width: 400, height: 300), styleMask: std, backing: .buffered, defer: true)
        w.isReleasedWhenClosed = false
        return w
    }

    @MainActor @Test func cornerRadiiAreRead() {
        let w = makeWindow()
        defer { w.close() }
        for top in [true, false] {
            let r = W7WindowCornerRadius(w, top)
            #expect(r >= 0 && r <= 40, "top \(top): \(r)")
        }
    }

    /// Decorating creates exactly one overlay (decorating again does not add one), hidden while the window is
    /// not on screen; closing the window releases it.
    @MainActor @Test func decoratingCreatesOneOverlayAndCloseReleasesIt() {
        W7FrameBorderUseDisabledOverride(0)
        defer { W7FrameBorderUseDisabledOverride(-1) }
        let before = W7FrameBorderLiveOverlayCount()
        weak var weakOverlay: NSWindow?
        weak var weakWindow: NSWindow?
        autoreleasepool {
            let w = makeWindow()
            W7ChromeController.decorateWindow(w)
            W7ChromeController.decorateWindow(w)
            let overlay = W7FrameBorderOverlay(w)
            #expect(overlay != nil)
            #expect(W7FrameBorderLiveOverlayCount() == before + 1)
            #expect(overlay?.ignoresMouseEvents == true)
            #expect(overlay?.canBecomeKey == false && overlay?.canBecomeMain == false)
            #expect(overlay?.parent == nil, "not attached while the window is off screen")
            #expect(!W7FrameBorderIsShowing(w))
            W7FrameBorderAttach(w)
            #expect(W7FrameBorderOverlay(w) === overlay && W7FrameBorderLiveOverlayCount() == before + 1)
            weakOverlay = overlay
            weakWindow = w
            w.close()
            #expect(W7FrameBorderOverlay(w) === overlay, "kept until the window goes away, for a reopen")
        }
        #expect(weakOverlay == nil)
        #expect(weakWindow == nil)
        #expect(W7FrameBorderLiveOverlayCount() == before)
    }

    /// A window closed and shown again (isReleasedWhenClosed NO: Settings windows, single-window apps reopened
    /// from the Dock) gets the same overlay back; deallocating the window still releases it. The visibility
    /// override stands in for being on screen, so nothing is shown on the display (the window is far off it).
    @MainActor @Test func closedAndReopenedWindowGetsItsFrameBack() {
        W7FrameBorderUseDisabledOverride(0)
        W7FrameBorderUseVisibilityOverride(1)
        defer { W7FrameBorderUseDisabledOverride(-1); W7FrameBorderUseVisibilityOverride(-1) }
        let before = W7FrameBorderLiveOverlayCount()
        weak var weakOverlay: NSWindow?
        weak var weakWindow: NSWindow?
        autoreleasepool {
            let w = makeWindow()
            w.setFrameOrigin(NSPoint(x: -12000, y: -12000))
            W7ChromeController.decorateWindow(w)
            guard let overlay = W7FrameBorderOverlay(w) else { Issue.record("no overlay"); return }
            #expect(W7FrameBorderIsShowing(w) && overlay.parent === w)
            #expect(overlay.frame == W7FrameBorderOverlayFrame(w.frame))
            w.close()
            #expect(!W7FrameBorderIsShowing(w) && overlay.parent == nil && !overlay.isVisible, "hidden on close")
            // A sync during the close itself (before AppKit orders the window out) keeps it hidden.
            NotificationCenter.default.post(name: NSWindow.didResignKeyNotification, object: w)
            #expect(!W7FrameBorderIsShowing(w) && overlay.parent == nil)
            RunLoop.main.run(until: Date().addingTimeInterval(0.05))
            // Reopening posts key/occlusion changes: the same overlay comes back.
            NotificationCenter.default.post(name: NSWindow.didChangeOcclusionStateNotification, object: w)
            #expect(W7FrameBorderIsShowing(w) && overlay.parent === w, "shown again after a reopen")
            #expect(W7FrameBorderOverlay(w) === overlay && W7FrameBorderLiveOverlayCount() == before + 1, "exactly one")
            weakOverlay = overlay
            weakWindow = w
            w.close()
        }
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        #expect(weakWindow == nil)
        #expect(weakOverlay == nil)
        #expect(W7FrameBorderLiveOverlayCount() == before)
    }

    @MainActor @Test func killSwitchMeansNoOverlay() {
        W7FrameBorderUseDisabledOverride(1)
        defer { W7FrameBorderUseDisabledOverride(-1) }
        let w = makeWindow()
        defer { w.close() }
        W7ChromeController.decorateWindow(w)
        #expect(W7FrameBorderOverlay(w) == nil)
    }

    /// Only a title bar view in the window's title bar gets an overlay (the render tool puts one in a
    /// content view); undecorated windows get none.
    @MainActor @Test func onlyDecoratedTitleBarsAttach() {
        W7FrameBorderUseDisabledOverride(0)
        defer { W7FrameBorderUseDisabledOverride(-1) }
        let w = makeWindow()
        defer { w.close() }
        w.contentView?.addSubview(W7TitlebarView(frame: NSRect(x: 0, y: 0, width: 400, height: 30)))
        #expect(W7FrameBorderOverlay(w) == nil)
        // A utility panel stays undecorated (dialog panels are decorated since DialogPanelTests).
        let panel = NSPanel(contentRect: .init(x: 0, y: 0, width: 200, height: 100), styleMask: std.union(.utilityWindow),
                            backing: .buffered, defer: true)
        panel.isReleasedWhenClosed = false
        defer { panel.close() }
        W7ChromeController.decorateWindow(panel)
        #expect(W7FrameBorderOverlay(panel) == nil)
    }
}

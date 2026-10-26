import Testing
import CoreGraphics
@testable import Win7Core

private func cg(_ id: UInt32, name: String? = nil, w: CGFloat = 400, h: CGFloat = 300,
                layer: Int = 0, onScreen: Bool = true) -> CGWindowInfo {
    CGWindowInfo(id: id, name: name, bounds: CGRect(x: 0, y: 0, width: w, height: h), layer: layer, isOnScreen: onScreen)
}
private func ax(_ id: UInt32, _ title: String?, minimized: Bool = false) -> AXWindowInfo {
    AXWindowInfo(id: id, title: title, isMinimized: minimized)
}
private func merge(ax: [AXWindowInfo]?, cg: [CGWindowInfo], images: [UInt32: String] = [:],
                   app: String = "Safari") -> [WindowListEntry<String>] {
    WindowList.merge(ax: ax, cg: cg, images: images, appName: app)
}

@Suite struct WindowListTests {
    @Test func axOrderFollowsCGFrontToBackWithMinimizedAppended() {
        let list = merge(ax: [ax(1, "A"), ax(2, "B", minimized: true), ax(3, "C")],
                         cg: [cg(3), cg(2, onScreen: false), cg(1)])
        #expect(list.map(\.id) == [3, 1, 2])
        #expect(list.map(\.title) == ["C", "A", "B"])
        #expect(list.map(\.isMinimized) == [false, false, true])
    }

    @Test func minimizedWindowAbsentFromCGIsStillListed() {
        let list = merge(ax: [ax(1, "A"), ax(9, "Gone", minimized: true)], cg: [cg(1)])
        #expect(list.map(\.id) == [1, 9])
    }

    @Test func axWindowsOnHiddenAppCountEvenWhenOffScreen() {
        let list = merge(ax: [ax(1, "A"), ax(2, "B")], cg: [cg(2, onScreen: false), cg(1, onScreen: false)])
        #expect(list.map(\.id) == [2, 1])
    }

    @Test func deduplicatesByID() {
        let list = merge(ax: [ax(1, "A"), ax(1, "A again"), ax(2, "B")], cg: [cg(1), cg(1), cg(2)])
        #expect(list.map(\.id) == [1, 2])
        #expect(list[0].title == "A")
    }

    @Test func dropsSmallAndNonZeroLayerWindows() {
        let list = merge(ax: [ax(1, "A"), ax(2, "Tiny"), ax(3, "Panel"), ax(4, "Narrow")],
                         cg: [cg(1), cg(2, w: 39, h: 300), cg(3, layer: 3), cg(4, w: 300, h: 39)])
        #expect(list.map(\.id) == [1])
        let noAX = merge(ax: nil, cg: [cg(1), cg(2, w: 20, h: 20), cg(3, layer: 25), cg(5, w: 40, h: 40)])
        #expect(noAX.map(\.id) == [1, 5])
    }

    @Test func axWithNoUsableWindowsFallsBackToOnScreenCGWindows() {
        // AX can come back empty (timeouts, apps without AX support) although CG sees windows.
        #expect(merge(ax: [], cg: [cg(1), cg(2), cg(3, onScreen: false)]).map(\.id) == [1, 2])
        // AX windows that CG rejects (too small, wrong layer) are not usable either.
        #expect(merge(ax: [ax(5, "Tiny")], cg: [cg(5, w: 10, h: 10), cg(6)]).map(\.title) == ["Safari"])
        #expect(merge(ax: [], cg: []).isEmpty)
    }

    @Test func withoutAXOnlyOnScreenCGWindowsAreListedAndNumbered() {
        let list = merge(ax: nil, cg: [cg(7), cg(8, onScreen: false), cg(9)])
        #expect(list.map(\.id) == [7, 9])
        #expect(list.map(\.title) == ["Safari (1)", "Safari (2)"])
        #expect(list.allSatisfy { !$0.isMinimized })
    }

    @Test func singleUntitledWindowIsJustTheAppName() {
        #expect(merge(ax: nil, cg: [cg(7)]).map(\.title) == ["Safari"])
    }

    @Test func cgNamesUsedWhenAvailableAndOnlyUntitledOnesNumbered() {
        let list = merge(ax: nil, cg: [cg(1, name: "Apple"), cg(2, name: ""), cg(3)])
        #expect(list.map(\.title) == ["Apple", "Safari (1)", "Safari (2)"])
        let mixed = merge(ax: [ax(1, ""), ax(2, nil), ax(3, "Doc")], cg: [cg(1, name: "From CG"), cg(2), cg(3)])
        #expect(mixed.map(\.title) == ["From CG", "Safari", "Doc"])
    }

    @Test func imagesAttachByID() {
        let list = merge(ax: [ax(1, "A"), ax(2, "B", minimized: true)], cg: [cg(1), cg(2, onScreen: false)],
                         images: [1: "img1", 5: "stray"])
        #expect(list.map(\.image) == ["img1", nil])
    }

    @Test func countMatchesMerge() {
        #expect(WindowList.counts(ax: [ax(1, "A"), ax(2, "B", minimized: true)], cg: [cg(1)]) == WindowCounts(total: 2, minimized: 1))
        #expect(WindowList.counts(ax: nil, cg: [cg(1), cg(2, onScreen: false), cg(3, w: 10, h: 10)])
                == WindowCounts(total: 1, filteredOnScreen: 1))
        // Rejected windows count as filtered only while on screen.
        #expect(WindowList.counts(ax: nil, cg: [cg(4, layer: 3), cg(5, w: 10, h: 10, onScreen: false)])
                == WindowCounts(total: 0, filteredOnScreen: 1))
        // Menu-bar status items (layer 25 and up) and desktop-level windows (negative layers, as
        // Finder's desktop) are not app panels.
        #expect(WindowList.counts(ax: nil, cg: [cg(6, w: 30, h: 24, layer: 25), cg(7, layer: 101),
                                                cg(8, layer: -2147483623), cg(9, layer: 24)])
                == WindowCounts(total: 0, filteredOnScreen: 1))
        #expect(WindowList.counts(ax: nil, cg: []) == WindowCounts(total: 0))
    }

    @Test func parsesCGWindowListDictionariesForOnePID() {
        let info: [[String: Any]] = [
            [kCGWindowNumber as String: UInt32(11), kCGWindowOwnerPID as String: Int32(42), kCGWindowLayer as String: 0,
             kCGWindowIsOnscreen as String: true, kCGWindowName as String: "Doc",
             kCGWindowBounds as String: ["X": 10.0, "Y": 20.0, "Width": 300.0, "Height": 200.0]],
            [kCGWindowNumber as String: UInt32(12), kCGWindowOwnerPID as String: Int32(42), kCGWindowLayer as String: 0,
             kCGWindowBounds as String: ["X": 0.0, "Y": 0.0, "Width": 50.0, "Height": 60.0]],
            [kCGWindowNumber as String: UInt32(13), kCGWindowOwnerPID as String: Int32(7), kCGWindowLayer as String: 0,
             kCGWindowBounds as String: ["X": 0.0, "Y": 0.0, "Width": 50.0, "Height": 60.0]],
            [kCGWindowOwnerPID as String: Int32(42)],
        ]
        let list = CGWindowInfo.list(from: info, pid: 42)
        #expect(list == [
            CGWindowInfo(id: 11, name: "Doc", bounds: CGRect(x: 10, y: 20, width: 300, height: 200), layer: 0, isOnScreen: true),
            CGWindowInfo(id: 12, name: nil, bounds: CGRect(x: 0, y: 0, width: 50, height: 60), layer: 0, isOnScreen: false),
        ])
    }
}

@Suite struct WindowPopupLayoutTests {
    @Test func listStyleWhenNoEntryHasAnImage() {
        let none: [WindowListEntry<String>] = [.init(id: 1, title: "A", isMinimized: false, image: nil),
                                                .init(id: 2, title: "B", isMinimized: true, image: nil)]
        #expect(WindowPopupLayout.style(for: none) == .list)
        let some = none + [.init(id: 3, title: "C", isMinimized: false, image: "img")]
        #expect(WindowPopupLayout.style(for: some) == .thumbnails)
        #expect(WindowPopupLayout.style(for: [WindowListEntry<String>]()) == .list)
    }

    @Test func listRowsAreStackedTopDown() {
        let size = WindowPopupLayout.listSize(rows: 3)
        #expect(size.width == WindowPopupLayout.listWidth)
        #expect(size.height == 3 * WindowPopupLayout.rowHeight + 2 * WindowPopupLayout.pad)
        let top = WindowPopupLayout.listRowRect(0, rows: 3)
        let bottom = WindowPopupLayout.listRowRect(2, rows: 3)
        #expect(top.height == WindowPopupLayout.rowHeight)
        #expect(top.minY == bottom.maxY + WindowPopupLayout.rowHeight)
        #expect(bottom.minY == WindowPopupLayout.pad)
        #expect(top.minX == WindowPopupLayout.pad && top.maxX == size.width - WindowPopupLayout.pad)
    }

    @Test func listHitTesting() {
        let r1 = WindowPopupLayout.listRowRect(1, rows: 3)
        #expect(WindowPopupLayout.listRow(at: CGPoint(x: r1.midX, y: r1.midY), rows: 3) == 1)
        #expect(WindowPopupLayout.listRow(at: CGPoint(x: 1, y: r1.midY), rows: 3) == nil)
        #expect(WindowPopupLayout.listRow(at: CGPoint(x: r1.midX, y: 2), rows: 3) == nil)
    }

    @Test func rowCountIsCappedByAvailableHeight() {
        let h = WindowPopupLayout.listSize(rows: 4).height
        #expect(WindowPopupLayout.listRowCount(entries: 10, availableHeight: h) == 4)
        #expect(WindowPopupLayout.listRowCount(entries: 2, availableHeight: h) == 2)
        #expect(WindowPopupLayout.listRowCount(entries: 2, availableHeight: 0) == 1)
        #expect(WindowPopupLayout.listRowCount(entries: 0, availableHeight: h) == 0)
    }
}

@Suite struct WindowPopupDismissalTests {
    @Test func hoverPopupClosesOnMouseExit() {
        var d = WindowPopupDismissal()
        #expect(d.handle(.hoverRequested(pid: 1)) == .show(.hover))
        #expect(d.handle(.mouseEntered) == .cancelClose)
        #expect(d.handle(.mouseExited) == .scheduleClose)
        #expect(d.handle(.hoverEnded) == .scheduleClose)
        #expect(d.handle(.closeTimerFired) == .close(.keep))   // a plain hover owes no restore
        #expect(d.mode == nil)
    }

    @Test func pinnedPopupIgnoresMouseExitAndHoverEnd() {
        var d = WindowPopupDismissal()
        #expect(d.handle(.buttonClicked(pid: 1)) == .show(.pinned))
        #expect(d.handle(.mouseEntered) == .ignore)
        #expect(d.handle(.mouseExited) == .ignore)
        #expect(d.handle(.hoverEnded) == .ignore)
        #expect(d.handle(.closeTimerFired) == .ignore)
        #expect(d.handle(.hoverRequested(pid: 1)) == .ignore)
        #expect(d.mode == .pinned)
    }

    @Test func pinnedPopupClosesOnSelectionOutsideClickEscOrReclick() {
        var d = WindowPopupDismissal()
        _ = d.handle(.buttonClicked(pid: 1))
        #expect(d.handle(.clickedInTaskbar(.anchor)) == .ignore)   // the button's own click decides
        #expect(d.handle(.buttonClicked(pid: 1)) == .close(.restore))
        #expect(d.mode == nil)

        _ = d.handle(.buttonClicked(pid: 1))
        #expect(d.handle(.clickedInTaskbar(.control)) == .close(.keep))
        _ = d.handle(.buttonClicked(pid: 1))
        #expect(d.handle(.clickedInShell) == .close(.release))
        _ = d.handle(.buttonClicked(pid: 1))
        #expect(d.handle(.clickedInOtherApp) == .close(.release))
        _ = d.handle(.buttonClicked(pid: 1))
        #expect(d.handle(.escape) == .close(.restore))
        _ = d.handle(.buttonClicked(pid: 1))
        #expect(d.handle(.selected) == .close(.release))
        #expect(d.mode == nil)
    }

    @Test func clickingTheHoveredButtonPinsInPlace() {
        var d = WindowPopupDismissal()
        _ = d.handle(.hoverRequested(pid: 1))
        #expect(d.handle(.buttonClicked(pid: 1)) == .pin)
        #expect(d.mode == .pinned)
        #expect(d.handle(.mouseExited) == .ignore)
    }

    @Test func otherButtonsReplaceThePopup() {
        var d = WindowPopupDismissal()
        _ = d.handle(.buttonClicked(pid: 1))
        #expect(d.handle(.buttonClicked(pid: 2)) == .show(.pinned))
        #expect(d.handle(.hoverRequested(pid: 3)) == .show(.hover))
        #expect(d.mode == .hover)
    }

    /// The pinned popup activates the shell. Closing it gives focus back to the user's app only when
    /// nothing else is about to take focus: a chosen window's app, a clicked app or shell window
    /// (desktop, flyout) take it themselves, and a click in the taskbar leaves focus to the
    /// taskbar's own handler while the original app is remembered for a list it may open next.
    @Test func focusIsRestoredOnlyWhenNothingElseTakesIt() {
        var d = WindowPopupDismissal()
        _ = d.handle(.buttonClicked(pid: 1))
        #expect(d.handle(.clickedInOtherApp) == .close(.release))
        #expect(d.mode == nil)
        _ = d.handle(.buttonClicked(pid: 1))
        #expect(d.handle(.selected) == .close(.release))
        _ = d.handle(.buttonClicked(pid: 1))
        #expect(d.handle(.clickedInShell) == .close(.release))
        _ = d.handle(.buttonClicked(pid: 1))
        #expect(d.handle(.escape) == .close(.restore))
        _ = d.handle(.buttonClicked(pid: 1))
        #expect(d.handle(.buttonClicked(pid: 1)) == .close(.restore))
        // A pinned popup replaced by another button's hover popup: its close timer restores too.
        _ = d.handle(.buttonClicked(pid: 1))
        _ = d.handle(.hoverRequested(pid: 2))
        #expect(d.handle(.closeTimerFired) == .close(.restore))
    }

    /// Any taskbar click other than a left click on the opening button (another button, the orb,
    /// Show Desktop, the tray, a right click anywhere including the anchor) closes without
    /// restoring: the taskbar's handler activates, opens a menu, or pins a new list.
    @Test func taskbarClicksCloseAndKeepTheOriginalApp() {
        var d = WindowPopupDismissal()
        _ = d.handle(.buttonClicked(pid: 1))
        #expect(d.handle(.clickedInTaskbar(.control)) == .close(.keep))
        #expect(d.mode == nil)
        // The pinned list a taskbar click opens next restores on Esc as usual.
        #expect(d.handle(.buttonClicked(pid: 2)) == .show(.pinned))
        #expect(d.handle(.escape) == .close(.restore))
    }

    @Test func nothingToShowRestoresOnlyAPinnedRequest() {
        var d = WindowPopupDismissal()
        _ = d.handle(.buttonClicked(pid: 1))
        #expect(d.handle(.nothingToShow) == .close(.restore))
        #expect(d.mode == nil)
        _ = d.handle(.hoverRequested(pid: 1))
        #expect(d.handle(.nothingToShow) == .close(.keep))
        #expect(d.mode == nil)
    }

    /// A taskbar click (here the orb) settles the owed restore; a later hover popup's timer must not
    /// pull focus back to the old app (it would steal it from the Start menu).
    @Test func hoverAfterATaskbarClickDoesNotRestore() {
        var d = WindowPopupDismissal()
        _ = d.handle(.buttonClicked(pid: 1))
        #expect(d.handle(.clickedInTaskbar(.control)) == .close(.keep))
        _ = d.handle(.hoverRequested(pid: 2))
        #expect(d.handle(.closeTimerFired) == .close(.keep))
        _ = d.handle(.hoverRequested(pid: 2))
        #expect(d.handle(.nothingToShow) == .close(.keep))
    }

    /// A hover popup that replaces a pinned one inherits the restore the pinned one owed.
    @Test func hoverReplacingAPinnedPopupStillRestores() {
        var d = WindowPopupDismissal()
        _ = d.handle(.buttonClicked(pid: 1))
        #expect(d.handle(.hoverRequested(pid: 2)) == .show(.hover))
        #expect(d.handle(.closeTimerFired) == .close(.restore))

        _ = d.handle(.buttonClicked(pid: 1))
        _ = d.handle(.hoverRequested(pid: 2))
        #expect(d.handle(.nothingToShow) == .close(.restore))

        // Settled once: a plain hover afterwards owes nothing.
        _ = d.handle(.hoverRequested(pid: 3))
        #expect(d.handle(.closeTimerFired) == .close(.keep))
    }

    @Test func hoverThenClickOwesARestore() {
        var d = WindowPopupDismissal()
        _ = d.handle(.hoverRequested(pid: 1))
        #expect(d.handle(.buttonClicked(pid: 1)) == .pin)
        #expect(d.handle(.escape) == .close(.restore))
        _ = d.handle(.buttonClicked(pid: 1))
        d.closed()
        _ = d.handle(.hoverRequested(pid: 1))
        #expect(d.handle(.closeTimerFired) == .close(.keep))
    }

    /// A hover popup that inherited an owed restore must settle it on a taskbar click (the orb,
    /// Ctrl+Esc, Show Desktop, the tray), or its close timer would steal focus from Start.
    @Test func taskbarClickSettlesARestoreInheritedByAHoverPopup() {
        var d = WindowPopupDismissal()
        _ = d.handle(.buttonClicked(pid: 1))
        _ = d.handle(.hoverRequested(pid: 2))
        #expect(d.restoreOwed)
        #expect(d.handle(.clickedInTaskbar(.control)) == .close(.keep))
        #expect(!d.restoreOwed)
        #expect(d.handle(.closeTimerFired) == .ignore)
        _ = d.handle(.hoverRequested(pid: 2))
        #expect(d.handle(.closeTimerFired) == .close(.keep))
    }

    /// A left click on an empty part of the taskbar opens nothing, so the shell must not be left
    /// active with no UI: it restores like Esc.
    @Test func emptyTaskbarClickRestores() {
        var d = WindowPopupDismissal()
        _ = d.handle(.buttonClicked(pid: 1))
        #expect(d.handle(.clickedInTaskbar(.empty)) == .close(.restore))
        #expect(d.mode == nil)
        _ = d.handle(.hoverRequested(pid: 1))
        #expect(d.handle(.clickedInTaskbar(.empty)) == .close(.keep))
        #expect(d.handle(.clickedInTaskbar(.empty)) == .ignore)
    }

    @Test func taskbarClickClassification() {
        let anchor = CGRect(x: 54, y: 0, width: 60, height: 40)
        let inside = CGPoint(x: 80, y: 20), outside = CGPoint(x: 200, y: 20)
        #expect(TaskbarClickTarget.classify(.left, at: inside, anchor: anchor, hit: .button) == .anchor)
        // A right click on the anchor opens its jump list.
        #expect(TaskbarClickTarget.classify(.right, at: inside, anchor: anchor, hit: .button) == .control)
        #expect(TaskbarClickTarget.classify(.left, at: outside, anchor: anchor, hit: .button) == .control)
        #expect(TaskbarClickTarget.classify(.left, at: outside, anchor: anchor, hit: .bare) == .empty)
        // A right click on empty taskbar opens the taskbar menu, which decides focus.
        #expect(TaskbarClickTarget.classify(.right, at: outside, anchor: anchor, hit: .bare) == .control)
    }

    @Test func closedPopupIgnoresEverythingButRequests() {
        var d = WindowPopupDismissal()
        #expect(d.handle(.mouseExited) == .ignore)
        #expect(d.handle(.escape) == .ignore)
        #expect(d.handle(.clickedInTaskbar(.control)) == .ignore)
        #expect(d.handle(.clickedInShell) == .ignore)
        #expect(d.handle(.clickedInOtherApp) == .ignore)
        _ = d.handle(.buttonClicked(pid: 1))
        d.closed()
        #expect(d.mode == nil)
        #expect(d.handle(.buttonClicked(pid: 1)) == .show(.pinned))
    }
}

/// the dylib's 8 pt Aero frame overlay is a separate CG window of the same app. Its bounds (CG's top-left
/// origin) are its window's grown by 8 on the left, right and bottom with the same top; the shell drops it.
@Suite struct FrameBorderOverlayFilterTests {
    private func win(_ id: UInt32, _ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat) -> CGWindowInfo {
        CGWindowInfo(id: id, name: nil, bounds: CGRect(x: x, y: y, width: w, height: h), layer: 0, isOnScreen: true)
    }

    @Test func dropsTheOverlayOfAnotherWindow() {
        let doc = win(1, 100, 50, 400, 300), overlay = win(2, 92, 50, 416, 308), other = win(3, 600, 80, 200, 150)
        #expect(WindowList.droppingFrameBorderOverlays([overlay, doc, other]) == [doc, other])
        #expect(WindowList.droppingFrameBorderOverlays([doc, other, overlay]) == [doc, other])
        #expect(WindowList.frameBorderWidth == 8)
    }

    /// Only that exact geometry: a different top, width or height, or no window it frames, keeps the window.
    @Test func keepsWindowsThatAreNotExactOverlays() {
        let doc = win(1, 100, 50, 400, 300)
        let near: [CGWindowInfo] = [win(2, 92, 42, 416, 308),   // grown on top too
                                    win(3, 92, 50, 417, 308),   // one point wider
                                    win(4, 92, 50, 416, 300),   // not grown at the bottom
                                    win(5, 100, 50, 400, 300)]  // same bounds (a duplicate, not an overlay)
        for w in near { #expect(WindowList.droppingFrameBorderOverlays([doc, w]) == [doc, w], "\(w.bounds)") }
        #expect(WindowList.droppingFrameBorderOverlays([win(2, 92, 50, 416, 308)]).count == 1, "alone: kept")
        #expect(WindowList.droppingFrameBorderOverlays([]).isEmpty)
    }

    /// The per-pid lists the shell builds are filtered; an overlay-shaped window of another app is not.
    @Test func cgListsArePerAppFiltered() {
        func dict(_ id: UInt32, _ pid: Int32, _ r: CGRect) -> [String: Any] {
            [kCGWindowNumber as String: id, kCGWindowOwnerPID as String: pid, kCGWindowLayer as String: 0,
             kCGWindowIsOnscreen as String: true,
             kCGWindowBounds as String: ["X": Double(r.minX), "Y": Double(r.minY), "Width": Double(r.width), "Height": Double(r.height)]]
        }
        let info = [dict(10, 42, CGRect(x: 92, y: 50, width: 416, height: 308)),
                    dict(11, 42, CGRect(x: 100, y: 50, width: 400, height: 300)),
                    dict(12, 7, CGRect(x: 92, y: 50, width: 416, height: 308))]
        #expect(CGWindowInfo.list(from: info, pid: 42).map(\.id) == [11])
        #expect(CGWindowInfo.list(from: info, pid: 7).map(\.id) == [12])
        let byPID = CGWindowInfo.byPID(from: info)
        #expect(byPID[42]?.map(\.id) == [11] && byPID[7]?.map(\.id) == [12])
        // What the Option+Tab switcher skips while walking the raw result.
        #expect(CGWindowInfo.frameBorderOverlayIDs(in: info) == [10])
        #expect(CGWindowInfo.frameBorderOverlayIDs(in: [dict(12, 7, CGRect(x: 92, y: 50, width: 416, height: 308))]).isEmpty)
        #expect(CGWindowInfo.frameBorderOverlayIDs(in: []).isEmpty)
    }
}

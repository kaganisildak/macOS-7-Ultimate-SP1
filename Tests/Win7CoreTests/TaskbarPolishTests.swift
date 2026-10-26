import Testing
import Foundation
import CoreGraphics
@testable import Win7Core

private func pin(_ id: String) -> PinnedApp { PinnedApp(bundleID: id, name: id) }

@Suite struct WindowArrangementTests {
    /// AX coordinates: the area's top-left is its origin.
    private let area = CGRect(x: 0, y: 25, width: 1200, height: 900)

    @Test func sideBySideSplitsTheWidth() {
        let f = WindowArranger.frames(.sideBySide, count: 3, in: area)
        #expect(f == [CGRect(x: 0, y: 25, width: 400, height: 900),
                      CGRect(x: 400, y: 25, width: 400, height: 900),
                      CGRect(x: 800, y: 25, width: 400, height: 900)])
    }

    @Test func stackedSplitsTheHeight() {
        let f = WindowArranger.frames(.stacked, count: 2, in: area)
        #expect(f == [CGRect(x: 0, y: 25, width: 1200, height: 450),
                      CGRect(x: 0, y: 475, width: 1200, height: 450)])
    }

    /// Four or more windows tile in a grid; the later rows (columns) take the extra windows and the
    /// last tile absorbs rounding, so the tiles cover the area exactly.
    @Test func gridsForMoreWindows() {
        let side = WindowArranger.frames(.sideBySide, count: 5, in: CGRect(x: 0, y: 0, width: 1000, height: 800))
        #expect(side.count == 5)
        #expect(side[0] == CGRect(x: 0, y: 0, width: 500, height: 400))
        #expect(side[1] == CGRect(x: 500, y: 0, width: 500, height: 400))
        #expect(side[2] == CGRect(x: 0, y: 400, width: 333, height: 400))
        #expect(side[4] == CGRect(x: 666, y: 400, width: 334, height: 400))

        let stacked = WindowArranger.frames(.stacked, count: 4, in: CGRect(x: 10, y: 0, width: 1000, height: 800))
        #expect(stacked == [CGRect(x: 10, y: 0, width: 500, height: 400), CGRect(x: 10, y: 400, width: 500, height: 400),
                            CGRect(x: 510, y: 0, width: 500, height: 400), CGRect(x: 510, y: 400, width: 500, height: 400)])
    }

    @Test func cascadeStepsByTheTitleBarHeight() {
        let f = WindowArranger.frames(.cascade, count: 3, in: area)
        #expect(WindowArranger.cascadeStep == 30)
        #expect(f[0] == CGRect(x: 0, y: 25, width: 800, height: 600))
        #expect(f[1] == CGRect(x: 30, y: 55, width: 800, height: 600))
        #expect(f[2] == CGRect(x: 60, y: 85, width: 800, height: 600))
        for r in f { #expect(area.contains(r)) }
    }

    /// A long cascade starts over at the top-left instead of running off the area.
    @Test func cascadeWrapsInsideTheArea() {
        let f = WindowArranger.frames(.cascade, count: 25, in: area)
        for r in f { #expect(area.contains(r)) }
        #expect(f.filter { $0.origin == area.origin }.count >= 2)
    }

    @Test func noWindowsNoFrames() {
        for k in [WindowArrangement.cascade, .stacked, .sideBySide] { #expect(WindowArranger.frames(k, count: 0, in: area).isEmpty) }
    }

    /// The area windows are arranged in: the screen's visible frame without the taskbar strip, in AX
    /// coordinates.
    @Test func arrangeAreaLeavesTheTaskbarOut() {
        let screen = CGRect(x: 0, y: 0, width: 1440, height: 900)
        // AppKit visible frame with the Dock hidden (4 pt) and a 25 pt menu bar.
        let visible = CGRect(x: 0, y: 4, width: 1440, height: 871)
        let ax = WindowArranger.area(screenFrame: screen, visibleFrame: visible, taskbarHeight: 40, primaryHeight: 900)
        #expect(ax == CGRect(x: 0, y: 25, width: 1440, height: 835))
    }
}

@Suite struct PinReorderTests {
    @Test func movesAPinToAnotherSlot() {
        let pins = ["a", "b", "c", "d"].map(pin)
        #expect(TaskbarPinOrder.moved(pins, bundleID: "a", to: 2).map(\.bundleID) == ["b", "c", "a", "d"])
        #expect(TaskbarPinOrder.moved(pins, bundleID: "d", to: 0).map(\.bundleID) == ["d", "a", "b", "c"])
        #expect(TaskbarPinOrder.moved(pins, bundleID: "b", to: 9).map(\.bundleID) == ["a", "c", "d", "b"])
        #expect(TaskbarPinOrder.moved(pins, bundleID: "zz", to: 1) == pins)
    }

    /// Duplicate pins collapse into one button, so slots count distinct pins.
    @Test func duplicatesCollapse() {
        let pins = ["a", "b", "a", "c"].map(pin)
        #expect(TaskbarPinOrder.moved(pins, bundleID: "c", to: 0).map(\.bundleID) == ["c", "a", "b"])
    }

    @Test func slotUnderThePointerIsClampedToThePinnedButtons() {
        // Buttons 60 wide starting at x 54; the dragged button's centre decides.
        #expect(TaskbarPinOrder.slot(centerX: 54 + 30, firstX: 54, buttonWidth: 60, firstIndex: 0, pinCount: 3) == 0)
        #expect(TaskbarPinOrder.slot(centerX: 54 + 125, firstX: 54, buttonWidth: 60, firstIndex: 0, pinCount: 3) == 2)
        #expect(TaskbarPinOrder.slot(centerX: 54 + 500, firstX: 54, buttonWidth: 60, firstIndex: 0, pinCount: 3) == 2)
        #expect(TaskbarPinOrder.slot(centerX: 0, firstX: 54, buttonWidth: 60, firstIndex: 0, pinCount: 3) == 0)
        // On a later page the first visible button is item 4.
        #expect(TaskbarPinOrder.slot(centerX: 54 + 90, firstX: 54, buttonWidth: 60, firstIndex: 4, pinCount: 6) == 5)
        #expect(TaskbarPinOrder.slot(centerX: 54, firstX: 54, buttonWidth: 60, firstIndex: 4, pinCount: 6) == 4)
    }

    @Test func dragGestures() {
        #expect(TaskbarDrag.gesture(dx: 3, dy: 2, isPinned: true) == nil)
        #expect(TaskbarDrag.gesture(dx: 7, dy: 2, isPinned: true) == .reorder)
        #expect(TaskbarDrag.gesture(dx: -7, dy: 0, isPinned: true) == .reorder)
        // Running unpinned buttons are not draggable.
        #expect(TaskbarDrag.gesture(dx: 30, dy: 0, isPinned: false) == nil)
        // Dragging up opens the jump list (AppKit y grows upward).
        #expect(TaskbarDrag.gesture(dx: 2, dy: 21, isPinned: true) == .jumpList)
        #expect(TaskbarDrag.gesture(dx: 2, dy: 21, isPinned: false) == .jumpList)
        #expect(TaskbarDrag.gesture(dx: 2, dy: -30, isPinned: false) == nil)
    }
}

@Suite struct TaskbarPagingTests {
    @Test func everythingFitsOnOnePage() {
        let p = TaskbarPaging(count: 5, available: 300, buttonWidth: 60)
        #expect(p.pageCount == 1 && p.perPage == 5 && !p.showsArrows)
        #expect(p.range(page: 0) == 0..<5)
    }

    /// When the buttons don't fit, the arrows take their width and the buttons page.
    @Test func overflowPages() {
        let p = TaskbarPaging(count: 10, available: 300, buttonWidth: 60)
        #expect(p.showsArrows)
        #expect(p.perPage == 4)   // (300 - 17) / 60
        #expect(p.pageCount == 3)
        #expect(p.range(page: 0) == 0..<4)
        #expect(p.range(page: 2) == 8..<10)
        #expect(p.clamped(7) == 2 && p.clamped(-1) == 0)
        #expect(p.page(containing: 9) == 2)
        #expect(!p.canPageUp(0) && p.canPageDown(0) && p.canPageUp(2) && !p.canPageDown(2))
    }

    @Test func tinyAreaStillShowsOneButtonPerPage() {
        let p = TaskbarPaging(count: 3, available: 20, buttonWidth: 60)
        #expect(p.perPage == 1 && p.pageCount == 3)
        let none = TaskbarPaging(count: 0, available: 300, buttonWidth: 60)
        #expect(none.pageCount == 1 && none.range(page: 0) == 0..<0)
    }
}

@Suite struct IconTintTests {
    private func pixels(_ colors: [(UInt8, UInt8, UInt8, UInt8)]) -> [UInt8] { colors.flatMap { [$0.0, $0.1, $0.2, $0.3] } }

    @Test func averagesOpaquePixelsOnly() {
        // Two opaque blue-ish pixels, one transparent red one that must not count.
        let c = IconTint.dominantColor(premultipliedRGBA: pixels([(0, 64, 200, 255), (0, 96, 220, 255), (255, 0, 0, 10)]))
        #expect(c != nil)
        if let c { #expect(c.b > c.g && c.g > c.r && c.r < 0.1) }
    }

    /// The glow is saturated and bright, even for a dull icon.
    @Test func boostsSaturationAndBrightness() throws {
        let c = try #require(IconTint.dominantColor(premultipliedRGBA: pixels([(100, 120, 100, 255)])))
        let maxC = max(c.r, c.g, c.b), minC = min(c.r, c.g, c.b)
        #expect(maxC >= 0.85)
        #expect((maxC - minC) / maxC > (120.0 - 100.0) / 120.0)
        #expect(c.g == maxC)
    }

    @Test func greyStaysGreyAndEmptyIsNil() throws {
        let g = try #require(IconTint.dominantColor(premultipliedRGBA: pixels([(128, 128, 128, 255)])))
        #expect(abs(g.r - g.g) < 0.001 && abs(g.g - g.b) < 0.001)
        #expect(IconTint.dominantColor(premultipliedRGBA: pixels([(0, 0, 0, 0)])) == nil)
        #expect(IconTint.dominantColor(premultipliedRGBA: []) == nil)
    }
}

@Suite struct TaskbarClickClassificationTests {
    private let anchor = CGRect(x: 54, y: 0, width: 60, height: 40)
    private let inside = CGPoint(x: 80, y: 20), outside = CGPoint(x: 200, y: 20)

    @Test func leftClicks() {
        #expect(TaskbarClickTarget.classify(.left, at: inside, anchor: anchor, hit: .button) == .anchor)
        for hit in [TaskbarHit.button, .orb, .showDesktop, .tray, .pager] {
            #expect(TaskbarClickTarget.classify(.left, at: outside, anchor: anchor, hit: hit) == .control)
        }
        #expect(TaskbarClickTarget.classify(.left, at: outside, anchor: anchor, hit: .bare) == .empty)
    }

    /// A right click opens a menu on a button (its jump list), the orb, the tray and the bare taskbar
    /// (the taskbar menu), whose handler decides focus. Show Desktop has none: like a bare click.
    @Test func rightClicks() {
        #expect(TaskbarClickTarget.classify(.right, at: inside, anchor: anchor, hit: .button) == .control)
        for hit in [TaskbarHit.button, .orb, .tray, .bare, .pager] {
            #expect(TaskbarClickTarget.classify(.right, at: outside, anchor: anchor, hit: hit) == .control)
        }
        #expect(TaskbarClickTarget.classify(.right, at: outside, anchor: anchor, hit: .showDesktop) == .empty)
    }

    /// A middle click only does something on a button (a new window / launch); elsewhere it restores.
    @Test func middleClicks() {
        #expect(TaskbarClickTarget.classify(.middle, at: inside, anchor: anchor, hit: .button) == .control)
        #expect(TaskbarClickTarget.classify(.middle, at: outside, anchor: anchor, hit: .button) == .control)
        for hit in [TaskbarHit.orb, .showDesktop, .tray, .pager, .bare] {
            #expect(TaskbarClickTarget.classify(.middle, at: outside, anchor: anchor, hit: hit) == .empty)
        }
    }

    /// Buttons past the middle one (back/forward) do nothing anywhere, even on a taskbar button.
    @Test func otherButtonsDoNothing() {
        for hit in [TaskbarHit.button, .orb, .showDesktop, .tray, .pager, .bare] {
            #expect(TaskbarClickTarget.classify(.other, at: inside, anchor: anchor, hit: hit) == .empty)
        }
    }

    @Test func nonButtonRightAndMiddleClicksRestoreAnOwedFocus() {
        var d = WindowPopupDismissal()
        _ = d.handle(.buttonClicked(pid: 1))
        let t = TaskbarClickTarget.classify(.middle, at: outside, anchor: anchor, hit: .orb)
        #expect(d.handle(.clickedInTaskbar(t)) == .close(.restore))
        _ = d.handle(.buttonClicked(pid: 1))
        let sd = TaskbarClickTarget.classify(.right, at: outside, anchor: anchor, hit: .showDesktop)
        #expect(d.handle(.clickedInTaskbar(sd)) == .close(.restore))
    }
}

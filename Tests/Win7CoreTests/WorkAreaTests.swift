import AppKit
import CoreGraphics
import Testing
@testable import Win7Core

// AX coordinates (global, top-left origin), as the shell's window service reads them: a 1849×1082
// primary screen with a 37 pt menu bar and the 40 pt taskbar along the bottom.
private let screen = CGRect(x: 0, y: 0, width: 1849, height: 1082)
private let bar = CGRect(x: 0, y: 1042, width: 1849, height: 40)
private let visible = CGRect(x: 0, y: 37, width: 1849, height: 1005)

private func adjusted(_ frame: CGRect, flags: WorkAreaFlags = []) -> CGRect? {
    WorkArea.adjusted(frame: frame, visible: visible, bar: bar, flags: flags)
}

@Suite struct WorkAreaTests {
    @Test func overlapOf20IsMovedUp20() {
        #expect(adjusted(CGRect(x: 100, y: 500, width: 800, height: 562))
                == CGRect(x: 100, y: 480, width: 800, height: 562))
    }

    @Test func windowTallerThanVisibleIsClampedToTheVisibleArea() {
        #expect(adjusted(CGRect(x: 100, y: 60, width: 800, height: 1020))
                == CGRect(x: 100, y: 37, width: 800, height: 1005))
        // A zoomed window as tall as the screen's visible frame without the taskbar.
        #expect(adjusted(CGRect(x: 0, y: 37, width: 1849, height: 1045))
                == CGRect(x: 0, y: 37, width: 1849, height: 1005))
    }

    @Test func eachFlagLeavesTheWindowAlone() {
        let under = CGRect(x: 100, y: 500, width: 800, height: 562)
        let tall = CGRect(x: 100, y: 60, width: 800, height: 1020)
        for flag: WorkAreaFlags in [.fullscreen, .sheetOrPanel, .shellOwned, .userDragging] {
            #expect(adjusted(under, flags: flag) == nil)
            #expect(adjusted(tall, flags: flag) == nil)
        }
        #expect(adjusted(under, flags: [.fullscreen, .userDragging]) == nil)
    }

    @Test func windowFullyAboveTheBarIsLeftAlone() {
        #expect(adjusted(CGRect(x: 100, y: 100, width: 800, height: 500)) == nil)
        // Touching the bar's top edge is not an overlap.
        #expect(adjusted(CGRect(x: 100, y: 542, width: 800, height: 500)) == nil)
        // Under a point (rounding in an app's frame) is not an overlap either: no endless nudging.
        #expect(adjusted(CGRect(x: 100, y: 542.4, width: 800, height: 500)) == nil)
    }

    @Test func windowWhoseTopIsInsideTheBarSettlesAboveIt() {
        #expect(adjusted(CGRect(x: 100, y: 1050, width: 800, height: 300))
                == CGRect(x: 100, y: 742, width: 800, height: 300))
    }

    @Test func windowsOnOtherDisplaysAreLeftAlone() {
        // A display to the right of the primary: no horizontal overlap with the bar.
        #expect(adjusted(CGRect(x: 1900, y: 900, width: 800, height: 600)) == nil)
        // A display below the primary: the window's top is under the primary's bottom edge.
        #expect(adjusted(CGRect(x: 100, y: 1082, width: 800, height: 600)) == nil)
    }

    @Test func noBarOrNoVisibleAreaMeansNothingToDo() {
        let under = CGRect(x: 100, y: 500, width: 800, height: 562)
        #expect(WorkArea.adjusted(frame: under, visible: visible, bar: .zero, flags: []) == nil)
        #expect(WorkArea.adjusted(frame: under, visible: .zero, bar: bar, flags: []) == nil)
    }

    @Test func visibleAreaStopsAtTheBar() {
        // The screen's visible frame (menu bar off; the Dock is hidden so it reaches the bottom).
        let screenVisible = CGRect(x: 0, y: 37, width: 1849, height: 1045)
        #expect(WorkArea.visible(screenVisible: screenVisible, bar: bar) == visible)
        // A Dock already keeping its own band free: the smaller of the two wins.
        let withDock = CGRect(x: 0, y: 37, width: 1849, height: 900)
        #expect(WorkArea.visible(screenVisible: withDock, bar: bar) == withDock)
        #expect(screen.contains(visible))
    }

    /// Snap uses exactly the keeper's work area on the bar's screen, so a snapped
    /// or snap-maximized window is never touched by the keeper, with or without a 37 pt menu bar.
    @Test func snapAreaIsTheWorkArea() {
        for menuBar: CGFloat in [0, 37] {
            let screenVisible = CGRect(x: 0, y: menuBar, width: 1849, height: 1082 - menuBar)
            let usable = SnapGeometry.usableRect(screenVisible: screenVisible, bar: bar)
            let work = WorkArea.visible(screenVisible: screenVisible, bar: bar)
            #expect(usable == work)
            for target in [SnapTarget.maximize, .leftHalf, .rightHalf] {
                let snapped = SnapGeometry.frame(for: target, usable: usable)
                #expect(WorkArea.adjusted(frame: snapped, visible: work, bar: bar, flags: []) == nil,
                        "menu bar \(menuBar), \(target)")
            }
            // Win+Shift+Up uses the same area.
            let tall = WindowMoves.verticallyMaximized(CGRect(x: 200, y: 300, width: 640, height: 400), usable: usable)
            #expect(WorkArea.adjusted(frame: tall, visible: work, bar: bar, flags: []) == nil)
        }
        // Another display (no bar): its visible frame as is.
        let left = CGRect(x: -1920, y: -200, width: 1920, height: 1080)
        #expect(SnapGeometry.usableRect(screenVisible: left, bar: nil) == left)
    }
}

/// What the keeper remembers per app, so an app that puts its window
/// back is tried once, and at most twice per window per 10 s.
@Suite struct WorkAreaMemoryTests {
    private let f0 = CGRect(x: 100, y: 500, width: 800, height: 562)
    private let f1 = CGRect(x: 100, y: 480, width: 800, height: 562)

    @Test func aFrameIsLookedAtOnce() {
        var m = WorkAreaMemory()
        #expect(m.shouldLook(id: 1, frame: f0))
        m.noteLooked(id: 1, frame: f0)
        #expect(!m.shouldLook(id: 1, frame: f0))
        #expect(m.shouldLook(id: 2, frame: f0))
        #expect(m.shouldLook(id: 1, frame: f1))
    }

    /// The fight: F0 → moved to F1 → the app restores F0 → never adjusted again.
    @Test func aFrameTheKeeperMovedFromIsNeverAdjustedAgain() {
        var m = WorkAreaMemory()
        m.noteLooked(id: 1, frame: f0)
        m.noteMoved(id: 1, from: f0, to: f1, now: 0)
        #expect(!m.shouldLook(id: 1, frame: f1))
        #expect(!m.shouldLook(id: 1, frame: f0))   // the app put it back
        let f2 = CGRect(x: 100, y: 510, width: 800, height: 562)
        #expect(m.shouldLook(id: 1, frame: f2))
    }

    /// After a resolution change the work area is new, so every window is looked at again once —
    /// but a frame the keeper moved a window from stays left alone, and the move limit still holds.
    @Test func aScreenChangeForgetsTheFramesLookedAt() {
        var m = WorkAreaMemory()
        m.noteLooked(id: 1, frame: f0)
        m.noteLooked(id: 2, frame: f0)
        m.noteMoved(id: 2, from: f0, to: f1, now: 0)
        m.noteMoved(id: 2, from: CGRect(x: 0, y: 0, width: 10, height: 10), to: f1, now: 1)
        m.forgetLooks()
        #expect(m.shouldLook(id: 1, frame: f0))
        #expect(m.shouldLook(id: 2, frame: f1))
        #expect(!m.shouldLook(id: 2, frame: f0))
        #expect(!m.canMove(id: 2, now: 2))
        #expect(m.count == 2)
    }

    @Test func atMostTwoMovesPerWindowPerTenSeconds() {
        #expect(WorkAreaMemory.maxMoves == 2 && WorkAreaMemory.moveWindow == 10)
        var m = WorkAreaMemory()
        #expect(m.canMove(id: 1, now: 100))
        m.noteMoved(id: 1, from: f0, to: f1, now: 100)
        #expect(m.canMove(id: 1, now: 101))
        m.noteMoved(id: 1, from: CGRect(x: 0, y: 900, width: 50, height: 300), to: f1, now: 101)
        #expect(!m.canMove(id: 1, now: 105))
        #expect(!m.canMove(id: 1, now: 109.9))
        #expect(m.canMove(id: 2, now: 105))   // per window
        #expect(m.canMove(id: 1, now: 110.5))  // the first move is 10 s old
    }

    @Test func memoryIsClearedPastItsCapacity() {
        #expect(WorkAreaMemory.capacity == 256)
        var m = WorkAreaMemory()
        for id in 0..<UInt32(256) { m.noteLooked(id: id, frame: f0) }
        #expect(m.count == 256)
        #expect(!m.shouldLook(id: 0, frame: f0))
        m.noteLooked(id: 999, frame: f0)
        #expect(m.count == 1)
        #expect(m.shouldLook(id: 0, frame: f0))   // forgotten: looked at again once
    }
}

@Suite struct ShellWindowLevelTests {
    @Test func taskbarSitsAtTheDocksLevelAboveAppWindows() {
        let taskbar = ShellWindowLevels.taskbar(legacy: false)
        #expect(taskbar == Int(CGWindowLevelForKey(.dockWindow)))
        #expect(taskbar == 20)
        // App windows, floating palettes and modal panels stay under the bar.
        #expect(NSWindow.Level.normal.rawValue < taskbar)
        #expect(NSWindow.Level.floating.rawValue < taskbar)
        #expect(NSWindow.Level.modalPanel.rawValue < taskbar)
        // System overlays (menu bar, status items) stay above it.
        #expect(NSWindow.Level.mainMenu.rawValue > taskbar)
        #expect(NSWindow.Level.statusBar.rawValue > taskbar)
    }

    @Test func legacyTaskbarLevelIsTheOldStatusBarLevel() {
        #expect(ShellWindowLevels.taskbar(legacy: true) == NSWindow.Level.statusBar.rawValue)
    }

    @Test func shellPopupsKeepTheirAppKitLevels() {
        #expect(ShellWindowLevels.startMenu == NSWindow.Level.popUpMenu.rawValue)
        #expect(ShellWindowLevels.trayFlyout == NSWindow.Level.popUpMenu.rawValue)
        #expect(ShellWindowLevels.jumpList == NSWindow.Level.statusBar.rawValue + 1)
        #expect(ShellWindowLevels.thumbnailPopup == NSWindow.Level.statusBar.rawValue + 1)
        #expect(ShellWindowLevels.switcher == NSWindow.Level.screenSaver.rawValue)
        #expect(ShellWindowLevels.snapPreview == NSWindow.Level.statusBar.rawValue)
        #expect(ShellWindowLevels.permissionBalloon == NSWindow.Level.statusBar.rawValue)
    }

    @Test func everyShellPopupOpensAboveTheTaskbar() {
        let names = ShellWindowLevels.aboveTaskbar.map(\.name)
        #expect(Set(names) == ["start menu", "tray flyout", "jump list", "thumbnail popup", "switcher",
                               "snap preview", "permission balloon"])
        for (name, level) in ShellWindowLevels.aboveTaskbar {
            #expect(level > ShellWindowLevels.taskbar(legacy: false), "\(name)")
            #expect(level >= ShellWindowLevels.taskbar(legacy: true), "\(name)")
        }
        // The desktop and its gadgets stay under everything.
        #expect(Int(CGWindowLevelForKey(.desktopIconWindow)) < ShellWindowLevels.taskbar(legacy: false))
    }
}

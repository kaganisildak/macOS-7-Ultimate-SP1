import AppKit
import Testing
import Win7ChromeCore

private func key(_ code: Int) -> String { String(UnicodeScalar(UInt16(code))!) }

@Test func shortcuts() {
    #expect(W7ShortcutString("s", .command) == "Cmd+S")
    #expect(W7ShortcutString("S", .command) == "Shift+Cmd+S")       // uppercase key implies Shift, in the usual order
    #expect(W7ShortcutString("S", .command) == W7ShortcutString("s", [.shift, .command]))
    #expect(W7ShortcutString("s", [.control, .option, .shift, .command]) == "Ctrl+Alt+Shift+Cmd+S")
    #expect(W7ShortcutString("", .command) == nil)
    #expect(W7ShortcutString("\r", .command) == "Cmd+Enter")
    #expect(W7ShortcutString(key(NSLeftArrowFunctionKey), [.option, .command]) == "Alt+Cmd+Left")
    #expect(W7ShortcutString(key(NSF5FunctionKey), []) == "F5")
    #expect(W7ShortcutString(",", .command) == "Cmd+,")
}

@Test func shortcutKeyNames() {
    #expect(W7ShortcutString("\t", .control) == "Ctrl+Tab")
    #expect(W7ShortcutString("\u{1b}", []) == "Esc")
    #expect(W7ShortcutString(" ", .command) == "Cmd+Space")
    #expect(W7ShortcutString("\u{7f}", .command) == "Cmd+Backspace")
    #expect(W7ShortcutString(key(NSBackspaceCharacter), .command) == "Cmd+Backspace")
    #expect(W7ShortcutString(key(NSDeleteFunctionKey), []) == "Del")
    #expect(W7ShortcutString(key(NSUpArrowFunctionKey), .command) == "Cmd+Up")
    #expect(W7ShortcutString(key(NSDownArrowFunctionKey), .command) == "Cmd+Down")
    #expect(W7ShortcutString(key(NSRightArrowFunctionKey), .command) == "Cmd+Right")
    #expect(W7ShortcutString(key(NSF1FunctionKey), .shift) == "Shift+F1")
    #expect(W7ShortcutString(key(NSF20FunctionKey), []) == "F20")
    // Shift given explicitly with an uppercase key is not doubled; non-shortcut flags are ignored.
    #expect(W7ShortcutString("S", [.shift, .command]) == "Shift+Cmd+S")
    #expect(W7ShortcutString("s", [.command, .function, .capsLock]) == "Cmd+S")
    // Uppercasing must not depend on the locale (Turkish dotted i).
    #expect(W7ShortcutString("i", .command) == "Cmd+I")
    // A function key with no name is not drawn as a glyph.
    #expect(W7ShortcutString(key(NSHelpFunctionKey), .command) == nil)
}

@MainActor @Test func nodesCleanUp() {
    let m = NSMenu(); m.autoenablesItems = false
    m.addItem(.separator()); m.addItem(withTitle: "Open", action: nil, keyEquivalent: "o")
    m.addItem(.separator()); m.addItem(.separator())
    let hidden = m.addItem(withTitle: "Hidden", action: nil, keyEquivalent: ""); hidden.isHidden = true
    let save = m.addItem(withTitle: "Save", action: nil, keyEquivalent: ""); save.isEnabled = false
    let alt = m.addItem(withTitle: "Alt", action: nil, keyEquivalent: ""); alt.isAlternate = true
    m.addItem(.separator())
    let n = W7MenuNodes(m)
    #expect(n.map { $0.isSeparator ? "—" : $0.title } == ["Open", "—", "Save"])
    #expect(n[0].shortcut == "Cmd+O" && n[2].enabled == false && n[2].sourceIndex == 5)
}

@MainActor @Test func nodesCarryStateSubmenuAndImage() {
    let m = NSMenu(); m.autoenablesItems = false
    let checked = m.addItem(withTitle: "Ruler", action: nil, keyEquivalent: ""); checked.state = .on
    let parent = m.addItem(withTitle: "Recent", action: nil, keyEquivalent: ""); parent.submenu = NSMenu()
    let pic = m.addItem(withTitle: "Pic", action: nil, keyEquivalent: ""); pic.image = NSImage(size: NSSize(width: 16, height: 16))
    let n = W7MenuNodes(m)
    #expect(n[0].state == .on && !n[0].hasSubmenu && n[0].shortcut == nil)
    #expect(n[1].hasSubmenu && n[1].state == .off)
    #expect(n[2].image != nil && n[0].image == nil)
    #expect(n.map(\.sourceIndex) == [0, 1, 2])
}

@MainActor private final class RecentDelegate: NSObject, NSMenuDelegate {
    var calls = 0
    func menuNeedsUpdate(_ menu: NSMenu) {
        calls += 1
        menu.removeAllItems()
        menu.addItem(withTitle: "Recent 1", action: nil, keyEquivalent: "")
    }
}

@MainActor @Test func delegatePopulatesDynamicMenu() {
    let m = NSMenu()
    let d = RecentDelegate()
    m.delegate = d
    let n = W7MenuNodes(m)
    #expect(d.calls == 1)
    #expect(n.map(\.title) == ["Recent 1"])
    withExtendedLifetime(d) {}
}

@MainActor private final class BareDelegate: NSObject, NSMenuDelegate {}

@MainActor @Test func delegateWithoutMenuNeedsUpdateIsTolerated() {
    let m = NSMenu(); m.addItem(withTitle: "A", action: nil, keyEquivalent: "")
    let d = BareDelegate()
    m.delegate = d
    #expect(W7MenuNodes(m).map(\.title) == ["A"])
    withExtendedLifetime(d) {}
}

private func node(_ title: String, enabled: Bool = true, separator: Bool = false) -> W7MenuNode {
    W7MenuNode(title: title, enabled: enabled, isSeparator: separator, state: .off, shortcut: nil,
               hasSubmenu: false, image: nil, sourceIndex: 0)
}

@Test func navigation() {
    let nodes = [node("A"), node("", separator: true), node("B", enabled: false), node("C")]
    #expect(W7NextSelectableIndex(nodes, 0, 1) == 3)
    #expect(W7NextSelectableIndex(nodes, 3, 1) == 0)
    #expect(W7NextSelectableIndex(nodes, NSNotFound, 1) == 0)
    #expect(W7NextSelectableIndex(nodes, NSNotFound, -1) == 3)
    #expect(W7NextSelectableIndex(nodes, 3, -1) == 0)
    #expect(W7NextSelectableIndex(nodes, 0, -1) == 3)
    let allDisabled = [node("A", enabled: false), node("", separator: true), node("B", enabled: false)]
    #expect(W7NextSelectableIndex(allDisabled, NSNotFound, 1) == NSNotFound)
    #expect(W7NextSelectableIndex(allDisabled, 0, -1) == NSNotFound)
    #expect(W7NextSelectableIndex([], NSNotFound, 1) == NSNotFound)
    // A single selectable item wraps onto itself.
    #expect(W7NextSelectableIndex([node("A"), node("B", enabled: false)], 0, 1) == 0)
}

// MARK: - Layout helpers used by W7MenuWindow

@Test func menuWidth() {
    // gutter 28 + title 100 + 40 + shortcut 50 + 24 = 242
    #expect(W7MenuLayoutWidth(100, 50, 0) == 242)
    // Never below the 160 pt minimum, nor below the caller's minimum.
    #expect(W7MenuLayoutWidth(20, 0, 0) == 160)
    #expect(W7MenuLayoutWidth(100, 50, 300) == 300)
}

@Test func rowsAndHitTesting() {
    let nodes = [node("A"), node("", separator: true), node("B")]
    #expect(W7MenuRowsHeight(nodes) == CGFloat(22 + 7 + 22))
    #expect(W7MenuRowTop(nodes, 0) == 0)
    #expect(W7MenuRowTop(nodes, 2) == 29)
    #expect(W7MenuRowAtOffset(nodes, 0) == 0)
    #expect(W7MenuRowAtOffset(nodes, 21.9) == 0)
    #expect(W7MenuRowAtOffset(nodes, 22) == 1)
    #expect(W7MenuRowAtOffset(nodes, 29) == 2)
    #expect(W7MenuRowAtOffset(nodes, 50.9) == 2)
    #expect(W7MenuRowAtOffset(nodes, 51) == NSNotFound)
    #expect(W7MenuRowAtOffset(nodes, -1) == NSNotFound)
}

@Test func popUpFramePlacement() {
    let screen = CGRect(x: 0, y: 0, width: 1000, height: 800)
    let size = CGSize(width: 200, height: 300)
    // Fits: top-left corner sits at the point.
    #expect(W7MenuPopUpFrame(CGPoint(x: 100, y: 700), size, screen) == CGRect(x: 100, y: 400, width: 200, height: 300))
    // Too low: flips up so the bottom-left corner sits at the point (Windows context menus).
    #expect(W7MenuPopUpFrame(CGPoint(x: 100, y: 100), size, screen) == CGRect(x: 100, y: 100, width: 200, height: 300))
    // Too far right: shifts left to stay on screen.
    #expect(W7MenuPopUpFrame(CGPoint(x: 900, y: 700), size, screen) == CGRect(x: 800, y: 400, width: 200, height: 300))
    // Fits neither way vertically: clamped to the top of the screen.
    #expect(W7MenuPopUpFrame(CGPoint(x: 0, y: 200), CGSize(width: 200, height: 700), screen) == CGRect(x: 0, y: 100, width: 200, height: 700))
    // Secondary display left of the primary (negative coordinates).
    let left = CGRect(x: -1280, y: 0, width: 1280, height: 1024)
    #expect(W7MenuPopUpFrame(CGPoint(x: -100, y: 900), size, left) == CGRect(x: -200, y: 600, width: 200, height: 300))
}

@Test func submenuFramePlacement() {
    let screen = CGRect(x: 0, y: 0, width: 1000, height: 800)
    let parent = CGRect(x: 100, y: 300, width: 200, height: 400)
    let size = CGSize(width: 180, height: 100)
    // Opens to the right, overlapping the parent by 2 pt; its top aligns with the row's top.
    #expect(W7MenuSubmenuFrame(parent, 650, size, screen) == CGRect(x: 298, y: 550, width: 180, height: 100))
    // No room on the right: flips to the left of the parent.
    let rightParent = CGRect(x: 750, y: 300, width: 200, height: 400)
    #expect(W7MenuSubmenuFrame(rightParent, 650, size, screen) == CGRect(x: 572, y: 550, width: 180, height: 100))
    // Too low: shifted up onto the screen.
    #expect(W7MenuSubmenuFrame(parent, 50, size, screen) == CGRect(x: 298, y: 0, width: 180, height: 100))
}

// MARK: - Tracking loop driven by scripted events

@MainActor private final class ActionLog: NSObject {
    var fired: [String] = []
    var menuWindowVisibleDuringAction = false
    @objc func run(_ sender: NSMenuItem) {
        fired.append(sender.title)
        menuWindowVisibleDuringAction = NSApp.windows.contains { $0 is W7MenuWindow && $0.isVisible }
    }
}

/// Rebuilds or empties its menu when the menu closes, as dynamic and status menus do.
@MainActor private final class ClosingDelegate: NSObject, NSMenuDelegate {
    var removeAll: Bool
    var didClose = 0
    init(removeAll: Bool) { self.removeAll = removeAll }
    func menuDidClose(_ menu: NSMenu) {
        didClose += 1
        if removeAll { menu.removeAllItems() } else { menu.removeItem(at: 0) }
    }
}

@MainActor private enum Key {
    static var down: NSEvent { ScriptedMenuInput.key(String(UnicodeScalar(UInt16(NSDownArrowFunctionKey))!), 125) }
    static var enter: NSEvent { ScriptedMenuInput.key("\r", 36) }
    static var esc: NSEvent { ScriptedMenuInput.key("\u{1b}", 53) }
    static var left: NSEvent { ScriptedMenuInput.key(String(UnicodeScalar(UInt16(NSLeftArrowFunctionKey))!), 123) }
}

@MainActor private func menu(_ titles: [String], target: ActionLog) -> NSMenu {
    let m = NSMenu(); m.autoenablesItems = false
    for t in titles {
        let item = m.addItem(withTitle: t, action: #selector(ActionLog.run(_:)), keyEquivalent: "")
        item.target = target
    }
    return m
}

@MainActor private func liveMenuWindows() -> [NSWindow] { NSApp.windows.filter { $0 is W7MenuWindow } }

/// Every test that calls popUp lives here, serialized: popUp refuses to nest and the scripted input is global.
/// Input comes from ScriptedMenuInput, never from NSApp.postEvent or the window server (see there for why).
@MainActor @Suite(.serialized) struct MenuTrackingTests {
    init() { _ = NSApplication.shared }

    @Test func popUpReturnsImmediatelyForEmptyMenu() {
        let m = NSMenu()
        let hidden = m.addItem(withTitle: "Hidden", action: nil, keyEquivalent: ""); hidden.isHidden = true
        m.addItem(.separator())
        W7MenuWindow.popUp(m, topLeft: NSPoint(x: 100, y: 100), minWidth: 0)
        #expect(liveMenuWindows().isEmpty)
    }

    @Test func downDownReturnRunsSecondItemAfterMenuIsGone() {
        let log = ActionLog()
        let m = menu(["First", "Second", "Third"], target: log)
        ScriptedMenuInput.run([Key.down, Key.down, Key.enter]) { W7MenuWindow.popUp(m, topLeft: NSPoint(x: 200, y: 600), minWidth: 0) }
        #expect(log.fired == ["Second"])
        #expect(log.menuWindowVisibleDuringAction == false)
    }

    @Test func mouseEnteringSwitchRegionReturnsItsIndexWithoutAction() {
        let log = ActionLog()
        let m = menu(["First", "Second"], target: log)
        // Far from the menu at (200, 600); AppKit coordinates.
        let target = NSPoint(x: 900, y: 300)
        let regions = [NSValue(rect: NSRect(x: 0, y: 0, width: 10, height: 10)),
                       NSValue(rect: NSRect(x: target.x - 20, y: target.y - 20, width: 40, height: 40))]
        var r = NSNotFound
        autoreleasepool {
            r = ScriptedMenuInput.run([ScriptedMenuInput.mouseMoved(to: target)]) {
                W7MenuWindow.popUp(m, topLeft: NSPoint(x: 200, y: 600), minWidth: 0, switchRegions: regions)
            }
        }
        #expect(r == 1)
        #expect(log.fired.isEmpty)
        #expect(liveMenuWindows().isEmpty)
    }

    @Test func escapeWithNilRegionsReturnsNotFound() {
        let log = ActionLog()
        let m = menu(["First", "Second"], target: log)
        let r = ScriptedMenuInput.run([Key.esc]) {
            W7MenuWindow.popUp(m, topLeft: NSPoint(x: 200, y: 600), minWidth: 0, switchRegions: nil)
        }
        #expect(r == NSNotFound)
        #expect(log.fired.isEmpty)
    }

    @Test func commitWithRegionsReturnsNotFoundAndRunsItemOnce() {
        let log = ActionLog()
        let m = menu(["First", "Second"], target: log)
        let regions = [NSValue(rect: NSRect(x: 900, y: 300, width: 40, height: 40))]
        let r = ScriptedMenuInput.run([Key.down, Key.enter]) {
            W7MenuWindow.popUp(m, topLeft: NSPoint(x: 200, y: 600), minWidth: 0, switchRegions: regions)
        }
        #expect(r == NSNotFound)
        #expect(log.fired == ["First"])
    }

    @Test func showMenuReportsWhetherAnythingAppeared() {
        let log = ActionLog()
        #expect(!W7MenuWindow.show(NSMenu(), topLeft: NSPoint(x: 100, y: 100), minWidth: 0))
        let m = menu(["First"], target: log)
        #expect(ScriptedMenuInput.run([Key.esc]) { W7MenuWindow.show(m, topLeft: NSPoint(x: 200, y: 600), minWidth: 0) })
    }

    /// Left closes a menu marked W7MenuSetLeftClosesRoot (the Start menu's jump list, as in Windows 7); an unmarked
    /// root menu ignores Left and needs Esc.
    @Test func leftClosesAMarkedRootMenu() {
        let log = ActionLog()
        let marked = menu(["First", "Second"], target: log)
        #expect(!W7MenuLeftClosesRoot(marked))
        W7MenuSetLeftClosesRoot(marked, true)
        #expect(W7MenuLeftClosesRoot(marked))
        autoreleasepool {
            ScriptedMenuInput.run([Key.down, Key.left]) { W7MenuWindow.popUp(marked, topLeft: NSPoint(x: 200, y: 600), minWidth: 0) }
        }
        #expect(log.fired.isEmpty)
        #expect(liveMenuWindows().isEmpty)
        W7MenuSetLeftClosesRoot(marked, false)
        #expect(!W7MenuLeftClosesRoot(marked))
        let plain = menu(["First", "Second"], target: log)
        autoreleasepool {
            // Left is read and ignored; the loop then needs the Esc (ScriptedMenuInput checks both were read).
            ScriptedMenuInput.run([Key.left, Key.esc]) { W7MenuWindow.popUp(plain, topLeft: NSPoint(x: 200, y: 600), minWidth: 0) }
        }
        #expect(log.fired.isEmpty)
    }

    @Test func escapeDismissesWithoutAction() {
        let log = ActionLog()
        let m = menu(["First", "Second"], target: log)
        autoreleasepool {
            ScriptedMenuInput.run([Key.down, Key.esc]) { W7MenuWindow.popUp(m, topLeft: NSPoint(x: 200, y: 600), minWidth: 0) }
        }
        #expect(log.fired.isEmpty)
        #expect(liveMenuWindows().isEmpty)
    }

    @Test func actionSurvivesDelegateRebuildingMenuOnClose() {
        let log = ActionLog()
        let m = menu(["Open", "Delete", "Rename"], target: log)
        let d = ClosingDelegate(removeAll: false)   // removes "Open": every index shifts down by one
        m.delegate = d
        // Chooses "Delete".
        ScriptedMenuInput.run([Key.down, Key.down, Key.enter]) { W7MenuWindow.popUp(m, topLeft: NSPoint(x: 200, y: 600), minWidth: 0) }
        #expect(d.didClose == 1)
        #expect(log.fired == ["Delete"])
        withExtendedLifetime(d) {}
    }

    @Test func noOtherActionWhenDelegateEmptiesMenuOnClose() {
        let log = ActionLog()
        let m = menu(["Open", "Delete"], target: log)
        let d = ClosingDelegate(removeAll: true)
        m.delegate = d
        // Chooses "Open", which the delegate then removes.
        ScriptedMenuInput.run([Key.down, Key.enter]) { W7MenuWindow.popUp(m, topLeft: NSPoint(x: 200, y: 600), minWidth: 0) }
        #expect(d.didClose == 1)
        #expect(log.fired.isEmpty)
        withExtendedLifetime(d) {}
    }
}

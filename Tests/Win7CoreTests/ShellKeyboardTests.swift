import Foundation
import Testing
@testable import Win7Core

/// (review of F3–F5): keyboard access for the shell's drawn controls: the key mapping, Tab order,
/// arrows in lists and grids, and the Desktop Background window's own keys.
@Suite struct ShellKeyboardTests {
    @Test func keyCodesMapToKeys() {
        func key(_ code: UInt16, shift: Bool = false, option: Bool = false, command: Bool = false, control: Bool = false) -> ShellKey? {
            ShellKey(keyCode: code, shift: shift, option: option, command: command, control: control)
        }
        #expect(key(48) == .tab && key(48, shift: true) == .backTab)
        #expect(key(49) == .space && key(36) == .enter && key(76) == .enter && key(53) == .escape)
        #expect(key(123) == .left && key(124) == .right && key(125) == .down && key(126) == .up)
        #expect(key(125, option: true) == .openList && key(118) == .openList)   // Alt+↓ and F4 open a list
        #expect(key(0, command: true) == .selectAll)
        #expect(key(0) == nil && key(49, command: true) == nil && key(36, control: true) == nil)
        #expect(key(48, control: true) == nil)   // Ctrl+Tab is not focus movement here
    }

    @Test func keysActOnControls() {
        for kind in [ShellControlKind.pushButton, .checkBox, .link] {
            #expect(ShellKeyboard.action(.space, for: kind) == .activate)
            #expect(ShellKeyboard.action(.enter, for: kind) == .activate)
            #expect(ShellKeyboard.action(.down, for: kind) == nil)
            #expect(ShellKeyboard.action(.tab, for: kind) == nil)
        }
        // A drop-down list opens on Space, Return, Alt+↓ or F4; the arrows step its choice while it is closed.
        #expect(ShellKeyboard.action(.space, for: .popUp) == .open)
        #expect(ShellKeyboard.action(.enter, for: .popUp) == .open)
        #expect(ShellKeyboard.action(.openList, for: .popUp) == .open)
        #expect(ShellKeyboard.action(.up, for: .popUp) == .previous && ShellKeyboard.action(.left, for: .popUp) == .previous)
        #expect(ShellKeyboard.action(.down, for: .popUp) == .next && ShellKeyboard.action(.right, for: .popUp) == .next)
        #expect(ShellKeyboard.action(.escape, for: .popUp) == nil)
        #expect(ShellKeyboard.stepped(0, by: .previous, count: 3) == 0 && ShellKeyboard.stepped(0, by: .next, count: 3) == 1)
        #expect(ShellKeyboard.stepped(2, by: .next, count: 3) == 2 && ShellKeyboard.stepped(1, by: .open, count: 3) == 1)
    }

    @Test func tabCyclesOverFocusableStops() {
        let all = [true, true, false, true]
        #expect(ShellKeyboard.nextFocus(from: nil, canFocus: all, backward: false) == 0)
        #expect(ShellKeyboard.nextFocus(from: nil, canFocus: all, backward: true) == 3)
        #expect(ShellKeyboard.nextFocus(from: 1, canFocus: all, backward: false) == 3)   // the disabled stop is skipped
        #expect(ShellKeyboard.nextFocus(from: 3, canFocus: all, backward: false) == 0)   // wraps
        #expect(ShellKeyboard.nextFocus(from: 0, canFocus: all, backward: true) == 3)
        #expect(ShellKeyboard.nextFocus(from: 3, canFocus: all, backward: true) == 1)
        #expect(ShellKeyboard.nextFocus(from: 0, canFocus: [false, false], backward: false) == nil)
        #expect(ShellKeyboard.nextFocus(from: 0, canFocus: [true], backward: false) == 0)
        #expect(ShellKeyboard.nextFocus(from: 9, canFocus: all, backward: false) == 0)   // a stale index starts over
    }

    @Test func arrowsMoveInAList() {
        #expect(ShellKeyboard.moveInList(.down, from: nil, count: 4, vertical: true) == 0)
        #expect(ShellKeyboard.moveInList(.down, from: 1, count: 4, vertical: true) == 2)
        #expect(ShellKeyboard.moveInList(.down, from: 3, count: 4, vertical: true) == 3)   // no wrap
        #expect(ShellKeyboard.moveInList(.up, from: 0, count: 4, vertical: true) == 0)
        #expect(ShellKeyboard.moveInList(.right, from: 1, count: 4, vertical: true) == nil)  // not this list's axis
        #expect(ShellKeyboard.moveInList(.right, from: 1, count: 4, vertical: false) == 2)
        #expect(ShellKeyboard.moveInList(.left, from: 0, count: 4, vertical: false) == 0)
        #expect(ShellKeyboard.moveInList(.down, from: nil, count: 0, vertical: true) == nil)
    }

    /// Two groups: three cells in a row and one under it, then a group of two further down (rows of the grid,
    /// flipped coordinates: y grows downward).
    @Test func arrowsMoveInAGrid() {
        let centers = [CGPoint(x: 10, y: 10), CGPoint(x: 30, y: 10), CGPoint(x: 50, y: 10),
                       CGPoint(x: 10, y: 30),
                       CGPoint(x: 10, y: 70), CGPoint(x: 30, y: 70)]
        #expect(ShellKeyboard.moveInGrid(.right, from: nil, centers: centers) == 0)
        #expect(ShellKeyboard.moveInGrid(.right, from: 0, centers: centers) == 1)
        #expect(ShellKeyboard.moveInGrid(.right, from: 2, centers: centers) == 3)   // reading order, as Explorer
        #expect(ShellKeyboard.moveInGrid(.left, from: 0, centers: centers) == 0)
        #expect(ShellKeyboard.moveInGrid(.right, from: 5, centers: centers) == 5)
        #expect(ShellKeyboard.moveInGrid(.down, from: 1, centers: centers) == 3)   // the nearest cell in the next row
        #expect(ShellKeyboard.moveInGrid(.down, from: 3, centers: centers) == 4)   // into the next group
        #expect(ShellKeyboard.moveInGrid(.up, from: 5, centers: centers) == 3)
        #expect(ShellKeyboard.moveInGrid(.up, from: 2, centers: centers) == 2)     // top row stays
        #expect(ShellKeyboard.moveInGrid(.down, from: 5, centers: centers) == 5)
        #expect(ShellKeyboard.moveInGrid(.space, from: 1, centers: centers) == nil)
        #expect(ShellKeyboard.moveInGrid(.down, from: nil, centers: []) == nil)
    }

    @Test func focusOrders() {
        #expect(DesktopBackgroundModel.focusOrder == [.location, .browse, .selectAll, .clearAll, .pictures, .position,
                                                      .interval, .shuffle, .save, .cancel, .search])
        #expect(PersonalizationModel.focusOrder == [.tasks, .themes, .bottomRow, .search])
    }

    /// F3: the window's own Return, Esc and Cmd+A wait while the search box is being typed in; Return on a focused
    /// button or link is that control's; Tab always moves the focus.
    @Test func desktopBackgroundWindowKeys() {
        typealias M = DesktopBackgroundModel
        #expect(M.windowAction(.enter, editingText: false, controlHasFocus: false) == .save)
        #expect(M.windowAction(.enter, editingText: true, controlHasFocus: false) == nil)
        #expect(M.windowAction(.enter, editingText: false, controlHasFocus: true) == nil)
        #expect(M.windowAction(.escape, editingText: false, controlHasFocus: true) == .cancel)
        #expect(M.windowAction(.escape, editingText: true, controlHasFocus: false) == nil)
        #expect(M.windowAction(.selectAll, editingText: false, controlHasFocus: false) == .selectAllPictures)
        #expect(M.windowAction(.selectAll, editingText: true, controlHasFocus: false) == nil)
        #expect(M.windowAction(.tab, editingText: true, controlHasFocus: false) == .focusNext)
        #expect(M.windowAction(.backTab, editingText: false, controlHasFocus: true) == .focusPrevious)
        #expect(M.windowAction(.space, editingText: false, controlHasFocus: true) == nil)
    }
}

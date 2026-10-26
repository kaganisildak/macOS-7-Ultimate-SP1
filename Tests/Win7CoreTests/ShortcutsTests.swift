import Carbon.HIToolbox
import Testing
@testable import Win7Core

private func combo(_ key: Int, _ mods: ShortcutModifiers) -> KeyCombo { KeyCombo(keyCode: UInt32(key), modifiers: mods) }

@Test func winModifierIsControlOption() {
    #expect(ShortcutModifiers.win == [.control, .option])
    #expect(ShortcutModifiers.win.carbonFlags == UInt32(controlKey | optionKey))
    #expect(ShortcutModifiers([.win, .shift]).carbonFlags == UInt32(controlKey | optionKey | shiftKey))
    #expect(ShortcutModifiers.command.carbonFlags == UInt32(cmdKey))
    #expect(ShortcutModifiers.control.carbonFlags == UInt32(controlKey))
}

@Test func eachBindingMapsToItsAction() {
    let win = ShortcutModifiers.win
    let winShift: ShortcutModifiers = [.win, .shift]
    let expected: [(KeyCombo, ShortcutAction)] = [
        (combo(kVK_ANSI_D, win), .showDesktop),
        (combo(kVK_ANSI_M, win), .minimizeAll),
        (combo(kVK_ANSI_M, winShift), .restoreMinimized),
        (combo(kVK_ANSI_E, win), .openComputer),
        (combo(kVK_ANSI_L, win), .lock),
        (combo(kVK_ANSI_R, win), .run),
        (combo(kVK_Home, win), .minimizeOthers),
        (combo(kVK_Space, win), .peekDesktop),
        (combo(kVK_ANSI_T, win), .focusTaskbar),
        (combo(kVK_UpArrow, winShift), .verticalMaximize),
        (combo(kVK_LeftArrow, winShift), .previousScreen),
        (combo(kVK_RightArrow, winShift), .nextScreen),
        (combo(kVK_ANSI_1, win), .taskbarButton(0)),
        (combo(kVK_ANSI_2, win), .taskbarButton(1)),
        (combo(kVK_ANSI_3, win), .taskbarButton(2)),
        (combo(kVK_ANSI_4, win), .taskbarButton(3)),
        (combo(kVK_ANSI_5, win), .taskbarButton(4)),
        (combo(kVK_ANSI_6, win), .taskbarButton(5)),
        (combo(kVK_ANSI_7, win), .taskbarButton(6)),
        (combo(kVK_ANSI_8, win), .taskbarButton(7)),
        (combo(kVK_ANSI_9, win), .taskbarButton(8)),
    ]
    for (c, action) in expected { #expect(Shortcuts.action(for: c) == action) }
    #expect(Shortcuts.all.count == expected.count)
}

@Test func noDuplicateCombosOrActions() {
    let combos = Shortcuts.all.map(\.combo)
    #expect(Set(combos).count == combos.count)
    let actions = Shortcuts.all.map(\.action)
    #expect(Set(actions).count == actions.count)
}

@Test func noCollisionWithExistingShortcuts() {
    let snap = [kVK_LeftArrow, kVK_RightArrow, kVK_UpArrow, kVK_DownArrow].map { combo($0, .win) }
    let start = combo(kVK_Escape, .control)
    let switcher = [combo(kVK_Tab, .option), combo(kVK_Tab, [.option, .shift])]
    let existing = snap + [start] + switcher
    #expect(Set(Shortcuts.reserved) == Set(existing))
    for c in existing { #expect(Shortcuts.action(for: c) == nil) }
    #expect(Shortcuts.escape == combo(kVK_Escape, []))
}

@Test func accessibilityNeedAndHold() {
    let needAX: Set<ShortcutAction> = [.minimizeOthers, .verticalMaximize, .previousScreen, .nextScreen]
    for s in Shortcuts.all { #expect(s.action.needsAccessibility == needAX.contains(s.action)) }
    #expect(Shortcuts.all.filter(\.action.isHeld).map(\.action) == [.peekDesktop])
}

@Test func displayNames() {
    #expect(Shortcuts.all.first { $0.action == .minimizeAll }?.name == "Win+M")
    #expect(Shortcuts.all.first { $0.action == .restoreMinimized }?.name == "Win+Shift+M")
    #expect(Shortcuts.all.first { $0.action == .taskbarButton(2) }?.name == "Win+3")
    #expect(Shortcuts.all.first { $0.action == .nextScreen }?.name == "Win+Shift+Right")
    #expect(Shortcuts.all.first { $0.action == .peekDesktop }?.name == "Win+Space")
}

@Test func winKeysReleased() {
    // Win+L locks only once Control and Option are up, so the synthetic Ctrl+Cmd+Q carries no Option.
    #expect(ShortcutModifiers.win.isReleased(in: []))
    #expect(ShortcutModifiers.win.isReleased(in: [.maskShift, .maskCommand, .maskAlphaShift]))
    #expect(!ShortcutModifiers.win.isReleased(in: [.maskControl, .maskAlternate]))
    #expect(!ShortcutModifiers.win.isReleased(in: [.maskAlternate]))
    #expect(!ShortcutModifiers.win.isReleased(in: [.maskControl, .maskNumericPad]))
    #expect(!ShortcutModifiers.command.isReleased(in: [.maskCommand]))
    #expect(!ShortcutModifiers.shift.isReleased(in: [.maskShift]))
}

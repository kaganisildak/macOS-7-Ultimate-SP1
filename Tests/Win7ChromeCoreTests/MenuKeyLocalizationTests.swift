import AppKit
import Carbon
import Testing
import Win7ChromeCore

// Finder's menu key equivalents follow the keyboard layout (automatic key-equivalent localization):
// on Turkish Q, Back is Cmd+Ğ and Forward Cmd+Ü instead of Cmd+[ and Cmd+]. The lookup also accepts
// the character the US key's physical position types in the current layout, then the action name.

/// The Unicode key layout data of an installed layout (nil when it isn't installed: those tests skip).
@MainActor private func layoutData(_ id: String) -> Data? {
    let filter = [kTISPropertyInputSourceID as String: id] as CFDictionary
    guard let list = TISCreateInputSourceList(filter, true)?.takeRetainedValue() as? [TISInputSource],
          let source = list.first,
          let raw = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData) else { return nil }
    return Unmanaged<CFData>.fromOpaque(raw).takeUnretainedValue() as Data
}

private let usKeys = Array("abcdefghijklmnopqrstuvwxyz0123456789[];',./\\`-=").map(String.init)

@Test func usKeyCodeTable() {
    #expect(W7USVirtualKeyCode("[") == Int(kVK_ANSI_LeftBracket))
    #expect(W7USVirtualKeyCode("]") == Int(kVK_ANSI_RightBracket))
    #expect(W7USVirtualKeyCode("a") == Int(kVK_ANSI_A))
    #expect(W7USVirtualKeyCode("N") == Int(kVK_ANSI_N))   // case-insensitive
    #expect(W7USVirtualKeyCode("0") == Int(kVK_ANSI_0))
    #expect(W7USVirtualKeyCode("/") == Int(kVK_ANSI_Slash))
    #expect(W7USVirtualKeyCode("\u{F700}") == -1)         // an arrow key has no character position
    #expect(W7USVirtualKeyCode("") == -1)
    #expect(W7USVirtualKeyCode("ab") == -1)
    // Every table entry is distinct.
    let codes = usKeys.map { W7USVirtualKeyCode($0) }
    #expect(!codes.contains(-1))
    #expect(Set(codes).count == usKeys.count)
}

@MainActor @Test func usLayoutTranslatesBackToTheSameCharacters() throws {
    guard let us = layoutData("com.apple.keylayout.US") else { return }
    for key in usKeys {
        #expect(W7TranslateVirtualKey(us, W7USVirtualKeyCode(key), false) == key, "\(key)")
    }
    #expect(W7TranslateVirtualKey(us, Int(kVK_ANSI_A), true) == "A")
    #expect(W7TranslateVirtualKey(us, Int(kVK_ANSI_LeftBracket), true) == "{")
    #expect(W7TranslateVirtualKey(us, -1, false) == nil)
    #expect(W7TranslateVirtualKey(Data([1, 2, 3]), Int(kVK_ANSI_A), false) == nil)   // garbage layout data
}

@MainActor @Test func turkishQTranslatesBracketsToGBreveAndUDiaeresis() throws {
    guard let tr = layoutData("com.apple.keylayout.Turkish-QWERTY-PC") else { return }
    #expect(W7TranslateVirtualKey(tr, Int(kVK_ANSI_LeftBracket), false) == "ğ")
    #expect(W7TranslateVirtualKey(tr, Int(kVK_ANSI_RightBracket), false) == "ü")
}

@MainActor private func goMenu(back: String, forward: String, actions: Bool = true) -> (NSMenu, NSMenuItem, NSMenuItem, NSMenuItem) {
    let root = NSMenu(title: "Main")
    let go = NSMenu(title: "Git")
    let b = NSMenuItem(title: "Geri", action: actions ? NSSelectorFromString("back:") : nil, keyEquivalent: back)
    let f = NSMenuItem(title: "İleri", action: actions ? NSSelectorFromString("forward:") : nil, keyEquivalent: forward)
    let docs = NSMenuItem(title: "Belgeler", action: nil, keyEquivalent: "o")
    docs.keyEquivalentModifierMask = [.command, .shift]
    go.addItem(b); go.addItem(f); go.addItem(docs)
    let top = NSMenuItem(title: "Git", action: nil, keyEquivalent: "")
    top.submenu = go
    root.addItem(top)
    return (root, b, f, docs)
}

@MainActor @Test func localizedKeyEquivalentsMatchUnderTheTurkishLayout() throws {
    guard let tr = layoutData("com.apple.keylayout.Turkish-QWERTY-PC") else { return }
    let (root, back, forward, docs) = goMenu(back: "ğ", forward: "ü")
    var how = W7MenuMatch.none
    #expect(W7FindMenuItemMatching(root, "[", .command, tr, nil, &how) === back)
    #expect(how == .localizedKey)
    #expect(W7FindMenuItemMatching(root, "]", .command, tr, nil, &how) === forward)
    #expect(how == .localizedKey)
    #expect(W7FindMenuItemMatching(root, "O", .command, tr, nil, &how) === docs)
    #expect(how == .keyEquivalent)
    // The modifiers still have to match.
    #expect(W7FindMenuItemMatching(root, "[", [.command, .shift], tr, nil, &how) == nil)
    #expect(how == .none)
}

@MainActor @Test func exactKeyEquivalentWinsOverALocalizedOne() throws {
    guard let tr = layoutData("com.apple.keylayout.Turkish-QWERTY-PC") else { return }
    // "ğ" is the localized form of "[", but an item that really has "[" comes first.
    let (root, localized, _, _) = goMenu(back: "ğ", forward: "ü")
    let exact = NSMenuItem(title: "Exact", action: nil, keyEquivalent: "[")
    root.addItem(exact)
    var how = W7MenuMatch.none
    #expect(W7FindMenuItemMatching(root, "[", .command, tr, nil, &how) === exact)
    #expect(how == .keyEquivalent)
    _ = localized
}

@MainActor @Test func userKeyEquivalentAndActionNameFallbacks() throws {
    let us = layoutData("com.apple.keylayout.US")
    // A key equivalent no layout explains: only the action name can find it.
    let (root, back, forward, _) = goMenu(back: "x", forward: "y")
    var how = W7MenuMatch.none
    #expect(W7FindMenuItemMatching(root, "[", .command, us, nil, &how) == nil)
    #expect(how == .none)
    #expect(W7FindMenuItemMatching(root, "[", .command, us, "back", &how) === back)
    #expect(how == .actionName)
    #expect(W7FindMenuItemMatching(root, "]", .command, nil, "FORWARD", &how) === forward)
    #expect(how == .actionName)
    // Without actions there is nothing to go on.
    let (bare, _, _, _) = goMenu(back: "x", forward: "y", actions: false)
    #expect(W7FindMenuItemMatching(bare, "[", .command, us, "back", &how) == nil)
}

@Test func actionHintsOnlyForBackAndForward() {
    #expect(W7MenuActionHint("[", .command) == "back")
    #expect(W7MenuActionHint("]", .command) == "forward")
    #expect(W7MenuActionHint("[", [.command, .shift]) == nil)
    #expect(W7MenuActionHint("n", .command) == nil)
}

@MainActor @Test func findMenuItemUsesTheCurrentLayout() {
    // Whatever the machine's layout, an exact key equivalent is still found by the public lookup.
    let (root, _, _, docs) = goMenu(back: "ğ", forward: "ü")
    #expect(W7FindMenuItem(root, "O", .command) === docs)
    #expect(W7CurrentKeyboardLayoutData() != nil)
}

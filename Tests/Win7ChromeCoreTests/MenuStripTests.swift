import AppKit
import Testing
import Win7ChromeCore

@objc(W7SwizzleProbe) final class W7SwizzleProbe: NSObject {
    @objc dynamic class func value() -> Int { 1 }
    @objc dynamic class func w7_value() -> Int { 2 }
}

@Test func menuStripEligibility() {
    #expect(W7ShouldShowMenuStrip([.titled, .resizable], false))
    #expect(!W7ShouldShowMenuStrip([.titled], false))
    #expect(!W7ShouldShowMenuStrip([.titled, .resizable], true))
}

@MainActor @Test func menuStripTitles() {
    let main = NSMenu()
    for t in ["Apple-ish app menu", "File", "Debug", "Edit"] {
        let item = NSMenuItem(title: t, action: nil, keyEquivalent: "")
        item.isHidden = (t == "Debug")
        main.addItem(item)
    }
    #expect(W7MenuStripTitles(main, "TextEdit") == ["TextEdit", "File", "Edit"])
}

@Test func swizzleClassMethod() {
    #expect(W7SwizzleClassMethod(W7SwizzleProbe.self, NSSelectorFromString("value"), NSSelectorFromString("w7_value")))
    #expect(W7SwizzleProbe.value() == 2)
    #expect(W7SwizzleProbe.w7_value() == 1)
    #expect(!W7SwizzleClassMethod(W7SwizzleProbe.self, NSSelectorFromString("nope"), NSSelectorFromString("w7_value")))
}

@MainActor @Test func menuStripKeepsItsHeight() {
    // AppKit resizes bottom titlebar accessories to its standard height unless told not to.
    _ = NSApplication.shared
    let saved = NSApp.mainMenu
    defer { NSApp.mainMenu = saved }
    let main = NSMenu()
    let file = NSMenuItem(title: "File", action: nil, keyEquivalent: "")
    file.submenu = NSMenu(title: "File")
    main.addItem(file)
    NSApp.mainMenu = main
    let w = NSWindow(contentRect: .init(x: 0, y: 0, width: 600, height: 400),
                     styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: true)
    w.isReleasedWhenClosed = false
    W7ChromeController.decorateWindow(w)
    let strips = w.titlebarAccessoryViewControllers.filter { $0 is W7MenuStripController }
    #expect(strips.count == 1)
    #expect(strips.first?.view.frame.height == W7MenuStripHeight)
}

/// Windows 7 puts the menu bar directly under the title bar, above any toolbar-like bar. An app's own
/// bottom accessory (TextEdit's format bar) must come after the strip, not before it.
@MainActor @Test func menuStripSitsAboveAppAccessories() {
    _ = NSApplication.shared
    let saved = NSApp.mainMenu
    defer { NSApp.mainMenu = saved }
    let main = NSMenu()
    let file = NSMenuItem(title: "File", action: nil, keyEquivalent: "")
    file.submenu = NSMenu(title: "File")
    main.addItem(file)
    NSApp.mainMenu = main
    let w = NSWindow(contentRect: .init(x: -9000, y: -9000, width: 600, height: 400),
                     styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
    w.isReleasedWhenClosed = false
    let appBar = NSTitlebarAccessoryViewController()
    appBar.layoutAttribute = .bottom
    appBar.automaticallyAdjustsSize = false
    appBar.view = NSView(frame: .init(x: 0, y: 0, width: 600, height: 30))
    w.addTitlebarAccessoryViewController(appBar)
    W7ChromeController.decorateWindow(w)
    let acc = w.titlebarAccessoryViewControllers
    #expect(acc.count == 2)
    #expect(acc.first is W7MenuStripController)
    w.layoutIfNeeded()
    if let strip = acc.first(where: { $0 is W7MenuStripController })?.view {
        let s = strip.convert(strip.bounds, to: nil), a = appBar.view.convert(appBar.view.bounds, to: nil)
        #expect(s.minY >= a.maxY, "strip \(s) app bar \(a)")
    }
}

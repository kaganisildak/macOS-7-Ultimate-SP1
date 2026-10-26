import AppKit
import Testing
import Win7ChromeCore

//: the whole path from the L0 gate through L1–L3 and hook d, on stand-ins registered
// under Safari's own class names (BrowserWindow, BrowserWindowController, ToolbarController), so the gate's
// exact class check and the hook installation find them. No window is ordered on screen.

@objc(BrowserWindow) final class FakeSafariBrowserWindow: NSWindow {}

@objc(BrowserWindowController) final class FakeSafariWindowController: NSWindowController {
    var privateWindow = false
    var standalone = true
    @objc class func browserWindowControllerForWindow(_ window: NSWindow?) -> AnyObject? { window?.windowController }
    @objc func isPrivate() -> Bool { privateWindow }
    @objc func browsingMode() -> UInt64 { privateWindow ? 1 : 0 }
    @objc func isPopupWindow() -> Bool { false }
    @objc func showsStandaloneUnifiedTabBar() -> Bool { standalone }
}

/// Safari prepares the control with SF Symbols; hook d replaces them with the orbs in a themed window.
@MainActor @objc(ToolbarController) final class FakeSafariToolbarController: NSObject {
    @objc func _prepareBackForwardSegmentedControl(_ control: NSSegmentedControl) {
        control.setImage(NSImage(systemSymbolName: "chevron.left", accessibilityDescription: nil), forSegment: 0)
        control.setImage(NSImage(systemSymbolName: "chevron.right", accessibilityDescription: nil), forSegment: 1)
    }
}

@MainActor private final class BackForwardToolbarDelegate: NSObject, NSToolbarDelegate {
    static let identifier = NSToolbarItem.Identifier("BackForwardToolbarIdentifier")
    let control: NSSegmentedControl
    init(_ control: NSSegmentedControl) { self.control = control }
    func toolbar(_ toolbar: NSToolbar, itemForItemIdentifier id: NSToolbarItem.Identifier,
                 willBeInsertedIntoToolbar flag: Bool) -> NSToolbarItem? {
        let item = NSToolbarItem(itemIdentifier: id)
        item.view = control
        return item
    }
    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] { [Self.identifier] }
    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] { [Self.identifier] }
}

@MainActor private final class SafariWindow {
    let window: FakeSafariBrowserWindow
    let controller: FakeSafariWindowController
    let control = NSSegmentedControl(frame: NSRect(x: 0, y: 0, width: 76, height: 28))
    let delegate: BackForwardToolbarDelegate

    init(private isPrivate: Bool) {
        window = FakeSafariBrowserWindow(contentRect: NSRect(x: 0, y: 0, width: 700, height: 500),
                                         styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        controller = FakeSafariWindowController(window: window)
        controller.privateWindow = isPrivate
        control.segmentCount = 2
        FakeSafariToolbarController()._prepareBackForwardSegmentedControl(control)
        delegate = BackForwardToolbarDelegate(control)
        let toolbar = NSToolbar(identifier: "BrowserStandaloneTabBarToolbarIdentifier-v4")
        toolbar.delegate = delegate
        window.toolbar = toolbar
        if toolbar.items.isEmpty { toolbar.insertItem(withItemIdentifier: BackForwardToolbarDelegate.identifier, at: 0) }
        W7ChromeController.decorateWindow(window)
    }

    var inset: CGFloat { window.contentView!.additionalSafeAreaInsets.bottom }
    var hasOverlay: Bool { control.subviews.contains { NSStringFromClass(type(of: $0)).contains("OrbOverlay") } }
}

@MainActor @Test func endToEndThemesAPlainWindowAndUnthemesItCleanly() {
    _ = NSApplication.shared
    W7SafariChromeStartForTesting(true)
    let s = SafariWindow(private: false)
    #expect(s.window.toolbar?.items.first?.view === s.control)
    let before = s.inset
    let safariBack = s.control.image(forSegment: 0)

    W7SafariUpdateWindow(s.window)
    #expect(W7SafariWindowIsThemed(s.window))
    #expect(W7TitlebarBandPainterForWindow(s.window) != nil)                 // L1
    #expect(W7SafariStatusBarForWindow(s.window) != nil && s.inset == before + 22)   // L3
    #expect(s.control.image(forSegment: 0) === W7SafariOrbImage(false))      // hook d installed: orb images…
    #expect(s.control.image(forSegment: 1) === W7SafariOrbImage(true))
    #expect(!s.hasOverlay)                                                  // …and no L2 overlay
    W7SafariUpdateWindow(s.window)                                         // idempotent
    #expect(s.inset == before + 22)

    // Switching to the Compact layout un-themes the window and puts everything back.
    s.controller.standalone = false
    W7SafariUpdateWindow(s.window)
    #expect(!W7SafariWindowIsThemed(s.window))
    #expect(W7TitlebarBandPainterForWindow(s.window) == nil)
    #expect(W7SafariStatusBarForWindow(s.window) == nil && s.inset == before)
    #expect(s.control.image(forSegment: 0) === safariBack)
    s.window.close()
}

@MainActor @Test func endToEndLeavesPrivateWindowsAlone() {
    _ = NSApplication.shared
    W7SafariChromeStartForTesting(true)
    let s = SafariWindow(private: true)
    let before = s.inset
    let safariBack = s.control.image(forSegment: 0)
    W7SafariUpdateWindow(s.window)
    #expect(!W7SafariWindowIsThemed(s.window))
    #expect(W7TitlebarBandPainterForWindow(s.window) == nil)
    #expect(W7SafariStatusBarForWindow(s.window) == nil && s.inset == before)
    #expect(s.control.image(forSegment: 0) === safariBack && !s.hasOverlay)
    // Safari re-preparing the control in a private window keeps its own images.
    let prepare = NSSelectorFromString("_prepareBackForwardSegmentedControl:")
    _ = FakeSafariToolbarController().perform(prepare, with: s.control)
    #expect(s.control.image(forSegment: 0) !== W7SafariOrbImage(false))
    s.window.close()
}

// the real AppKit toolbar (NSToolbarView → NSToolbarPlatterView → NSGlassEffectView) of the stand-in
// Safari window: the back/forward platter's glass is tinted as the IE7 capsule, keeps style .clear through AppKit's
// own platter layout, and gets AppKit's values back when the window is un-themed. Private windows: untouched.
@available(macOS 26.0, *)
@MainActor private func platterGlass(in window: NSWindow) -> NSGlassEffectView? {
    func find(_ v: NSView) -> NSGlassEffectView? {
        if let g = v as? NSGlassEffectView, let s = g.superview, NSStringFromClass(type(of: s)).contains("NSToolbarPlatterView") { return g }
        for sub in v.subviews { if let g = find(sub) { return g } }
        return nil
    }
    window.contentView?.superview?.layoutSubtreeIfNeeded()
    return window.contentView?.superview.flatMap(find)
}

@MainActor @Test func endToEndTintsTheRealToolbarGlass() {
    guard #available(macOS 26.0, *) else { return }
    _ = NSApplication.shared
    W7SafariChromeStartForTesting(true)
    W7SafariGlassStart(true)
    defer { W7SafariGlassSetEnabled(false) }
    let s = SafariWindow(private: false)
    s.window.appearance = NSAppearance(named: .aqua)
    guard let glass = platterGlass(in: s.window) else {
        Issue.record("no NSToolbarPlatterView glass in the stand-in window's toolbar")
        return
    }
    let style = glass.style, radius = glass.cornerRadius, tint = glass.tintColor
    W7SafariUpdateWindow(s.window)
    #expect(W7SafariWindowIsThemed(s.window))
    let capsule = W7SafariToolbarGlassTint(true)
    let rgb = glass.tintColor?.usingColorSpace(.sRGB)
    #expect(rgb.map { abs($0.redComponent * 255 - CGFloat(capsule.rgb >> 16)) < 1 && abs($0.alphaComponent - capsule.alpha) < 0.01 } == true)
    #expect(glass.style == .clear)
    // A gate re-run with nothing new (as on every frame of a window resize) does not walk the toolbar again.
    glass.tintColor = nil
    W7SafariUpdateWindow(s.window)
    #expect(glass.tintColor == nil)
    _ = W7SafariGlassStylePlatter(glass.superview!, nil)
    #expect(glass.tintColor != nil)
    // AppKit's own platter layout resets the style; the platter hook puts .clear back.
    glass.superview!.needsLayout = true
    glass.superview!.layoutSubtreeIfNeeded()
    #expect(glass.style == .clear && W7SafariGlassIsStyled(glass))

    s.controller.standalone = false   // Compact: un-themed, AppKit's glass back exactly
    W7SafariUpdateWindow(s.window)
    #expect(!W7SafariGlassIsStyled(glass) && glass.style == style && glass.cornerRadius == radius && glass.tintColor == tint)
    s.window.close()

    let p = SafariWindow(private: true)
    p.window.appearance = NSAppearance(named: .aqua)
    let privateGlass = platterGlass(in: p.window)
    let privateTint = privateGlass?.tintColor
    W7SafariUpdateWindow(p.window)
    #expect(privateGlass.map { !W7SafariGlassIsStyled($0) && $0.tintColor == privateTint } == true)
    p.window.close()
}

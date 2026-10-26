import AppKit
import ObjectiveC
import Testing
import Win7ChromeCore

// Internet Explorer 7-style Safari chrome. Pure models (gate, tab state, status text, band
// rows) and the private-API hooks on fake classes built at run time with Safari's exact type
// encodings and ivar types. No window is ordered on screen and no events are posted.

// MARK: - Fake classes

private func uniqueName(_ prefix: String) -> String {
    "\(prefix)_\(UUID().uuidString.replacingOccurrences(of: "-", with: ""))"
}

/// A class registered at run time: `ivars` as (name, type encoding), `methods` as (selector, types, block).
private func makeClass(_ prefix: String, superclass: AnyClass, ivars: [(String, String)] = [],
                       methods: [(String, String, Any)] = []) -> AnyClass {
    let cls: AnyClass = objc_allocateClassPair(superclass, uniqueName(prefix), 0)!
    for (name, type) in ivars {
        let ok = class_addIvar(cls, name, MemoryLayout<UnsafeRawPointer>.size, UInt8(log2(Double(MemoryLayout<UnsafeRawPointer>.size))), type)
        precondition(ok, "ivar \(name)")
    }
    for (sel, types, block) in methods {
        class_addMethod(cls, sel_registerName(sel), imp_implementationWithBlock(block), types)
    }
    objc_registerClassPair(cls)
    return cls
}

private func setIvar(_ object: AnyObject, _ name: String, _ value: AnyObject?) {
    let ivar = class_getInstanceVariable(object_getClass(object), name)!
    object_setIvar(object, ivar, value)
}

/// Retains ivar values the runtime-built classes hold unretained (object_setIvar on an ivar added at
/// run time is unsafe_unretained), for the duration of a test.
private final class Keeper { var objects: [AnyObject] = [] }

private func call(_ object: AnyObject, _ sel: String) {
    typealias F = @convention(c) (AnyObject, Selector) -> Void
    let s = sel_registerName(sel)
    unsafeBitCast(class_getMethodImplementation(object_getClass(object), s), to: F.self)(object, s)
}

private func callBool(_ object: AnyObject, _ sel: String) -> Bool {
    typealias F = @convention(c) (AnyObject, Selector) -> Bool
    let s = sel_registerName(sel)
    return unsafeBitCast(class_getMethodImplementation(object_getClass(object), s), to: F.self)(object, s)
}

private func callObject(_ object: AnyObject, _ sel: String, _ arg: AnyObject?) {
    typealias F = @convention(c) (AnyObject, Selector, AnyObject?) -> Void
    let s = sel_registerName(sel)
    unsafeBitCast(class_getMethodImplementation(object_getClass(object), s), to: F.self)(object, s, arg)
}

@MainActor private func makeWindow() -> NSWindow {
    _ = NSApplication.shared
    let w = NSWindow(contentRect: .init(x: 0, y: 0, width: 600, height: 400),
                     styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: true)
    w.isReleasedWhenClosed = false
    return w
}

private func cgHex(_ c: CGColor?) -> UInt32? {
    guard let c, let s = c.converted(to: CGColorSpace(name: CGColorSpace.sRGB)!, intent: .defaultIntent, options: nil),
          let comps = s.components, comps.count >= 3 else { return nil }
    return UInt32((comps[0] * 255).rounded()) << 16 | UInt32((comps[1] * 255).rounded()) << 8 | UInt32((comps[2] * 255).rounded())
}

// MARK: - L0 gate

private func themeable() -> W7SafariGateInputs {
    var g = W7SafariGateInputs()
    g.isBrowserWindowClass = true
    g.decorated = true
    g.controllerFound = true
    g.isPrivateKnown = true
    g.isPrivate = false
    g.browsingModeKnown = true
    g.browsingMode = 0
    g.popupKnown = true
    g.isPopup = false
    g.fullScreen = false
    g.standaloneKnown = true
    g.showsStandaloneTabBar = true
    return g
}

@Test func gateThemesOnlyAPlainStandaloneBrowserWindow() {
    #expect(W7SafariShouldTheme(themeable()))
    var g = themeable(); g.disabled = true; #expect(!W7SafariShouldTheme(g))
    g = themeable(); g.isBrowserWindowClass = false; #expect(!W7SafariShouldTheme(g))
    g = themeable(); g.decorated = false; #expect(!W7SafariShouldTheme(g))
    g = themeable(); g.controllerFound = false; #expect(!W7SafariShouldTheme(g))
    g = themeable(); g.fullScreen = true; #expect(!W7SafariShouldTheme(g))
    g = themeable(); g.isPopup = true; #expect(!W7SafariShouldTheme(g))
    g = themeable(); g.popupKnown = false; #expect(!W7SafariShouldTheme(g))   // fails closed
    g = themeable(); g.showsStandaloneTabBar = false; #expect(!W7SafariShouldTheme(g))   // Compact layout
}

@Test func gateNeverThemesPrivateWindows() {
    var g = themeable(); g.isPrivate = true; #expect(!W7SafariShouldTheme(g))
    g = themeable(); g.browsingMode = 1; #expect(!W7SafariShouldTheme(g))
    g = themeable(); g.browsingMode = 2; #expect(!W7SafariShouldTheme(g))   // any mode but the normal one
    // One readable source is enough when it says normal; none readable fails closed.
    g = themeable(); g.isPrivateKnown = false; #expect(W7SafariShouldTheme(g))
    g = themeable(); g.browsingModeKnown = false; #expect(W7SafariShouldTheme(g))
    g = themeable(); g.isPrivateKnown = false; g.browsingModeKnown = false; #expect(!W7SafariShouldTheme(g))
    // An unreadable source is ignored even if its stale value says private… but a readable one never is.
    g = themeable(); g.isPrivateKnown = false; g.isPrivate = true; #expect(W7SafariShouldTheme(g))
}

@Test func gateFallsBackToTheToolbarIdentifierForTheLayout() {
    var g = themeable(); g.standaloneKnown = false; g.showsStandaloneTabBar = false
    #expect(!W7SafariShouldTheme(g))
    g.toolbarIdentifierStandalone = true
    #expect(W7SafariShouldTheme(g))
    // A readable answer wins over the identifier.
    g = themeable(); g.showsStandaloneTabBar = false; g.toolbarIdentifierStandalone = true
    #expect(!W7SafariShouldTheme(g))
}

@Test func toolbarIdentifierMatch() {
    #expect(W7SafariToolbarIdentifierIsStandalone("BrowserStandaloneTabBarToolbarIdentifier-v4"))
    #expect(!W7SafariToolbarIdentifierIsStandalone("BrowserToolbarIdentifier-v4"))
    #expect(!W7SafariToolbarIdentifierIsStandalone(nil))
}

@Test func startsOnlyInSafariWithoutKillSwitch() {
    #expect(W7SafariChromeShouldStart("com.apple.Safari", false))
    #expect(!W7SafariChromeShouldStart("com.apple.Safari", true))
    #expect(!W7SafariChromeShouldStart("com.apple.SafariTechnologyPreview", false))
    #expect(!W7SafariChromeShouldStart("com.apple.finder", false))
    #expect(!W7SafariChromeShouldStart(nil, false))
}

@Test func excludedClassNames() {
    for name in ["UnifiedField", "UnifiedFieldButtonHostViewController", "InteriorUnifiedField",
                 "_UnifiedFieldImageOffsetCell", "PopupWindowUnifiedFieldViewController", "CompletionListWindow",
                 "AutoFillCompletionWindow", "AuthenticationPanel", "ToolbarDownloadsButtonView",
                 "PrivacyReportToolbarButton", "LockdownModeBarView", "WebExtensionToolbarItem"] {
        #expect(W7SafariIsExcludedClassName(name), "\(name)")
    }
    for name in ["UnifiedTabBar", "UnifiedTabBarButton", "NSToolbarView", "BrowserToolbarItem", "NSSegmentedControl"] {
        #expect(!W7SafariIsExcludedClassName(name), "\(name)")
    }
    #expect(W7SafariIsExcludedClassName(nil))
}

// MARK: - Tab state, status text, band rows

@Test func tabStateTable() {
    #expect(W7SafariTabState(false, false, false, false, 0) == .normal)
    #expect(W7SafariTabState(true, false, false, false, 0) == .selected)
    #expect(W7SafariTabState(true, true, true, true, 0) == .selected)
    #expect(W7SafariTabState(false, false, true, false, 0) == .hover)
    #expect(W7SafariTabState(false, true, false, false, 0) == .hover)    // multi-selected
    #expect(W7SafariTabState(false, false, false, true, 0) == .normal)   // pinned: same colours, narrower
    #expect(W7SafariTabState(false, false, false, false, 3) == .normal)
}

@Test func statusTextModel() {
    #expect(W7SafariStatusText(nil, nil, false) == "Done")
    #expect(W7SafariStatusText("", "", false) == "Done")
    #expect(W7SafariStatusText(nil, nil, true) == "")
    #expect(W7SafariStatusText("Go to “example.com”", "https://example.com/", false) == "Go to “example.com”")
    #expect(W7SafariStatusText(nil, "https://example.com/a", true) == "https://example.com/a")
    #expect(W7SafariLoadingStatusIsLoading(0) == false)
    #expect(W7SafariLoadingStatusIsLoading(2))
    #expect(W7SafariProgressFraction(0.4, true) == 0.4)
    #expect(W7SafariProgressFraction(3, true) == 1)
    #expect(W7SafariProgressFraction(-1, true) == 0)
    #expect(W7SafariProgressFraction(Double.nan, true) == 0)
    #expect(W7SafariProgressFraction(0.4, false) < 0)   // hidden when not loading
}

@Test func bandRowsFromToolbarAndTabBar() {
    let bounds = CGRect(x: 0, y: 0, width: 800, height: 140)
    let toolbar = CGRect(x: 0, y: 82, width: 800, height: 28)       // under the 30 pt caption row
    let tabBar = CGRect(x: 0, y: 0, width: 800, height: 30)
    var l = W7SafariBandLayoutFor(bounds, toolbar, tabBar, 2)
    #expect(l.tabRow == CGRect(x: 2, y: 0, width: 796, height: 30))
    #expect(l.favoritesRow == CGRect(x: 2, y: 30, width: 796, height: 52))   // favourites bar + menu strip
    // No tab bar: one row under the toolbar.
    l = W7SafariBandLayoutFor(bounds, toolbar, .zero, 2)
    #expect(l.tabRow == .zero)
    #expect(l.favoritesRow == CGRect(x: 2, y: 0, width: 796, height: 82))
    // Tab bar directly under the toolbar: no favourites row.
    l = W7SafariBandLayoutFor(bounds, toolbar, CGRect(x: 0, y: 52, width: 800, height: 30), 2)
    #expect(l.tabRow.height == 30 && l.favoritesRow == .zero)
    // No toolbar, or a tab bar above it (not Safari's Separate layout): nothing.
    l = W7SafariBandLayoutFor(bounds, .zero, tabBar, 2)
    #expect(l.tabRow == .zero && l.favoritesRow == .zero)
    l = W7SafariBandLayoutFor(bounds, toolbar, CGRect(x: 0, y: 110, width: 800, height: 30), 2)
    #expect(l.tabRow == .zero && l.favoritesRow == .zero)
}

// MARK: - Title bar band painter hook point

@MainActor private final class CountingPainter: NSObject, W7TitlebarBandPainter {
    var calls = 0
    func w7DrawBands(inTitlebarView view: NSView, window: NSWindow, context ctx: CGContext) {
        calls += 1
        ctx.setFillColor(CGColor(srgbRed: 1, green: 0, blue: 0, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: view.bounds.width, height: 4))
    }
}

@MainActor @Test func titlebarAsksTheWindowsBandPainter() {
    let w = makeWindow()
    W7ChromeController.decorateWindow(w)
    let bar = w.standardWindowButton(.closeButton)!.superview!.subviews.compactMap { $0 as? W7TitlebarView }.first!
    let painter = CountingPainter()
    #expect(W7TitlebarBandPainterForWindow(w) == nil)
    W7SetTitlebarBandPainter(w, painter)
    #expect(W7TitlebarBandPainterForWindow(w) === painter)
    let glass = bar.w7GlassView
    // Draw the glass view's drawRect directly (cacheDisplay would render its never-displayed layer).
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(glass.bounds.width), pixelsHigh: Int(glass.bounds.height),
                               bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                               colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    glass.draw(glass.bounds)
    NSGraphicsContext.restoreGraphicsState()
    #expect(painter.calls == 1)
    let bottom = rep.colorAt(x: rep.pixelsWide / 2, y: rep.pixelsHigh - 1)!.usingColorSpace(.sRGB)!
    #expect(bottom.redComponent > 0.9 && bottom.greenComponent < 0.1)
    W7TitlebarBandsNeedDisplay(w)
    #expect(glass.needsDisplay)
    W7SetTitlebarBandPainter(w, nil)
    #expect(W7TitlebarBandPainterForWindow(w) == nil)
}

/// Fills a 4 pt row at `y` (from the bottom) with one colour and counts its calls.
@MainActor private final class RowPainter: NSObject, W7TitlebarBandPainter {
    var calls = 0
    let y: CGFloat, color: CGColor
    init(y: CGFloat, color: CGColor) { self.y = y; self.color = color }
    func w7DrawBands(inTitlebarView view: NSView, window: NSWindow, context ctx: CGContext) {
        calls += 1
        ctx.setFillColor(color)
        ctx.fill(CGRect(x: 0, y: y, width: view.bounds.width, height: 4))
    }
}

/// item 5: the toolbar band and (later) the Messenger band are two painters on one title bar; each is set,
/// drawn and removed by its identifier without touching the other, in the order they were added.
@MainActor @Test func titlebarBandPaintersStackByIdentifier() {
    let w = makeWindow()
    W7ChromeController.decorateWindow(w)
    let bar = w.standardWindowButton(.closeButton)!.superview!.subviews.compactMap { $0 as? W7TitlebarView }.first!
    let glass = bar.w7GlassView
    let red = RowPainter(y: 0, color: CGColor(srgbRed: 1, green: 0, blue: 0, alpha: 1))
    let green = RowPainter(y: 0, color: CGColor(srgbRed: 0, green: 1, blue: 0, alpha: 1))
    let blue = RowPainter(y: 8, color: CGColor(srgbRed: 0, green: 0, blue: 1, alpha: 1))
    func draw() -> NSBitmapImageRep {
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(glass.bounds.width), pixelsHigh: Int(glass.bounds.height),
                                   bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                   colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        glass.draw(glass.bounds)
        NSGraphicsContext.restoreGraphicsState()
        return rep
    }
    func pixel(_ rep: NSBitmapImageRep, _ yFromBottom: Int) -> NSColor {
        rep.colorAt(x: rep.pixelsWide / 2, y: rep.pixelsHigh - 1 - yFromBottom)!.usingColorSpace(.sRGB)!
    }

    W7SetTitlebarBandPainterForIdentifier(w, "test.red", red)
    W7SetTitlebarBandPainterForIdentifier(w, "test.blue", blue)
    #expect(W7TitlebarBandPainterIdentifiers(w) == ["test.red", "test.blue"])
    #expect(W7TitlebarBandPainterForIdentifier(w, "test.red") === red)
    #expect(W7TitlebarBandPainterForIdentifier(w, "test.blue") === blue)
    #expect(W7TitlebarBandPainterForWindow(w) == nil, "the legacy slot is its own identifier")
    var rep = draw()
    #expect(red.calls == 1 && blue.calls == 1, "both painters draw")
    #expect(pixel(rep, 1).redComponent > 0.9 && pixel(rep, 9).blueComponent > 0.9)

    // Replacing keeps the position; a later painter draws over an earlier one.
    W7SetTitlebarBandPainterForIdentifier(w, "test.red", green)
    #expect(W7TitlebarBandPainterIdentifiers(w) == ["test.red", "test.blue"])
    W7SetTitlebarBandPainterForIdentifier(w, "test.over", red)
    rep = draw()
    #expect(pixel(rep, 1).redComponent > 0.9 && pixel(rep, 1).greenComponent < 0.1, "added last, drawn last")

    // Removing one leaves the others drawing.
    red.calls = 0; blue.calls = 0; green.calls = 0
    W7SetTitlebarBandPainterForIdentifier(w, "test.over", nil)
    W7SetTitlebarBandPainterForIdentifier(w, "test.red", nil)
    #expect(W7TitlebarBandPainterIdentifiers(w) == ["test.blue"])
    rep = draw()
    #expect(red.calls == 0 && green.calls == 0 && blue.calls == 1)
    let low = pixel(rep, 1)
    #expect(pixel(rep, 9).blueComponent > 0.9 && !(low.redComponent > 0.9 && low.greenComponent < 0.1 && low.blueComponent < 0.1))

    // The legacy slot stacks with the identified painters and leaves them alone.
    W7SetTitlebarBandPainter(w, red)
    #expect(W7TitlebarBandPainterForWindow(w) === red && W7TitlebarBandPainterForIdentifier(w, "test.blue") === blue)
    W7SetTitlebarBandPainter(w, nil)
    #expect(W7TitlebarBandPainterForWindow(w) == nil && W7TitlebarBandPainterIdentifiers(w) == ["test.blue"])
    W7SetTitlebarBandPainterForIdentifier(w, "test.blue", nil)
    #expect(W7TitlebarBandPainterIdentifiers(w).isEmpty)
    w.close()
}

// MARK: - Hook a: website tint

@MainActor @Test func titlebarColourHooksOnlyActInThemedWindows() {
    let cls: AnyClass = makeClass("W7FakeBWC", superclass: NSWindowController.self, methods: [
        ("_needsUncoloredTitlebar", "B16@0:8", { (_: AnyObject) -> Bool in false } as @convention(block) (AnyObject) -> Bool),
        ("backgroundColorInTabBarEnabled", "B16@0:8", { (_: AnyObject) -> Bool in true } as @convention(block) (AnyObject) -> Bool),
    ])
    #expect(W7SafariHookWindowControllerColors(cls))
    #expect(W7SafariHookWindowControllerColors(cls))   // idempotent
    let w = makeWindow()
    let wc = (cls as! NSObject.Type).init() as! NSWindowController
    wc.window = w
    #expect(callBool(wc, "_needsUncoloredTitlebar") == false)
    #expect(callBool(wc, "backgroundColorInTabBarEnabled") == true)
    W7SafariSetWindowThemed(w, true)
    #expect(callBool(wc, "_needsUncoloredTitlebar") == true)
    #expect(callBool(wc, "backgroundColorInTabBarEnabled") == false)
    W7SafariSetWindowThemed(w, false)
    #expect(callBool(wc, "_needsUncoloredTitlebar") == false)

    let wrong: AnyClass = makeClass("W7FakeBWCWrong", superclass: NSWindowController.self, methods: [
        ("_needsUncoloredTitlebar", "c16@0:8", { (_: AnyObject) -> Int8 in 0 } as @convention(block) (AnyObject) -> Int8),
    ])
    #expect(!W7SafariHookWindowControllerColors(wrong))
    #expect(!W7SafariHookWindowControllerColors(nil))
}

// MARK: - Hook b: tab bar backdrops and separators

private final class FakeSeparator: NSView {
    @objc var alphaValueSet: Double = 1
}

@MainActor @Test func tabBarHookHidesBackdropsAndSeparatorsInThemedWindows() {
    let keep = Keeper()
    var layouts = 0
    let separatorClass: AnyClass = makeClass("W7FakeSeparator", superclass: FakeSeparator.self, methods: [
        ("setSeparatorAlphaValue:", "v24@0:8d16", { (me: AnyObject, v: Double) in (me as! FakeSeparator).alphaValueSet = v }
            as @convention(block) (AnyObject, Double) -> Void),
    ])
    var reruns: [(AnyObject?, Bool)] = []
    // Safari's own per-item separator update: here it shows the separator unless the item is highlighted.
    let update: @convention(block) (AnyObject, AnyObject?, Bool) -> Void = { me, item, highlighted in
        reruns.append((item, highlighted))
        let map = object_getIvar(me, class_getInstanceVariable(object_getClass(me), "_tabBarItemsToTabBarButtonSeparators")!) as! NSMapTable<AnyObject, AnyObject>
        (map.object(forKey: item) as? FakeSeparator)?.alphaValueSet = highlighted ? 0.25 : 1
    }
    let cls: AnyClass = makeClass("W7FakeUnifiedTabBar", superclass: NSView.self,
                        ivars: [("_backdropView", "@\"BackdropView\""), ("_pinnedTabRegionBackdropView", "@\"BackdropView\""),
                                ("_tabBarItemsToTabBarButtonSeparators", "@\"NSMapTable\""),
                                ("_highlightedTabBarViewItem", "@\"UnifiedTabBarItem\"")],
                        methods: [("layout", "v16@0:8", { (_: AnyObject) in layouts += 1 } as @convention(block) (AnyObject) -> Void),
                                  ("_updateSeparatorVisibilityForTabBarItem:isHighlighted:", "v28@0:8@16B24", update)])
    #expect(W7SafariHookTabBar(cls))
    #expect(W7SafariHookTabBar(cls))
    let w = makeWindow()
    let bar = (cls as! NSObject.Type).init() as! NSView
    bar.frame = NSRect(x: 0, y: 0, width: 400, height: 30)
    let backdrop = NSView(), pinned = NSView()
    let sep = (separatorClass as! NSObject.Type).init() as! FakeSeparator
    let sep2 = (separatorClass as! NSObject.Type).init() as! FakeSeparator
    let item = NSObject(), item2 = NSObject()
    let map = NSMapTable<AnyObject, AnyObject>.strongToStrongObjects()
    map.setObject(sep, forKey: item)
    map.setObject(sep2, forKey: item2)
    keep.objects += [backdrop, pinned, map, sep, sep2, item, item2]
    setIvar(bar, "_highlightedTabBarViewItem", item2)
    setIvar(bar, "_backdropView", backdrop)
    setIvar(bar, "_pinnedTabRegionBackdropView", pinned)
    setIvar(bar, "_tabBarItemsToTabBarButtonSeparators", map)
    bar.addSubview(backdrop); bar.addSubview(pinned)
    w.contentView!.addSubview(bar)

    call(bar, "layout")   // not themed: Safari's look
    #expect(layouts == 1 && !backdrop.isHidden && !pinned.isHidden && sep.alphaValueSet == 1)
    W7SafariSetWindowThemed(w, true)
    call(bar, "layout")
    #expect(layouts == 2 && backdrop.isHidden && pinned.isHidden && sep.alphaValueSet == 0 && sep2.alphaValueSet == 0)
    // Un-theming restores what was hidden and lets Safari decide each separator again, per item.
    W7SafariSetWindowThemed(w, false)
    reruns.removeAll()
    W7SafariRestoreTabBar(bar)
    #expect(!backdrop.isHidden && !pinned.isHidden && sep.alphaValueSet == 1 && sep2.alphaValueSet == 0.25)
    #expect(reruns.count == 2 && reruns.contains { $0.0 === item2 && $0.1 } && reruns.contains { $0.0 === item && !$0.1 })

    // A layout in a window that is no longer themed (full screen, a torn-off tab) unstyles on its own.
    W7SafariSetWindowThemed(w, true)
    call(bar, "layout")
    #expect(backdrop.isHidden && sep.alphaValueSet == 0)
    W7SafariSetWindowThemed(w, false)
    call(bar, "layout")
    #expect(!backdrop.isHidden && !pinned.isHidden && sep.alphaValueSet == 1)

    let wrong: AnyClass = makeClass("W7FakeUnifiedTabBarWrong", superclass: NSView.self,
                          methods: [("layout", "v24@0:8@16", { (_: AnyObject, _: AnyObject?) in } as @convention(block) (AnyObject, AnyObject?) -> Void)])
    #expect(!W7SafariHookTabBar(wrong))
    _ = keep
}

/// The tab bar's capture-only BackdropView is the source the glass tabs sample through their backdrop group:
/// hiding it blanks every tab. It, and a backdrop holding the tabs, stay visible; a plain backdrop still goes.
@MainActor @Test func tabBarHookKeepsCaptureBackdropsAndOnesHoldingTheTabs() {
    let keep = Keeper()
    let captureClass: AnyClass = makeClass("W7FakeCaptureBackdrop", superclass: NSView.self, methods: [
        ("captureOnly", "B16@0:8", { (_: AnyObject) -> Bool in true } as @convention(block) (AnyObject) -> Bool),
        ("groupName", "@16@0:8", { (_: AnyObject) -> AnyObject? in "UnifiedTabBar-1" as NSString } as @convention(block) (AnyObject) -> AnyObject?),
    ])
    let cls: AnyClass = makeClass("W7FakeUnifiedTabBarBackdrops", superclass: NSView.self,
                                  ivars: [("_backdropView", "@\"BackdropView\""), ("_pinnedTabRegionBackdropView", "@\"BackdropView\""),
                                          ("_tabContainer", "@\"NSView\""), ("_scrollView", "@\"NSScrollView\"")],
                                  methods: [("layout", "v16@0:8", { (_: AnyObject) in } as @convention(block) (AnyObject) -> Void)])
    #expect(W7SafariHookTabBar(cls))
    let w = makeWindow()
    W7SafariSetWindowThemed(w, true)
    let bar = (cls as! NSObject.Type).init() as! NSView
    bar.frame = NSRect(x: 0, y: 0, width: 400, height: 38)
    let capture = (captureClass as! NSObject.Type).init() as! NSView
    let pinned = NSView(), scroll = NSView(), container = NSView()
    pinned.addSubview(scroll)          // this backdrop holds the scrolling tabs
    scroll.addSubview(container)
    for v in [capture, pinned] { bar.addSubview(v) }
    keep.objects += [capture, pinned, scroll, container]
    setIvar(bar, "_backdropView", capture)
    setIvar(bar, "_pinnedTabRegionBackdropView", pinned)
    setIvar(bar, "_scrollView", scroll)
    setIvar(bar, "_tabContainer", container)
    w.contentView!.addSubview(bar)
    call(bar, "layout")
    #expect(!capture.isHidden && !pinned.isHidden && !container.isHiddenOrHasHiddenAncestor)
    W7SafariSetWindowThemed(w, false)
}

@Test func tabBarLineIsThrottledAndCapped() {
    #expect(W7SafariTabBarLogAllows(0, 10, -1))
    #expect(!W7SafariTabBarLogAllows(3, 10.5, 10))
    #expect(W7SafariTabBarLogAllows(3, 11, 10))
    #expect(!W7SafariTabBarLogAllows(10, 100, 10))   // at most 10 lines per window
}

@Test func tabBarLogThrottleAndDiagnosticsReruns() {
    #expect(W7SafariThrottleAllows(10, -1, 1))       // never logged
    #expect(!W7SafariThrottleAllows(10.5, 10, 1))
    #expect(W7SafariThrottleAllows(11, 10, 1))
    // Diagnostics run again when the accessories change or a tab bar first lays out, at most 3 times per window.
    #expect(W7SafariShouldRerunDiagnostics(1, true, false))
    #expect(W7SafariShouldRerunDiagnostics(2, false, true))
    #expect(!W7SafariShouldRerunDiagnostics(1, false, false))
    #expect(!W7SafariShouldRerunDiagnostics(3, true, true))
}

@MainActor @Test func tabButtonHookRejectsWrongEncodings() {
    let wrong: AnyClass = makeClass("W7FakeTabButtonWrong", superclass: NSView.self, methods: [
        ("layout", "v16@0:8", { (_: AnyObject) in } as @convention(block) (AnyObject) -> Void),
        ("updateBackgroundAppearance", "v20@0:8B16", { (_: AnyObject, _: Bool) in } as @convention(block) (AnyObject, Bool) -> Void),
    ])
    #expect(!W7SafariHookTabButton(wrong))
    #expect(!W7SafariHookTabButton(nil))
}

// MARK: - L2: orb overlay geometry

@Test func segmentRectsFollowFixedAndAutosizedWidths() {
    let b = CGRect(x: 0, y: 0, width: 90, height: 28)
    let even = W7SafariSegmentRects(b, [0, 0]).map { $0.rectValue }
    #expect(even == [CGRect(x: 0, y: 0, width: 45, height: 28), CGRect(x: 45, y: 0, width: 45, height: 28)])
    let fixed = W7SafariSegmentRects(b, [30, 40]).map { $0.rectValue }
    #expect(fixed == [CGRect(x: 0, y: 0, width: 30, height: 28), CGRect(x: 30, y: 0, width: 40, height: 28)])
    let mixed = W7SafariSegmentRects(b, [30, 0]).map { $0.rectValue }
    #expect(mixed == [CGRect(x: 0, y: 0, width: 30, height: 28), CGRect(x: 30, y: 0, width: 60, height: 28)])
    #expect(W7SafariSegmentRects(b, []).isEmpty)
}

@MainActor @Test func overlayOrbsSitInTheirOwnSegments() {
    for widths in [[0.0, 0.0], [38.0, 30.0], [26.0, 0.0]] {
        let control = NSSegmentedControl(frame: NSRect(x: 0, y: 0, width: 76, height: 28))
        control.segmentCount = 2
        for (i, w) in widths.enumerated() { control.setWidth(w, forSegment: i) }
        let segments = W7SafariSegmentRects(control.bounds, widths.map { NSNumber(value: $0) }).map { $0.rectValue }
        var back = CGRect.zero, forward = CGRect.zero
        W7SafariOverlayOrbRects(control, &back, &forward)
        #expect(segments[0].contains(CGPoint(x: back.midX, y: back.midY)), "\(widths)")
        #expect(segments[1].contains(CGPoint(x: forward.midX, y: forward.midY)), "\(widths)")
        #expect(abs(back.midX - segments[0].midX) < 0.5 && abs(forward.midX - segments[1].midX) < 0.5)
        #expect(back.width <= 28 && forward.width <= 24 && back.width <= segments[0].width && forward.width <= segments[1].width)
        #expect(back.width == back.height && forward.width == forward.height)
    }
}

// MARK: - Hook d: back/forward orbs

@MainActor @Test func backForwardHookSetsOrbImagesInThemedWindows() {
    var prepared = 0
    let cls: AnyClass = makeClass("W7FakeToolbarController", superclass: NSObject.self, methods: [
        ("_prepareBackForwardSegmentedControl:", "v24@0:8@16", { (_: AnyObject, control: AnyObject?) in
            prepared += 1
            let c = control as! NSSegmentedControl
            c.setImage(NSImage(systemSymbolName: "chevron.left", accessibilityDescription: nil), forSegment: 0)
            c.setImage(NSImage(systemSymbolName: "chevron.right", accessibilityDescription: nil), forSegment: 1)
        } as @convention(block) (AnyObject, AnyObject?) -> Void),
    ])
    #expect(W7SafariHookBackForward(cls))
    #expect(W7SafariHookBackForward(cls))
    let controller = (cls as! NSObject.Type).init()
    let w = makeWindow()
    let control = NSSegmentedControl(frame: NSRect(x: 0, y: 0, width: 80, height: 28))
    control.segmentCount = 2
    w.contentView!.addSubview(control)

    callObject(controller, "_prepareBackForwardSegmentedControl:", control)   // not themed
    #expect(prepared == 1 && control.image(forSegment: 0) !== W7SafariOrbImage(false))
    W7SafariSetWindowThemed(w, true)
    callObject(controller, "_prepareBackForwardSegmentedControl:", control)
    #expect(prepared == 2)
    #expect(control.image(forSegment: 0) === W7SafariOrbImage(false))
    #expect(control.image(forSegment: 1) === W7SafariOrbImage(true))
    #expect(control.toolTip(forSegment: 0) == nil)   // tooltips and menus left as they were
    let back = W7SafariOrbImage(false)
    #expect(back.size == NSSize(width: 28, height: 28) && !back.isTemplate)
    #expect(back.representations.count == 2)
    #expect(W7SafariOrbImage(true).size == NSSize(width: 24, height: 24))
    // Restoring puts Safari's own images back.
    W7SafariRestoreBackForward(control)
    #expect(control.image(forSegment: 0) !== W7SafariOrbImage(false))
    W7SafariSetWindowThemed(w, false)

    let wrong: AnyClass = makeClass("W7FakeToolbarControllerWrong", superclass: NSObject.self, methods: [
        ("_prepareBackForwardSegmentedControl:", "v16@0:8", { (_: AnyObject) in } as @convention(block) (AnyObject) -> Void),
    ])
    #expect(!W7SafariHookBackForward(wrong))
}

// MARK: - Hook e and L3: status bar

@MainActor @Test func statusBarSitsAtTheBottomAndInsetsTheContent() {
    let w = makeWindow()
    let content = w.contentView!
    let before = content.additionalSafeAreaInsets
    let bar = W7SafariInstallStatusBar(w)
    #expect(bar != nil)
    #expect(W7SafariInstallStatusBar(w) === bar)   // idempotent
    #expect(W7SafariStatusBarForWindow(w) === bar)
    #expect(bar!.frame == NSRect(x: 0, y: 0, width: content.bounds.width, height: 22))
    #expect(content.subviews.last === bar)
    #expect(content.additionalSafeAreaInsets.bottom == before.bottom + 22)
    #expect(bar!.hitTest(NSPoint(x: 5, y: 5)) === bar)   // clicks stop at the bar, never reach the page under it
    #expect(bar!.text == "Done" && bar!.progress < 0)
    W7SafariRemoveStatusBar(w)
    #expect(W7SafariStatusBarForWindow(w) == nil && bar!.superview == nil)
    #expect(content.additionalSafeAreaInsets.bottom == before.bottom)
}

private final class FakeStatusMessage: NSObject {
    @objc let string: String?
    @objc let url: URL?
    init(_ s: String?, _ u: URL?) { string = s; url = u }
}

private final class FakeSafariBrowserViewController: NSObject {
    @objc var estimatedProgress: Double = 0.3
}

@MainActor @Test func statusHooksFeedTheStatusBar() {
    var loading: Int32 = 2
    let bvc = FakeSafariBrowserViewController()
    var messages = 0
    let cls: AnyClass = makeClass("W7FakeBWCStatus", superclass: NSWindowController.self, methods: [
        ("_setStatusMessage:", "v24@0:8@16", { (_: AnyObject, _: AnyObject?) in messages += 1 } as @convention(block) (AnyObject, AnyObject?) -> Void),
        ("loadingStatusDidChangeInBrowserViewController:", "v24@0:8@16", { (_: AnyObject, _: AnyObject?) in }
            as @convention(block) (AnyObject, AnyObject?) -> Void),
        ("updateFluidProgressForBrowserViewController:", "v24@0:8@16", { (_: AnyObject, _: AnyObject?) in }
            as @convention(block) (AnyObject, AnyObject?) -> Void),
        ("currentTabLoadingStatus", "i16@0:8", { (_: AnyObject) -> Int32 in loading } as @convention(block) (AnyObject) -> Int32),
        ("currentBrowserViewController", "@16@0:8", { (_: AnyObject) -> AnyObject? in bvc } as @convention(block) (AnyObject) -> AnyObject?),
    ])
    #expect(W7SafariHookStatus(cls))
    #expect(W7SafariHookStatus(cls))
    let w = makeWindow()
    let wc = (cls as! NSObject.Type).init() as! NSWindowController
    wc.window = w
    let bar = W7SafariInstallStatusBar(w)!

    callObject(wc, "loadingStatusDidChangeInBrowserViewController:", bvc)
    #expect(bar.text == "" && abs(bar.progress - 0.3) < 0.001)
    bvc.estimatedProgress = 0.7
    callObject(wc, "updateFluidProgressForBrowserViewController:", bvc)
    #expect(abs(bar.progress - 0.7) < 0.001)
    callObject(wc, "_setStatusMessage:", FakeStatusMessage(nil, URL(string: "https://example.com/x")))
    #expect(messages == 1 && bar.text == "https://example.com/x")
    callObject(wc, "_setStatusMessage:", nil)
    #expect(bar.text == "")
    loading = 0
    callObject(wc, "loadingStatusDidChangeInBrowserViewController:", bvc)
    #expect(bar.text == "Done" && bar.progress < 0)
    W7SafariRemoveStatusBar(w)

    // Without a status bar (an unthemed or private window) the originals still run.
    callObject(wc, "_setStatusMessage:", FakeStatusMessage("x", nil))
    #expect(messages == 3 && bar.text == "Done")

    let wrong: AnyClass = makeClass("W7FakeBWCStatusWrong", superclass: NSWindowController.self, methods: [
        ("_setStatusMessage:", "v24@0:8q16", { (_: AnyObject, _: Int) in } as @convention(block) (AnyObject, Int) -> Void),
    ])
    #expect(!W7SafariHookStatus(wrong))
}

import AppKit
import ObjectiveC
import Testing
import Win7ChromeCore

// Safari's tabs drawn by win7mac (IE8 facsimile) over Safari's own tab buttons, whose faces go to alpha 0.
// Run-time fake tab buttons with Safari's exact ivar types and method encodings; no window is ordered on screen and no
// event is posted.

// MARK: - Helpers

private func uniqueName(_ prefix: String) -> String {
    "\(prefix)_\(UUID().uuidString.replacingOccurrences(of: "-", with: ""))"
}

private func makeClass(_ prefix: String, superclass: AnyClass, ivars: [(String, String)] = [],
                       methods: [(String, String, Any)] = []) -> AnyClass {
    let cls: AnyClass = objc_allocateClassPair(superclass, uniqueName(prefix), 0)!
    for (name, type) in ivars {
        precondition(class_addIvar(cls, name, MemoryLayout<UnsafeRawPointer>.size,
                                   UInt8(log2(Double(MemoryLayout<UnsafeRawPointer>.size))), type), "ivar \(name)")
    }
    for (sel, types, block) in methods { class_addMethod(cls, sel_registerName(sel), imp_implementationWithBlock(block), types) }
    objc_registerClassPair(cls)
    return cls
}

private func setIvar(_ object: AnyObject, _ name: String, _ value: AnyObject?) {
    object_setIvar(object, class_getInstanceVariable(object_getClass(object), name)!, value)
}

private func call(_ object: AnyObject, _ sel: String) {
    typealias F = @convention(c) (AnyObject, Selector) -> Void
    let s = sel_registerName(sel)
    unsafeBitCast(class_getMethodImplementation(object_getClass(object), s), to: F.self)(object, s)
}

private func callBool(_ object: AnyObject, _ sel: String, _ flag: Bool) {
    typealias F = @convention(c) (AnyObject, Selector, Bool) -> Void
    let s = sel_registerName(sel)
    unsafeBitCast(class_getMethodImplementation(object_getClass(object), s), to: F.self)(object, s, flag)
}

/// Keeps the objects run-time ivars hold unretained alive for a test.
private final class Keeper { var objects: [AnyObject] = [] }

@MainActor private func makeWindow() -> NSWindow {
    _ = NSApplication.shared
    let w = NSWindow(contentRect: .init(x: 0, y: 0, width: 600, height: 400),
                     styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: true)
    w.isReleasedWhenClosed = false
    return w
}

/// What a fake tab's methods answer (shared with the blocks).
private final class TabModel { var active = false, highlighted = false, pinned = false, layouts = 0, backgrounds = 0, moves = 0 }

private let faceIvars = ["_contentGlassView", "_backgroundView", "_visualEffectBackground", "_visualEffectBackgroundHighlight"]

@MainActor private func makeTabClass(_ model: TabModel, superclass: AnyClass = NSView.self) -> AnyClass {
    makeClass("W7FakeFacsimileTab", superclass: superclass,
              ivars: [("_unifiedField", "@\"NSView\""), ("_backgroundView", "@\"LayerView\""),
                      ("_visualEffectBackground", "@\"UnifiedTabBarVisualEffectView\""),
                      ("_visualEffectBackgroundHighlight", "@\"NSImageView\""), ("_contentGlassView", "@\"NSGlassEffectView\""),
                      ("_contentView", "@\"NSView\""), ("_titleTextField", "@\"NSTextField\""), ("_iconImageView", "@\"NSImageView\""),
                      ("_closeButton", "@\"NSButton\"")],
              methods: [
                ("layout", "v16@0:8", { (_: AnyObject) in model.layouts += 1 } as @convention(block) (AnyObject) -> Void),
                ("updateBackgroundAppearance", "v16@0:8", { (_: AnyObject) in model.backgrounds += 1 } as @convention(block) (AnyObject) -> Void),
                ("isActive", "B16@0:8", { (_: AnyObject) -> Bool in model.active } as @convention(block) (AnyObject) -> Bool),
                ("setActive:", "v20@0:8B16", { (_: AnyObject, flag: Bool) in model.active = flag } as @convention(block) (AnyObject, Bool) -> Void),
                ("isHighlighted", "B16@0:8", { (_: AnyObject) -> Bool in model.highlighted } as @convention(block) (AnyObject) -> Bool),
                ("isPinned", "B16@0:8", { (_: AnyObject) -> Bool in model.pinned } as @convention(block) (AnyObject) -> Bool),
                ("state", "q16@0:8", { (_: AnyObject) -> Int in 0 } as @convention(block) (AnyObject) -> Int),
                ("viewDidMoveToWindow", "v16@0:8", { (_: AnyObject) in model.moves += 1 } as @convention(block) (AnyObject) -> Void),
              ])
}

/// Safari's tab as it is on macOS 27: the glass wraps the content (title, icon, close button); three backgrounds beside it.
/// The close button sits at the LEFT end over the favicon, as Safari places it.
@MainActor private struct FakeTab {
    let button: NSView, glass: NSView, content: NSView, title: NSTextField, icon: NSImageView, close: NSButton
    let faces: [NSView]
}

@MainActor private func makeTab(_ cls: AnyClass, in parent: NSView, keep: Keeper, title: String = "Wikipedia") -> FakeTab {
    let button = (cls as! NSView.Type).init()
    button.frame = NSRect(x: 10, y: 4, width: 160, height: 28)
    button.wantsLayer = true
    parent.addSubview(button)   // first, as Safari does: its -viewDidMoveToWindow (hooked) finds no content yet
    let background = NSView(frame: button.bounds), effect = NSView(frame: button.bounds), highlight = NSView(frame: button.bounds)
    let glass = NSView(frame: button.bounds), content = NSView(frame: button.bounds)
    let field = NSTextField(labelWithString: title)
    field.frame = NSRect(x: 26, y: 6, width: 100, height: 16)
    let icon = NSImageView(frame: NSRect(x: 6, y: 6, width: 16, height: 16))
    icon.image = NSImage(size: NSSize(width: 16, height: 16), flipped: false) { r in
        NSColor.systemOrange.setFill(); r.fill(); return true
    }
    let close = NSButton(frame: NSRect(x: 6, y: 6, width: 16, height: 16))
    for v in [field, icon, close] as [NSView] { content.addSubview(v) }
    glass.addSubview(content)
    for v in [background, effect, highlight, glass] { button.addSubview(v) }
    for v in [background, effect, highlight, glass, content] { v.wantsLayer = true; v.autoresizingMask = [.width, .height] }   // fill the tab
    background.alphaValue = 1; effect.alphaValue = 0.6; highlight.alphaValue = 0.3   // Safari's own alphas, to be put back exactly
    keep.objects += [background, effect, highlight, glass, content, field, icon, close]
    setIvar(button, "_backgroundView", background)
    setIvar(button, "_visualEffectBackground", effect)
    setIvar(button, "_visualEffectBackgroundHighlight", highlight)
    setIvar(button, "_contentGlassView", glass)
    setIvar(button, "_contentView", content)
    setIvar(button, "_titleTextField", field)
    setIvar(button, "_iconImageView", icon)
    setIvar(button, "_closeButton", close)
    return FakeTab(button: button, glass: glass, content: content, title: field, icon: icon, close: close,
                   faces: [glass, background, effect, highlight, content])
}

/// Draws `view`'s drawRect into a bitmap (cacheDisplay would render a never-displayed layer); sRGB, bottom-left origin.
@MainActor private func render(_ view: NSView) -> (Int, Int) -> (r: Int, g: Int, b: Int, a: Int) {
    let w = Int(view.bounds.width), h = Int(view.bounds.height)
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: w, pixelsHigh: h, bitsPerSample: 8, samplesPerPixel: 4,
                               hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    view.draw(view.bounds)
    NSGraphicsContext.restoreGraphicsState()
    return { x, y in
        guard let c = rep.colorAt(x: x, y: h - 1 - y)?.usingColorSpace(.sRGB) else { return (0, 0, 0, 0) }
        return (Int((c.redComponent * 255).rounded()), Int((c.greenComponent * 255).rounded()),
                Int((c.blueComponent * 255).rounded()), Int((c.alphaComponent * 255).rounded()))
    }
}

private func near(_ p: (r: Int, g: Int, b: Int, a: Int), _ hex: UInt32, _ tolerance: Int = 3) -> Bool {
    abs(p.r - Int(hex >> 16 & 0xFF)) <= tolerance && abs(p.g - Int(hex >> 8 & 0xFF)) <= tolerance && abs(p.b - Int(hex & 0xFF)) <= tolerance
}

// MARK: - Tests

@Test func facsimileStartsOnlyWithHooksAndWithoutKillSwitch() {
    #expect(W7SafariFacsimileShouldStart(true, false))
    #expect(!W7SafariFacsimileShouldStart(true, true))
    #expect(!W7SafariFacsimileShouldStart(false, false))
}

/// Hook c in a themed window: Safari's faces at alpha 0 (never hidden), the facsimile as the button's topmost subview at
/// its bounds; every alpha back exactly on un-theming, and a pass in an unthemed window takes it all off again.
@MainActor @Test func hookCDrawsTheFacsimileOverInvisibleFacesAndRestoresThem() {
    let keep = Keeper(), model = TabModel()
    model.active = true
    let cls: AnyClass = makeTabClass(model)
    #expect(W7SafariHookTabButton(cls))
    W7SafariFacsimileSetEnabled(true)
    defer { W7SafariFacsimileSetEnabled(false) }
    let w = makeWindow()
    let t = makeTab(cls, in: w.contentView!, keep: keep)
    let before = t.faces.map(\.alphaValue)

    call(t.button, "updateBackgroundAppearance")   // not themed: Safari's tab
    #expect(model.backgrounds == 1 && W7SafariFacsimileViewForButton(t.button) == nil && t.faces.map(\.alphaValue) == before)

    W7SafariSetWindowThemed(w, true)
    call(t.button, "updateBackgroundAppearance")
    #expect(t.faces.allSatisfy { $0.alphaValue == 0 && !$0.isHidden })
    let fac = W7SafariFacsimileViewForButton(t.button)
    #expect(fac != nil && fac?.superview === t.button && t.button.subviews.last === fac && fac?.frame == t.button.bounds)
    #expect(!t.title.isHidden && !t.icon.isHidden && !t.close.isHidden)   // only read, never touched
    call(t.button, "layout")
    #expect(model.layouts == 1 && t.button.subviews.filter { $0 === fac }.count == 1)   // one view, reused

    W7SafariSetWindowThemed(w, false)
    W7SafariRestoreTabButton(t.button)
    #expect(W7SafariFacsimileViewForButton(t.button) == nil && fac?.superview == nil)
    #expect(t.faces.map(\.alphaValue) == before)   // the alphas Safari had, exactly

    W7SafariSetWindowThemed(w, true)               // a pass in a window no longer themed unstyles on its own
    call(t.button, "layout")
    #expect(W7SafariFacsimileViewForButton(t.button) != nil)
    W7SafariSetWindowThemed(w, false)
    call(t.button, "layout")
    #expect(W7SafariFacsimileViewForButton(t.button) == nil && t.faces.map(\.alphaValue) == before)
}

/// Safari changes a face's alpha while styled (its hover fade): zeroed again, and the restore gives Safari's newest value.
/// A face Safari set itself after the last pass is left as Safari set it.
@MainActor @Test func alphaSnapshotKeepsSafarisNewestValue() {
    let keep = Keeper(), model = TabModel()
    let cls: AnyClass = makeTabClass(model)
    #expect(W7SafariHookTabButton(cls))
    W7SafariFacsimileSetEnabled(true)
    defer { W7SafariFacsimileSetEnabled(false) }
    let w = makeWindow()
    W7SafariSetWindowThemed(w, true)
    defer { W7SafariSetWindowThemed(w, false) }
    let t = makeTab(cls, in: w.contentView!, keep: keep)
    call(t.button, "layout")
    let highlight = t.faces[3]
    highlight.alphaValue = 0.8                     // Safari's hover fade
    call(t.button, "updateBackgroundAppearance")
    #expect(highlight.alphaValue == 0)
    let effect = t.faces[2]
    effect.alphaValue = 0.9                        // Safari's own change after the last pass, before un-theming
    W7SafariSetWindowThemed(w, false)
    W7SafariRestoreTabButton(t.button)
    #expect(highlight.alphaValue == 0.8 && effect.alphaValue == 0.9 && t.faces[1].alphaValue == 1)
}

/// The facsimile never takes an event: hit testing finds Safari's views (an alpha-0 close button included) everywhere.
@MainActor @Test func facsimileIsClickThroughAndSafarisInvisibleButtonsStillHit() {
    let keep = Keeper(), model = TabModel()
    model.active = true
    let cls: AnyClass = makeTabClass(model)
    #expect(W7SafariHookTabButton(cls))
    W7SafariFacsimileSetEnabled(true)
    defer { W7SafariFacsimileSetEnabled(false) }
    let w = makeWindow()
    W7SafariSetWindowThemed(w, true)
    defer { W7SafariSetWindowThemed(w, false) }
    let t = makeTab(cls, in: w.contentView!, keep: keep)
    call(t.button, "layout")
    let fac = W7SafariFacsimileViewForButton(t.button)!
    #expect(fac.hitTest(NSPoint(x: 80, y: 14)) == nil)
    let root = w.contentView!
    let onClose = root.hitTest(root.convert(NSPoint(x: 146, y: 14), from: t.button))
    #expect(onClose === t.close)                   // inside the alpha-0 content: AppKit ignores alpha (at its moved frame)
    let onTab = root.hitTest(root.convert(NSPoint(x: 4, y: 2), from: t.button))
    #expect(onTab != nil && onTab !== fac && onTab!.isDescendant(of: t.button))
}

/// What it draws: the selected tab #C3DDFB→#F0F4FB in a #A3A7AC outline, Safari's
/// title and favicon, the close glyph at _closeButton's frame (moved to the tab's right end); an unselected tab
/// 2 pt shorter, an outline on the row's #E3EEFB standing on the #8B919F line, and no glyph when Safari hides its button.
@MainActor @Test func facsimileDrawsTheIE8TabFromSafarisButton() {
    let keep = Keeper(), model = TabModel()
    model.active = true
    let cls: AnyClass = makeTabClass(model)
    #expect(W7SafariHookTabButton(cls))
    W7SafariFacsimileSetEnabled(true)
    defer { W7SafariFacsimileSetEnabled(false) }
    let w = makeWindow()
    W7SafariSetWindowThemed(w, true)
    defer { W7SafariSetWindowThemed(w, false) }
    let t = makeTab(cls, in: w.contentView!, keep: keep)
    call(t.button, "layout")
    let fac = W7SafariFacsimileViewForButton(t.button)!
    var px = render(fac)
    #expect(near(px(80, 0), 0xF0F4FB, 4) && near(px(80, 25), 0xC3DDFB, 5))
    #expect(near(px(80, 27), 0xA3A7AC, 3) && near(px(0, 14), 0xA3A7AC, 3) && near(px(1, 14), 0xFFFFFF, 3))
    let iconPixel = px(13, 14)
    #expect(iconPixel.r > 200 && iconPixel.b < 120, "favicon \(iconPixel)")   // Safari's orange favicon at x + 6
    var dark = 0
    for y in 6..<22 { for x in 26..<120 where px(x, y).r < 90 { dark += 1 } }
    #expect(dark > 20)                             // Safari's title, black
    #expect(px(146, 14).r < 200 && abs(px(146, 14).r - px(146, 14).b) <= 8)   // the grey close glyph, at the right end
    #expect(W7SafariFacsimileCloseRect(t.button, fac, nil) == CGRect(x: 138, y: 6, width: 16, height: 16))

    model.active = false
    t.close.isHidden = true                        // Safari hides the close button of an unselected tab
    call(t.button, "layout")
    px = render(fac)
    #expect(px(80, 27).a == 0 && px(80, 26).a == 0)                       // 2 pt shorter
    #expect(near(px(80, 0), 0x8B919F, 3))                                 // on the row's line
    #expect(near(px(80, 22), 0xE3EEFB, 4) && near(px(80, 3), 0xE3EEFB, 4))   // the row's colour within the outline
    #expect(near(px(146, 14), 0xE3EEFB, 4))                               // no glyph
}

/// Safari's close button: its frame in any view's coordinates, shown only when Safari shows it; nothing without one.
@MainActor @Test func closeRectFollowsSafarisCloseButton() {
    let keep = Keeper(), model = TabModel()
    let cls: AnyClass = makeTabClass(model)
    let w = makeWindow()
    let t = makeTab(cls, in: w.contentView!, keep: keep)
    var shown: ObjCBool = false
    #expect(W7SafariFacsimileCloseRect(t.button, t.button, &shown) == CGRect(x: 6, y: 6, width: 16, height: 16) && shown.boolValue)
    t.close.alphaValue = 0                         // faded out by Safari
    _ = W7SafariFacsimileCloseRect(t.button, t.button, &shown)
    #expect(!shown.boolValue)
    t.close.alphaValue = 1
    t.content.alphaValue = 0                       // our alpha 0 on the content is not Safari hiding it
    _ = W7SafariFacsimileCloseRect(t.button, t.button, &shown)
    #expect(shown.boolValue)
    setIvar(t.button, "_closeButton", nil)
    #expect(W7SafariFacsimileCloseRect(t.button, t.button, &shown) == .zero && !shown.boolValue)
}

/// A pass with nothing changed asks for no redraw; a new title, favicon, state or close button redraws that tab only.
@MainActor @Test func facsimileRedrawsOnlyOnChange() {
    let keep = Keeper(), model = TabModel()
    let cls: AnyClass = makeTabClass(model)
    #expect(W7SafariHookTabButton(cls))
    W7SafariFacsimileSetEnabled(true)
    defer { W7SafariFacsimileSetEnabled(false) }
    let w = makeWindow()
    W7SafariSetWindowThemed(w, true)
    defer { W7SafariSetWindowThemed(w, false) }
    let t = makeTab(cls, in: w.contentView!, keep: keep)
    let other = makeTab(cls, in: w.contentView!, keep: keep, title: "Other")
    call(t.button, "layout"); call(other.button, "layout")
    let fac = W7SafariFacsimileViewForButton(t.button)!, otherFac = W7SafariFacsimileViewForButton(other.button)!
    var requests = W7SafariFacsimileRedrawRequests(fac)
    let otherRequests = W7SafariFacsimileRedrawRequests(otherFac)
    #expect(requests == 1 && fac.needsDisplay)                   // the first look
    for _ in 0..<5 { call(t.button, "updateBackgroundAppearance"); call(t.button, "layout") }
    #expect(W7SafariFacsimileRedrawRequests(fac) == requests)    // nothing changed: nothing to draw
    t.title.stringValue = String("Wiki" + "pedia")               // the same title in a new string: still nothing
    call(t.button, "layout")
    #expect(W7SafariFacsimileRedrawRequests(fac) == requests)
    t.title.stringValue = "Internet Explorer 8"
    call(t.button, "layout")
    #expect(W7SafariFacsimileRedrawRequests(fac) == requests + 1)
    #expect(W7SafariFacsimileRedrawRequests(otherFac) == otherRequests)   // that tab only
    requests += 1
    t.icon.image = NSImage(size: NSSize(width: 16, height: 16))
    call(t.button, "layout")
    #expect(W7SafariFacsimileRedrawRequests(fac) == requests + 1)
    callBool(t.button, "setActive:", true)                       // Safari selects it (hooked -setActive:)
    #expect(W7SafariFacsimileRedrawRequests(fac) == requests + 2)
    let draws = W7SafariFacsimileDrawCount(fac)
    _ = render(fac)
    #expect(W7SafariFacsimileDrawCount(fac) == draws + 1)
}

/// Kill switch: Safari's own tabs (nothing drawn, every alpha back); Compact layout, hidden and restructured buttons are
/// left alone too.
@MainActor @Test func killSwitchCompactHiddenAndRestructuredTabsAreSafaris() {
    let keep = Keeper(), model = TabModel()
    let cls: AnyClass = makeTabClass(model)
    #expect(W7SafariHookTabButton(cls))
    W7SafariFacsimileSetEnabled(true)
    defer { W7SafariFacsimileSetEnabled(false) }
    let w = makeWindow()
    W7SafariSetWindowThemed(w, true)
    defer { W7SafariSetWindowThemed(w, false) }
    let t = makeTab(cls, in: w.contentView!, keep: keep)
    let before = t.faces.map(\.alphaValue)
    call(t.button, "layout")
    #expect(W7SafariFacsimileViewForButton(t.button) != nil)
    W7SafariFacsimileSetEnabled(false)
    call(t.button, "layout")
    #expect(W7SafariFacsimileViewForButton(t.button) == nil && t.faces.map(\.alphaValue) == before)
    W7SafariFacsimileSetEnabled(true)

    let compact = makeTab(cls, in: w.contentView!, keep: keep)
    let field = NSView()
    keep.objects.append(field)
    setIvar(compact.button, "_unifiedField", field)
    call(compact.button, "layout")
    #expect(W7SafariFacsimileViewForButton(compact.button) == nil && compact.faces.allSatisfy { $0.alphaValue != 0 })

    let hidden = makeTab(cls, in: w.contentView!, keep: keep)
    hidden.button.isHidden = true                  // the toolbar's own tab bar in the Separate layout
    call(hidden.button, "layout")
    #expect(W7SafariFacsimileViewForButton(hidden.button) == nil)
    hidden.button.isHidden = false
    call(hidden.button, "layout")
    #expect(W7SafariFacsimileViewForButton(hidden.button) != nil)

    let moved = makeTab(cls, in: w.contentView!, keep: keep)
    call(moved.button, "layout")
    #expect(W7SafariFacsimileViewForButton(moved.button) != nil)
    moved.content.removeFromSuperview()            // Safari restructures: the content is no longer inside the button
    call(moved.button, "layout")
    #expect(W7SafariFacsimileViewForButton(moved.button) == nil && moved.faces.filter { $0 !== moved.content }.allSatisfy { $0.alphaValue != 0 })
}

/// Safari's real structure: the selected tab hosted in the tab bar's capture-only backdrop, not among the visible
/// buttons. The tab bar's pass finds it there and draws its facsimile; window close puts every alpha back.
@MainActor @Test func selectedTabInTheBackdropIsDrawnAndWindowCloseRestores() {
    let keep = Keeper(), model = TabModel()
    model.active = true
    let base: AnyClass = objc_getClass("UnifiedTabBarButton") as? AnyClass ?? {
        let cls: AnyClass = objc_allocateClassPair(NSView.self, "UnifiedTabBarButton", 0)!
        objc_registerClassPair(cls)
        return cls
    }()
    let cls: AnyClass = makeTabClass(model, superclass: base)
    let captureClass: AnyClass = makeClass("W7FakeFacsimileCapture", superclass: NSView.self, methods: [
        ("captureOnly", "B16@0:8", { (_: AnyObject) -> Bool in true } as @convention(block) (AnyObject) -> Bool)])
    let barClass: AnyClass = makeClass("W7FakeFacsimileTabBar", superclass: NSView.self,
        ivars: [("_visibleTabBarButtons", "@\"NSMutableSet\""), ("_backdropView", "@\"BackdropView\"")],
        methods: [("layout", "v16@0:8", { (_: AnyObject) in } as @convention(block) (AnyObject) -> Void)])
    #expect(W7SafariHookTabBar(barClass))
    W7SafariFacsimileStart(true)
    defer { W7SafariFacsimileSetEnabled(false) }
    let w = makeWindow()
    let bar = (barClass as! NSView.Type).init()
    bar.frame = NSRect(x: 0, y: 0, width: 600, height: 38)
    let backdrop = (captureClass as! NSView.Type).init(frame: bar.bounds)
    let holder = NSView(frame: bar.bounds)
    backdrop.addSubview(holder)
    bar.addSubview(backdrop)
    w.contentView!.addSubview(bar)
    let set = NSMutableSet()
    setIvar(bar, "_visibleTabBarButtons", set)
    setIvar(bar, "_backdropView", backdrop)
    keep.objects += [set, backdrop, holder]
    let t = makeTab(cls, in: holder, keep: keep)
    let before = t.faces.map(\.alphaValue)
    W7SafariSetWindowThemed(w, true)
    call(bar, "layout")
    #expect(W7SafariFacsimileViewForButton(t.button) != nil && t.faces.allSatisfy { $0.alphaValue == 0 })
    #expect(!backdrop.isHidden)
    w.close()                                       // every alpha back before the window's views go
    #expect(t.faces.map(\.alphaValue) == before && W7SafariFacsimileViewForButton(t.button) == nil)
    W7SafariSetWindowThemed(w, false)
}

// MARK: - Later fixes

@MainActor private func mouseEvent(_ w: NSWindow, at p: NSPoint) -> NSEvent {
    NSEvent.mouseEvent(with: .mouseMoved, location: p, modifierFlags: [], timestamp: 0, windowNumber: w.windowNumber,
                       context: nil, eventNumber: 0, clickCount: 0, pressure: 0)!
}

/// The facsimile's own tracking area: entering an unselected tab draws it as hover, the pointer over the close glyph
/// turns it red, leaving puts the normal look back. Called directly (no event is posted).
@MainActor @Test func hoverTrackingDrawsHoverAndTheRedCloseGlyph() {
    let keep = Keeper(), model = TabModel()
    let cls: AnyClass = makeTabClass(model)
    #expect(W7SafariHookTabButton(cls))
    W7SafariFacsimileSetEnabled(true)
    defer { W7SafariFacsimileSetEnabled(false) }
    let w = makeWindow()
    W7SafariSetWindowThemed(w, true)
    defer { W7SafariSetWindowThemed(w, false) }
    let t = makeTab(cls, in: w.contentView!, keep: keep)
    call(t.button, "layout")
    let fac = W7SafariFacsimileViewForButton(t.button)!
    let normal = render(fac)(80, 4)
    let inTab = fac.convert(NSPoint(x: 60, y: 14), to: nil)
    fac.mouseEntered(with: mouseEvent(w, at: inTab))
    var px = render(fac)
    let hover = W7IETabColorsForState(.hover)
    #expect(px(80, 4).r + px(80, 4).g + px(80, 4).b > normal.r + normal.g + normal.b)   // lighter: the hover fill
    #expect(near(px(80, 3), hover.bottom, 6))
    #expect(px(146, 14).r < 200 && abs(px(146, 14).r - px(146, 14).b) <= 8)             // the close glyph, grey
    fac.mouseMoved(with: mouseEvent(w, at: fac.convert(NSPoint(x: 146, y: 14), to: nil)))
    px = render(fac)
    #expect(px(146, 14).r > px(146, 14).b + 60)                                         // red under the pointer
    fac.mouseExited(with: mouseEvent(w, at: fac.convert(NSPoint(x: 200, y: 14), to: nil)))
    px = render(fac)
    #expect(near(px(80, 4), 0xE3EEFB, 4))                                               // normal again
    #expect(px(146, 14).r < 200 && abs(px(146, 14).r - px(146, 14).b) <= 8)
}

/// A tab out of any window (Safari's reuse pool) is left until it is back; its -viewDidMoveToWindow (hooked) styles it then.
@MainActor @Test func tabOutOfAnyWindowIsStyledWhenItMovesBackIn() {
    let keep = Keeper(), model = TabModel()
    let cls: AnyClass = makeTabClass(model)
    #expect(W7SafariHookTabButton(cls))
    W7SafariFacsimileSetEnabled(true)
    defer { W7SafariFacsimileSetEnabled(false) }
    let w = makeWindow()
    W7SafariSetWindowThemed(w, true)
    defer { W7SafariSetWindowThemed(w, false) }
    let t = makeTab(cls, in: w.contentView!, keep: keep)
    t.button.removeFromSuperview()
    call(t.button, "layout")                       // no window: deferred, nothing done
    #expect(W7SafariFacsimileViewForButton(t.button) == nil && t.faces.allSatisfy { $0.alphaValue != 0 })
    let moves = model.moves
    w.contentView!.addSubview(t.button)            // AppKit calls -viewDidMoveToWindow
    #expect(model.moves == moves + 1)              // Safari's own ran
    #expect(W7SafariFacsimileViewForButton(t.button) != nil && t.faces.allSatisfy { $0.alphaValue == 0 })

    // Moved to another themed window: still styled, and tracked there too (its window refresh reaches it).
    let w2 = makeWindow()
    W7SafariSetWindowThemed(w2, true)
    defer { W7SafariSetWindowThemed(w2, false) }
    w2.contentView!.addSubview(t.button)
    let fac = W7SafariFacsimileViewForButton(t.button)!
    let requests = W7SafariFacsimileRedrawRequests(fac)
    t.title.stringValue = "Moved"
    W7SafariFacsimileRefreshWindow(w2, true)
    #expect(W7SafariFacsimileRedrawRequests(fac) == requests + 1)
}

/// Window refreshes (window updates, loading) run at most every 0.25 s per window unless forced.
@MainActor @Test func windowRefreshIsThrottled() {
    let keep = Keeper(), model = TabModel()
    let cls: AnyClass = makeTabClass(model)
    #expect(W7SafariHookTabButton(cls))
    W7SafariFacsimileSetEnabled(true)
    defer { W7SafariFacsimileSetEnabled(false) }
    let w = makeWindow()
    W7SafariSetWindowThemed(w, true)
    defer { W7SafariSetWindowThemed(w, false) }
    let t = makeTab(cls, in: w.contentView!, keep: keep)
    call(t.button, "layout")
    let fac = W7SafariFacsimileViewForButton(t.button)!
    W7SafariFacsimileRefreshWindow(w, true)        // starts the 0.25 s window
    var requests = W7SafariFacsimileRedrawRequests(fac)
    t.title.stringValue = "First"
    W7SafariFacsimileRefreshWindow(w, false)       // within 0.25 s: skipped
    #expect(W7SafariFacsimileRedrawRequests(fac) == requests)
    usleep(300_000)
    W7SafariFacsimileRefreshWindow(w, false)       // after it: refreshed
    #expect(W7SafariFacsimileRedrawRequests(fac) == requests + 1)
    requests += 1
    t.title.stringValue = "Second"
    W7SafariFacsimileRefreshWindow(w, true)        // forced: at once
    #expect(W7SafariFacsimileRedrawRequests(fac) == requests + 1)
    let unthemed = makeWindow()                    // never for an unthemed window
    W7SafariFacsimileRefreshWindow(unthemed, true)
}

/// Safari's other in-tab controls (the audio button of a tab playing sound) sit in the alpha-0 content: the facsimile
/// draws a glyph at each (a speaker for the audio button), keeps the title clear of it, and a hidden one draws nothing.
@MainActor @Test func tabAccessoriesGetAGlyph() {
    let keep = Keeper(), model = TabModel()
    model.active = true
    let cls: AnyClass = makeTabClass(model)
    #expect(W7SafariHookTabButton(cls))
    W7SafariFacsimileSetEnabled(true)
    defer { W7SafariFacsimileSetEnabled(false) }
    let w = makeWindow()
    W7SafariSetWindowThemed(w, true)
    defer { W7SafariSetWindowThemed(w, false) }
    let audioClass: AnyClass = makeClass("W7FakeTabAudioButton", superclass: NSButton.self)
    let t = makeTab(cls, in: w.contentView!, keep: keep, title: String(repeating: "Wikipedia ", count: 4))
    let audio = (audioClass as! NSButton.Type).init(frame: NSRect(x: 116, y: 8, width: 12, height: 12))
    let other = NSImageView(frame: NSRect(x: 100, y: 8, width: 12, height: 12))
    t.content.addSubview(audio)
    t.content.addSubview(other)
    keep.objects += [audio, other]
    call(t.button, "layout")
    let fac = W7SafariFacsimileViewForButton(t.button)!
    var px = render(fac)
    func inked(_ x0: Int, _ x1: Int) -> Int {
        var n = 0
        for y in 8..<20 { for x in x0..<x1 where px(x, y).r < 120 { n += 1 } }
        return n
    }
    #expect(inked(116, 128) > 6)                   // the speaker at the audio button's frame
    #expect(inked(100, 112) > 6)                   // the generic glyph at the other control
    // The long title stops 4 pt before the first control: nothing in the gaps before, between and after them.
    #expect(inked(96, 100) == 0 && inked(112, 116) == 0 && inked(128, 134) == 0)
    #expect(audio.alphaValue == 1 && !audio.isHidden)   // Safari's controls are only read
    audio.isHidden = true                          // Safari hides them: on the next scan, no glyph there
    other.isHidden = true
    t.title.stringValue = "Wiki"                   // (a short title, so nothing else is drawn there)
    usleep(550_000)                                // the scan runs at most twice a second
    call(t.button, "layout")
    px = render(fac)
    #expect(inked(98, 130) == 0)
}

/// A face holding an excluded view (here an AutoFill stand-in) is left visible: hook c never zeroes it.
@MainActor @Test func faceHoldingAnExcludedViewIsLeftAlone() {
    let keep = Keeper(), model = TabModel()
    let cls: AnyClass = makeTabClass(model)
    #expect(W7SafariHookTabButton(cls))
    W7SafariFacsimileSetEnabled(true)
    defer { W7SafariFacsimileSetEnabled(false) }
    let w = makeWindow()
    W7SafariSetWindowThemed(w, true)
    defer { W7SafariSetWindowThemed(w, false) }
    let t = makeTab(cls, in: w.contentView!, keep: keep)
    let excludedClass: AnyClass = makeClass("AutoFillW7Stub", superclass: NSView.self)
    let stub = (excludedClass as! NSView.Type).init()
    t.faces[1].addSubview(stub)                    // inside _backgroundView
    keep.objects.append(stub)
    call(t.button, "layout")
    #expect(t.faces[1].alphaValue == 1)            // left as Safari has it
    #expect(t.faces[0].alphaValue == 0 && t.faces[2].alphaValue == 0)
    call(t.button, "layout")
    #expect(t.faces[1].alphaValue == 1)
}

// MARK: - the close button at the tab's right end, the title kept under the pointer, the page icon

/// Where the × goes (pure): its right edge 6 pt from the tab's right edge, vertically centred, Safari's size, on
/// whole points.
@Test func closeButtonFrameIsSixPointsFromTheRightEdgeAndCentred() {
    #expect(W7SafariCloseButtonRightInset == 6 && W7SafariCloseButtonMaxResetsPerSecond == 8)
    #expect(W7SafariCloseButtonFrameFor(CGRect(x: 0, y: 0, width: 160, height: 28), CGSize(width: 16, height: 16))
            == CGRect(x: 138, y: 6, width: 16, height: 16))
    #expect(W7SafariCloseButtonFrameFor(CGRect(x: 10, y: 4, width: 120.4, height: 27), CGSize(width: 14, height: 14))
            == CGRect(x: 110, y: 11, width: 14, height: 14))
}

/// Hook c moves Safari's own _closeButton (not a copy) to the right end of a styled tab, follows the tab's width, does
/// nothing when it is already there, and puts Safari's frame back exactly when the styling comes off.
@MainActor @Test func closeButtonMovesToTheRightEndAndIsPutBackExactly() {
    let keep = Keeper(), model = TabModel()
    model.active = true
    let cls: AnyClass = makeTabClass(model)
    #expect(W7SafariHookTabButton(cls))
    W7SafariFacsimileSetEnabled(true)
    defer { W7SafariFacsimileSetEnabled(false) }
    let w = makeWindow()
    W7SafariSetWindowThemed(w, true)
    defer { W7SafariSetWindowThemed(w, false) }
    let t = makeTab(cls, in: w.contentView!, keep: keep)
    let safaris = t.close.frame
    #expect(safaris == CGRect(x: 6, y: 6, width: 16, height: 16) && W7SafariCloseButtonPlacementOf(t.button) == .untouched)
    call(t.button, "layout")
    #expect(t.close.frame == CGRect(x: 138, y: 6, width: 16, height: 16))
    #expect(W7SafariCloseButtonPlacementOf(t.button) == .moved && t.close.superview === t.content)
    call(t.button, "updateBackgroundAppearance")
    #expect(t.close.frame == CGRect(x: 138, y: 6, width: 16, height: 16))   // already there: left alone
    let fac = W7SafariFacsimileViewForButton(t.button)!
    let px = render(fac)
    let iconPixel = px(13, 14)
    #expect(iconPixel.r > 200 && iconPixel.b < 120, "favicon \(iconPixel)")   // the favicon shows: no × over it any more
    var dark = 0
    for y in 6..<22 { for x in 26..<120 where px(x, y).r < 90 { dark += 1 } }
    #expect(dark > 20)                                                        // and the title is drawn after it
    t.button.setFrameSize(NSSize(width: 200, height: 28))                     // Safari widens the tab: the × follows
    call(t.button, "layout")
    #expect(t.close.frame == CGRect(x: 178, y: 6, width: 16, height: 16))
    W7SafariSetWindowThemed(w, false)
    W7SafariRestoreTabButton(t.button)
    #expect(t.close.frame == safaris && W7SafariCloseButtonPlacementOf(t.button) == .untouched)
}

/// The kill switch leaves the × where Safari put it; a frame Safari set itself after our move is kept on the restore.
@MainActor @Test func closeButtonKillSwitchRestoresAndSafarisOwnLaterFrameIsKept() {
    let keep = Keeper(), model = TabModel()
    let cls: AnyClass = makeTabClass(model)
    #expect(W7SafariHookTabButton(cls))
    W7SafariFacsimileSetEnabled(true)
    defer { W7SafariFacsimileSetEnabled(false) }
    let w = makeWindow()
    W7SafariSetWindowThemed(w, true)
    defer { W7SafariSetWindowThemed(w, false) }
    let t = makeTab(cls, in: w.contentView!, keep: keep)
    call(t.button, "layout")
    #expect(t.close.frame.minX == 138)
    W7SafariFacsimileSetEnabled(false)
    call(t.button, "layout")
    #expect(t.close.frame == CGRect(x: 6, y: 6, width: 16, height: 16))
    W7SafariFacsimileSetEnabled(true)
    call(t.button, "layout")
    #expect(t.close.frame.minX == 138)
    W7SafariSetWindowThemed(w, false)
    t.close.frame = CGRect(x: 30, y: 6, width: 16, height: 16)              // Safari's own change once the window is un-themed
    W7SafariRestoreTabButton(t.button)
    #expect(t.close.frame == CGRect(x: 30, y: 6, width: 16, height: 16))    // not ours any more: left as Safari set it
}

/// Safari putting the × back every pass: after 8 re-sets in a second ours is set once more; the 9th backs off for that
/// button (Safari's frame kept, nothing set again). The facsimile then draws the × at the left over the favicon, and the
/// title is still there.
@MainActor @Test func closeButtonBacksOffWhenSafariKeepsPuttingItBackAndTheTitleStays() {
    let keep = Keeper(), model = TabModel()
    model.active = true
    let cls: AnyClass = makeTabClass(model)
    #expect(W7SafariHookTabButton(cls))
    W7SafariFacsimileSetEnabled(true)
    defer { W7SafariFacsimileSetEnabled(false) }
    let w = makeWindow()
    W7SafariSetWindowThemed(w, true)
    defer { W7SafariSetWindowThemed(w, false) }
    let t = makeTab(cls, in: w.contentView!, keep: keep)
    let safaris = t.close.frame
    call(t.button, "layout")
    #expect(t.close.frame.minX == 138)
    for i in 1...8 {
        t.close.frame = safaris                                               // Safari's layout puts it back
        call(t.button, "layout")
        #expect(t.close.frame.minX == 138, "re-set \(i)")
    }
    t.close.frame = safaris
    call(t.button, "layout")                                                  // the 9th in a second: back off
    #expect(t.close.frame == safaris && W7SafariCloseButtonPlacementOf(t.button) == .backedOff)
    call(t.button, "layout")
    call(t.button, "updateBackgroundAppearance")
    #expect(t.close.frame == safaris)                                         // left to Safari at this width for now
    #expect(W7SafariFacsimileViewForButton(t.button) != nil)                  // the tab is still drawn by us
    let fac = W7SafariFacsimileViewForButton(t.button)!
    let px = render(fac)
    let underClose = px(14, 14)
    #expect(!(underClose.r > 200 && underClose.b < 120), "icon under the × \(underClose)")   // the × wins over the icon
    #expect(underClose.r < 200 && abs(underClose.r - underClose.b) <= 8)      // the grey glyph at Safari's frame
    var dark = 0
    for y in 6..<22 { for x in 26..<120 where px(x, y).r < 90 { dark += 1 } }
    #expect(dark > 20)                                                        // the title never disappears
    t.button.setFrameSize(NSSize(width: 200, height: 28))                     // a new tab width lifts the back-off (as the row's)
    call(t.button, "layout")
    #expect(t.close.frame.minX == 178 && W7SafariCloseButtonPlacementOf(t.button) == .moved)
    W7SafariSetWindowThemed(w, false)
    W7SafariRestoreTabButton(t.button)
    #expect(t.close.frame == CGRect(x: 6, y: 6, width: 16, height: 16))
}

/// Safari's tab content as an NSStackView (live: 8 constraints, autoresizing not translated): the × first, then the
/// icon and the title; the stack lays the × out at the left whenever it runs.
@MainActor private func hostInStackView(_ t: FakeTab, keep: Keeper) -> NSStackView {
    let stack = NSStackView(frame: t.content.bounds)
    stack.orientation = .horizontal
    stack.alignment = .centerY
    stack.spacing = 4
    stack.edgeInsets = NSEdgeInsets(top: 0, left: 6, bottom: 0, right: 6)
    stack.autoresizingMask = [.width, .height]
    t.close.removeFromSuperview()
    t.icon.removeFromSuperview()
    t.title.removeFromSuperview()
    t.content.addSubview(stack)
    for v in [t.close, t.icon, t.title] as [NSView] {
        v.translatesAutoresizingMaskIntoConstraints = false
        stack.addArrangedSubview(v)
    }
    t.close.widthAnchor.constraint(equalToConstant: 16).isActive = true
    t.close.heightAnchor.constraint(equalToConstant: 16).isActive = true
    keep.objects.append(stack)
    return stack
}

/// Safari hosts the close button in an NSStackView: the stack's own layout after the button's puts it back at the left;
/// hook c's next pass puts it at the right again, and that is not a fight (fewer than 9 re-sets a second), so the ×
/// sits at the right whenever Safari shows it.
@MainActor @Test func closeButtonInAStackViewEndsAtTheRightAfterHookCsPass() {
    let keep = Keeper(), model = TabModel()
    model.active = true
    let cls: AnyClass = makeTabClass(model)
    #expect(W7SafariHookTabButton(cls))
    W7SafariFacsimileSetEnabled(true)
    defer { W7SafariFacsimileSetEnabled(false) }
    let w = makeWindow()
    W7SafariSetWindowThemed(w, true)
    defer { W7SafariSetWindowThemed(w, false) }
    let t = makeTab(cls, in: w.contentView!, keep: keep)
    _ = hostInStackView(t, keep: keep)
    t.content.layoutSubtreeIfNeeded()                                         // Safari's stack lays it out: at the left (no hook-c pass)
    #expect(t.close.frame.minX == 6 && !t.close.translatesAutoresizingMaskIntoConstraints)
    call(t.button, "layout")                                                  // hook c: moved
    #expect(t.close.frame.minX == 138)
    t.button.layoutSubtreeIfNeeded()                                          // the stack's layout after the button's
    t.button.layoutSubtreeIfNeeded()
    let afterStack = t.close.frame.minX
    call(t.button, "updateBackgroundAppearance")                              // hook c's next pass (hover, selection)
    #expect(t.close.frame.minX == 138 && W7SafariCloseButtonPlacementOf(t.button) == .moved, "stack put it at \(afterStack)")
    for _ in 0..<3 { t.button.layoutSubtreeIfNeeded(); call(t.button, "layout") }
    #expect(t.close.frame.minX == 138 && W7SafariCloseButtonPlacementOf(t.button) == .moved)
    let root = w.contentView!
    #expect(root.hitTest(root.convert(NSPoint(x: 146, y: 14), from: t.button)) === t.close)
    W7SafariSetWindowThemed(w, false)
    W7SafariRestoreTabButton(t.button)
    t.button.layoutSubtreeIfNeeded()
    #expect(t.close.frame.minX == 6)
}

/// The user's bug: on pointer entry Safari un-hides the × and its stack lays it out at the LEFT with
/// no hook-c pass; the facsimile's own refresh read that frame and drew the × over the icon until the pointer moved
/// again. Now the close button's frame is observed while styled: Safari's move is undone at once, the facsimile's close
/// rect is at the right, our own set is not a re-entry, and the observer goes (and postsFrameChangedNotifications is
/// put back) on unstyle.
@MainActor @Test func closeButtonFollowsSafarisHoverLayoutWithoutAHookCPass() {
    let keep = Keeper(), model = TabModel()
    model.active = true
    let cls: AnyClass = makeTabClass(model)
    #expect(W7SafariHookTabButton(cls))
    W7SafariFacsimileSetEnabled(true)
    defer { W7SafariFacsimileSetEnabled(false) }
    let w = makeWindow()
    W7SafariSetWindowThemed(w, true)
    defer { W7SafariSetWindowThemed(w, false) }
    let t = makeTab(cls, in: w.contentView!, keep: keep)
    let stack = hostInStackView(t, keep: keep)
    t.close.isHidden = true                                                   // idle: Safari hides the ×
    let posted = t.close.postsFrameChangedNotifications
    t.content.layoutSubtreeIfNeeded()                                         // Safari's stack, no hook-c pass
    call(t.button, "layout")                                                  // hook c: styled, the × (hidden) moved
    #expect(t.close.frame.minX == 138 && t.close.postsFrameChangedNotifications)
    let fac = W7SafariFacsimileViewForButton(t.button)!
    t.close.isHidden = false                                                  // pointer entry: Safari shows it…
    stack.needsLayout = true
    t.button.layoutSubtreeIfNeeded()                                          // …and its stack lays it out (no hook-c pass)
    #expect(t.close.frame.minX == 138, "stack layout left it at \(t.close.frame.minX)")
    var shown: ObjCBool = false
    #expect(W7SafariFacsimileCloseRect(t.button, fac, &shown).minX == 138 && shown.boolValue)
    let resets = W7SafariCloseButtonResets(t.button)
    t.close.frame = CGRect(x: 6, y: 6, width: 16, height: 16)                // Safari sets the frame directly
    #expect(t.close.frame.minX == 138)                                        // undone at once
    #expect(W7SafariCloseButtonResets(t.button) == resets + 1)                // one re-set; our own set did not re-enter
    let px = render(fac)
    #expect(px(146, 14).r < 200 && abs(px(146, 14).r - px(146, 14).b) <= 8)   // the × drawn at the right
    #expect(px(13, 14).r > 200 && px(13, 14).b < 120)                         // the favicon under the pointer, not a ×
    W7SafariSetWindowThemed(w, false)
    W7SafariRestoreTabButton(t.button)
    #expect(t.close.postsFrameChangedNotifications == posted && t.close.frame.minX == 6)
    t.close.frame = CGRect(x: 50, y: 6, width: 16, height: 16)               // no observer any more
    #expect(t.close.frame.minX == 50)
}

/// Nine stack-vs-ours rounds within a second back the move off (Safari's frame kept); a new tab width lifts it.
@MainActor @Test func closeButtonBacksOffAfterNineStackRoundsAndLiftsOnResize() {
    let keep = Keeper(), model = TabModel()
    model.active = true
    let cls: AnyClass = makeTabClass(model)
    #expect(W7SafariHookTabButton(cls))
    W7SafariFacsimileSetEnabled(true)
    defer { W7SafariFacsimileSetEnabled(false) }
    let w = makeWindow()
    W7SafariSetWindowThemed(w, true)
    defer { W7SafariSetWindowThemed(w, false) }
    let t = makeTab(cls, in: w.contentView!, keep: keep)
    _ = hostInStackView(t, keep: keep)
    t.content.layoutSubtreeIfNeeded()                                         // Safari's stack, no hook-c pass
    call(t.button, "layout")
    #expect(t.close.frame.minX == 138 && W7SafariCloseButtonResets(t.button) == 0)
    let left = CGRect(x: 6, y: 6, width: 16, height: 16)
    for i in 1...8 {
        t.close.frame = left                                                  // Safari's stack puts it back
        #expect(t.close.frame.minX == 138 && W7SafariCloseButtonResets(t.button) == i, "round \(i)")
    }
    t.close.frame = left                                                      // the 9th in a second
    #expect(t.close.frame.minX == 6 && W7SafariCloseButtonPlacementOf(t.button) == .backedOff)
    call(t.button, "updateBackgroundAppearance")
    #expect(t.close.frame.minX == 6)
    t.button.setFrameSize(NSSize(width: 200, height: 28))                     // lifted by the new width
    call(t.button, "layout")
    #expect(t.close.frame.minX == 178 && W7SafariCloseButtonPlacementOf(t.button) == .moved)
    W7SafariSetWindowThemed(w, false)
    W7SafariRestoreTabButton(t.button)
    #expect(t.close.frame.minX == 6)
}

/// A frame AppKit realigned by less than half a point is still ours: the restore puts Safari's frame back.
@MainActor @Test func closeButtonRestoreToleratesASubPointRealignment() {
    let keep = Keeper(), model = TabModel()
    let cls: AnyClass = makeTabClass(model)
    #expect(W7SafariHookTabButton(cls))
    W7SafariFacsimileSetEnabled(true)
    defer { W7SafariFacsimileSetEnabled(false) }
    let w = makeWindow()
    W7SafariSetWindowThemed(w, true)
    defer { W7SafariSetWindowThemed(w, false) }
    let t = makeTab(cls, in: w.contentView!, keep: keep)
    call(t.button, "layout")
    t.close.frame = CGRect(x: 138.25, y: 6, width: 16, height: 16)          // realigned by AppKit, not Safari's doing
    call(t.button, "layout")
    #expect(t.close.frame.minX == 138.25)                                     // "already there": nothing set
    W7SafariSetWindowThemed(w, false)
    W7SafariRestoreTabButton(t.button)
    #expect(t.close.frame == CGRect(x: 6, y: 6, width: 16, height: 16))
}

/// AppKit hit-tests the frame: at the new frame the click reaches Safari's close button; at its old place it does not.
@MainActor @Test func hitTestAtTheMovedFrameFindsSafarisCloseButton() {
    let keep = Keeper(), model = TabModel()
    model.active = true
    let cls: AnyClass = makeTabClass(model)
    #expect(W7SafariHookTabButton(cls))
    W7SafariFacsimileSetEnabled(true)
    defer { W7SafariFacsimileSetEnabled(false) }
    let w = makeWindow()
    W7SafariSetWindowThemed(w, true)
    defer { W7SafariSetWindowThemed(w, false) }
    let t = makeTab(cls, in: w.contentView!, keep: keep)
    let root = w.contentView!
    #expect(root.hitTest(root.convert(NSPoint(x: 14, y: 14), from: t.button)) === t.close)   // Safari's place, unstyled
    call(t.button, "layout")
    #expect(root.hitTest(root.convert(NSPoint(x: 146, y: 14), from: t.button)) === t.close)
    let old = root.hitTest(root.convert(NSPoint(x: 14, y: 14), from: t.button))
    #expect(old != nil && old !== t.close && old!.isDescendant(of: t.button))
    W7SafariSetWindowThemed(w, false)
    W7SafariRestoreTabButton(t.button)
    #expect(root.hitTest(root.convert(NSPoint(x: 14, y: 14), from: t.button)) === t.close)
}

/// Safari fades its icon view out under the pointer (to show its ×): our favicon stays. A hidden icon view draws none.
@MainActor @Test func iconStaysWhileSafariFadesItsIconViewOut() {
    let keep = Keeper(), model = TabModel()
    model.active = true
    let cls: AnyClass = makeTabClass(model)
    #expect(W7SafariHookTabButton(cls))
    W7SafariFacsimileSetEnabled(true)
    defer { W7SafariFacsimileSetEnabled(false) }
    let w = makeWindow()
    W7SafariSetWindowThemed(w, true)
    defer { W7SafariSetWindowThemed(w, false) }
    let t = makeTab(cls, in: w.contentView!, keep: keep)
    t.icon.alphaValue = 0
    call(t.button, "layout")
    let fac = W7SafariFacsimileViewForButton(t.button)!
    var p = render(fac)(13, 14)
    #expect(p.r > 200 && p.b < 120, "favicon \(p)")
    t.icon.isHidden = true
    call(t.button, "layout")
    p = render(fac)(13, 14)
    #expect(!(p.r > 200 && p.b < 120), "no favicon \(p)")
}

// MARK: - the IE row laid out again when a title's width arrives or changes

/// A fake UnifiedTabBar with Safari's tab scroll view; hook b lays the IE row out after its -layout.
@MainActor private func makeBar(in w: NSWindow, keep: Keeper) -> (NSView, NSView) {
    let barClass: AnyClass = makeClass("W7FakeRelayoutTabBar", superclass: NSView.self,
        ivars: [("_visibleTabBarButtons", "@\"NSMutableSet\""), ("_scrollView", "@\"NSScrollView\""),
                ("_draggedTabButton", "@\"UnifiedTabBarButton\"")],
        methods: [("layout", "v16@0:8", { (_: AnyObject) in } as @convention(block) (AnyObject) -> Void)])
    #expect(W7SafariHookTabBar(barClass))
    let bar = (barClass as! NSView.Type).init()
    bar.frame = NSRect(x: 0, y: 0, width: 600, height: 38)
    let scroll = NSView(frame: NSRect(x: 8, y: 6, width: 584, height: 32))
    bar.addSubview(scroll)
    w.contentView!.addSubview(bar)
    let set = NSMutableSet()
    setIvar(bar, "_visibleTabBarButtons", set)
    setIvar(bar, "_scrollView", scroll)
    keep.objects += [set, scroll]
    return (bar, scroll)
}

@MainActor private func spin(_ seconds: TimeInterval) { RunLoop.main.run(until: Date(timeIntervalSinceNow: seconds)) }

/// Hook c's refresh sees a title whose width differs from the one the last IE7 pass used: one coalesced pass (at most
/// one per 100 ms per tab bar) widens the tab. A title that changes but keeps its width asks for none. Titles that
/// arrive after a launch pass that found them all unsized get the row laid out too.
@MainActor @Test func titleWidthChangeRelaysOutTheRowOnceCoalesced() {
    let keep = Keeper(), model = TabModel()
    let cls: AnyClass = makeTabClass(model)
    #expect(W7SafariHookTabButton(cls))
    W7SafariFacsimileSetEnabled(true)
    W7SafariIETabLayoutSetEnabled(true)
    defer { W7SafariFacsimileSetEnabled(false); W7SafariIETabLayoutSetEnabled(false) }
    let w = makeWindow()
    W7SafariSetWindowThemed(w, true)
    defer { W7SafariSetWindowThemed(w, false) }
    let (bar, scroll) = makeBar(in: w, keep: keep)
    let set = object_getIvar(bar, class_getInstanceVariable(object_getClass(bar), "_visibleTabBarButtons")!) as! NSMutableSet
    let a = makeTab(cls, in: scroll, keep: keep, title: "")          // at window restore: no titles yet
    let b = makeTab(cls, in: scroll, keep: keep, title: "")
    a.button.frame = NSRect(x: 0, y: 0, width: 292, height: 32)
    b.button.frame = NSRect(x: 292, y: 0, width: 292, height: 32)
    set.add(a.button); set.add(b.button)
    call(a.button, "layout"); call(b.button, "layout")
    call(bar, "layout")
    #expect(a.button.frame.width == 292 && b.button.frame.width == 292)   // deferred to Safari
    #expect(W7SafariIETabLayoutCountsFor(bar).deferred == 1)

    a.title.stringValue = "Wikipedia"                                 // the titles arrive (Safari lays each button out)
    b.title.stringValue = "Example"
    call(a.button, "layout"); call(b.button, "layout")
    #expect(a.button.frame.width == 292)                              // not at once: coalesced
    spin(0.25)
    let short = a.button.frame.width
    #expect(short >= 120 && short < 220 && b.button.frame.width >= 120)
    var counts = W7SafariIETabLayoutCountsFor(bar)
    #expect(counts.relayouts == 1 && counts.requested == 2, "\(counts)")          // two titles asked, one pass

    a.title.stringValue = String(repeating: "Wikipedia ", count: 8)  // a wider title
    call(a.button, "layout")
    for _ in 0..<5 { call(a.button, "updateBackgroundAppearance") }   // more passes do not ask again
    spin(0.25)
    #expect(a.button.frame.width == 220)
    counts = W7SafariIETabLayoutCountsFor(bar)
    #expect(counts.relayouts == 2 && counts.requested == 3, "\(counts)")

    // A different title of the same width: nothing to lay out again (a zero-width space keeps the width exactly).
    let font = a.title.font!
    let base = "Wikipedia", same = base + "\u{200B}"
    func width(_ s: String) -> CGFloat { (s as NSString).size(withAttributes: [.font: font]).width }
    #expect(same != base && abs(width(same) - width(base)) < 0.01)
    a.title.stringValue = base
    call(a.button, "layout")
    spin(0.25)
    counts = W7SafariIETabLayoutCountsFor(bar)
    #expect(counts.relayouts == 3 && a.button.frame.width == short, "\(counts)")
    a.title.stringValue = same
    call(a.button, "layout")
    spin(0.25)
    #expect(W7SafariIETabLayoutCountsFor(bar).relayouts == 3 && W7SafariIETabLayoutCountsFor(bar).requested == 4, "\(W7SafariIETabLayoutCountsFor(bar))")

    // A request while the pass cannot run (a tab is being dragged) is not lost: the next refresh asks again.
    let dragged = NSView()
    keep.objects.append(dragged)
    setIvar(bar, "_draggedTabButton", dragged)
    a.title.stringValue = String(repeating: "Wikipedia ", count: 8)
    call(a.button, "layout")
    spin(0.25)
    #expect(a.button.frame.width == short && W7SafariIETabLayoutCountsFor(bar).relayouts == 4)   // ran, could not apply
    setIvar(bar, "_draggedTabButton", nil)
    call(a.button, "updateBackgroundAppearance")                     // any refresh after the drag
    spin(0.25)
    #expect(a.button.frame.width == 220 && W7SafariIETabLayoutCountsFor(bar).relayouts == 5)
    _ = keep
}

/// A template tab icon (Safari's symbol placeholders, the Start Page star) is drawn as IE's page icon; a real favicon as
/// itself. (No ie-page.png: an empty temp asset root, whatever the user's own folder holds.)
@MainActor @Test func templateIconIsDrawnAsThePageIcon() {
    withIconRoot([:]) { _ in templateIconIsDrawnAsThePageIconBody() }
}

@MainActor private func templateIconIsDrawnAsThePageIconBody() {
    let keep = Keeper(), model = TabModel()
    model.active = true
    let cls: AnyClass = makeTabClass(model)
    #expect(W7SafariHookTabButton(cls))
    W7SafariFacsimileSetEnabled(true)
    defer { W7SafariFacsimileSetEnabled(false) }
    let w = makeWindow()
    W7SafariSetWindowThemed(w, true)
    defer { W7SafariSetWindowThemed(w, false) }
    let t = makeTab(cls, in: w.contentView!, keep: keep)
    let star = NSImage(size: NSSize(width: 16, height: 16), flipped: false) { r in NSColor.systemOrange.setFill(); r.fill(); return true }
    star.isTemplate = true
    t.icon.image = star
    call(t.button, "layout")
    let fac = W7SafariFacsimileViewForButton(t.button)!
    var px = render(fac)
    #expect(near(px(12, 17), 0xFFFFFF, 2))                                    // the page, white (icon at 6,6)
    #expect(near(px(9, 14), 0x7A8A9E, 4))                                     // its outline
    #expect(!(px(13, 14).r > 200 && px(13, 14).b < 120))                      // not the symbol's own pixels
    let favicon = NSImage(size: NSSize(width: 16, height: 16), flipped: false) { r in NSColor.systemOrange.setFill(); r.fill(); return true }
    t.icon.image = favicon
    call(t.button, "layout")
    px = render(fac)
    #expect(px(13, 14).r > 200 && px(13, 14).b < 120)                         // a real favicon as it is
}

// MARK: - the back-off is not tripped by Safari's own animations, and hover lifts it

/// Safari closing a tab animates the others wider frame by frame; each frame's stack layout puts the × back, but the
/// stack view's bounds (or the tab's width, or the ×'s own size) differ from the last re-set every time: not a fight.
/// Twenty such rounds in a second never back the move off.
@MainActor @Test func closeButtonResetsDuringAnAnimationAreNotCounted() {
    let keep = Keeper(), model = TabModel()
    model.active = true
    let cls: AnyClass = makeTabClass(model)
    #expect(W7SafariHookTabButton(cls))
    W7SafariFacsimileSetEnabled(true)
    defer { W7SafariFacsimileSetEnabled(false) }
    let w = makeWindow()
    W7SafariSetWindowThemed(w, true)
    defer { W7SafariSetWindowThemed(w, false) }
    let t = makeTab(cls, in: w.contentView!, keep: keep)
    t.content.autoresizingMask = []                                           // the stack's bounds move on their own below
    call(t.button, "layout")
    #expect(t.close.frame.minX == 138 && W7SafariCloseButtonResets(t.button) == 0)
    let left = CGRect(x: 6, y: 6, width: 16, height: 16)
    for i in 1...20 {                                                         // the stack view's bounds change each frame
        t.content.setFrameSize(NSSize(width: 160 + CGFloat(i), height: 28))
        t.close.frame = left
        #expect(t.close.frame.minX == 138 && W7SafariCloseButtonPlacementOf(t.button) == .moved, "round \(i)")
    }
    #expect(W7SafariCloseButtonResets(t.button) <= 1)
    for i in 1...20 {                                                         // the ×'s own size animates
        t.close.frame = CGRect(x: 6, y: 6, width: 16 - CGFloat(i % 2) * 0.6 - 0.6, height: 16)
        #expect(W7SafariCloseButtonPlacementOf(t.button) == .moved, "size round \(i)")
    }
    #expect(W7SafariCloseButtonResets(t.button) <= 2)
    // A true ping-pong at one size is still capped: nine re-sets in a second back off.
    t.close.frame = CGRect(x: 6, y: 6, width: 16, height: 16)
    let settled = W7SafariCloseButtonResets(t.button)
    for _ in 1...9 { t.close.frame = CGRect(x: 6, y: 6, width: 16, height: 16) }
    #expect(W7SafariCloseButtonPlacementOf(t.button) == .backedOff, "resets \(settled) → \(W7SafariCloseButtonResets(t.button))")
    W7SafariSetWindowThemed(w, false)
    W7SafariRestoreTabButton(t.button)
    #expect(t.close.frame.minX == 6)
}

/// A backed-off × (Safari's left-end frame) is put right again the moment the pointer enters that tab, so it never
/// stays at the left while the user looks at it; nine more re-sets in a second back it off again (the cap stays).
@MainActor @Test func closeButtonBackOffIsLiftedWhenThePointerEntersTheTab() {
    let keep = Keeper(), model = TabModel()
    model.active = true
    let cls: AnyClass = makeTabClass(model)
    #expect(W7SafariHookTabButton(cls))
    W7SafariFacsimileSetEnabled(true)
    defer { W7SafariFacsimileSetEnabled(false) }
    let w = makeWindow()
    W7SafariSetWindowThemed(w, true)
    defer { W7SafariSetWindowThemed(w, false) }
    let t = makeTab(cls, in: w.contentView!, keep: keep)
    call(t.button, "layout")
    let left = CGRect(x: 6, y: 6, width: 16, height: 16)
    for _ in 1...9 { t.close.frame = left }
    #expect(t.close.frame.minX == 6 && W7SafariCloseButtonPlacementOf(t.button) == .backedOff)
    let fac = W7SafariFacsimileViewForButton(t.button)!
    fac.mouseEntered(with: mouseEvent(w, at: fac.convert(NSPoint(x: 60, y: 14), to: nil)))   // the pointer enters the tab
    #expect(t.close.frame.minX == 138 && W7SafariCloseButtonPlacementOf(t.button) == .moved)
    var shown: ObjCBool = false
    #expect(W7SafariFacsimileCloseRect(t.button, fac, &shown).minX == 138)
    fac.mouseMoved(with: mouseEvent(w, at: fac.convert(NSPoint(x: 70, y: 14), to: nil)))     // moving inside lifts nothing more
    for _ in 1...9 { t.close.frame = left }                                                   // a true fight backs off again
    #expect(t.close.frame.minX == 6 && W7SafariCloseButtonPlacementOf(t.button) == .backedOff)
    fac.mouseMoved(with: mouseEvent(w, at: fac.convert(NSPoint(x: 80, y: 14), to: nil)))
    #expect(W7SafariCloseButtonPlacementOf(t.button) == .backedOff)                            // only an entry lifts it
    fac.mouseExited(with: mouseEvent(w, at: fac.convert(NSPoint(x: 300, y: 14), to: nil)))
    fac.mouseEntered(with: mouseEvent(w, at: fac.convert(NSPoint(x: 60, y: 14), to: nil)))
    #expect(t.close.frame.minX == 138 && W7SafariCloseButtonPlacementOf(t.button) == .moved)
    W7SafariSetWindowThemed(w, false)
    W7SafariRestoreTabButton(t.button)
    #expect(t.close.frame.minX == 6)
}

// MARK: - (plan "icons everywhere" ): IE's page icon from the user's ie-page.png

/// A plain coloured square PNG (synthetic; nothing from Windows).
private func squarePNG(px: Int, r: CGFloat, g: CGFloat, b: CGFloat) -> Data {
    let ctx = CGContext(data: nil, width: px, height: px, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.setFillColor(red: r, green: g, blue: b, alpha: 1)
    ctx.fill(CGRect(x: 0, y: 0, width: px, height: px))
    return NSBitmapImageRep(cgImage: ctx.makeImage()!).representation(using: .png, properties: [:])!
}

/// Runs `body` with a temp asset root holding `icons` (name → PNG) and no embedded icons; the defaults come back after.
@MainActor private func withIconRoot(_ icons: [String: Data], _ body: (URL) throws -> Void) rethrows {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("w7facsimile-icons-\(UUID().uuidString)")
    try? FileManager.default.createDirectory(at: root.appendingPathComponent("icons"), withIntermediateDirectories: true)
    for (name, png) in icons { try? png.write(to: root.appendingPathComponent("icons/\(name).png")) }
    W7UserIconsUseEmbedded([:])
    W7FolderIconUseAssetRoot(root.path)
    defer {
        W7UserIconsUseEmbedded(nil)
        W7FolderIconUseAssetRoot(nil)
        try? FileManager.default.removeItem(at: root)
    }
    try body(root)
}

/// W7IETabIconFor: a template icon becomes the user's ie-page.png (a non-template image) when it exists and stays the
/// template (Theme draws its page icon) when not; a real favicon and nil come back unchanged; the page icon is kept
/// per loader generation (the same object on every call).
@MainActor @Test func templateTabIconBecomesTheUserPageIcon() {
    let template = NSImage(size: NSSize(width: 16, height: 16), flipped: false) { r in NSColor.systemOrange.setFill(); r.fill(); return true }
    template.isTemplate = true
    let favicon = NSImage(size: NSSize(width: 16, height: 16), flipped: false) { r in NSColor.systemOrange.setFill(); r.fill(); return true }
    withIconRoot([:]) { _ in
        #expect(W7IETabIconFor(template) === template)
        #expect(W7IETabIconFor(favicon) === favicon)
        #expect(W7IETabIconFor(nil) == nil)
    }
    withIconRoot(["ie-page": squarePNG(px: 32, r: 0, g: 1, b: 0)]) { _ in
        let page = W7IETabIconFor(template)
        #expect(page != nil && page !== template && page?.isTemplate == false && page?.size == NSSize(width: 16, height: 16))
        #expect(W7IETabIconFor(template) === page, "kept until the loader resets")
        #expect(W7IETabIconFor(favicon) === favicon)
        #expect(template.isTemplate, "Safari's image is never changed")
    }
}

/// The facsimile draws ie-page.png for Safari's template placeholder, and a real favicon as itself.
@MainActor @Test func facsimileDrawsTheUserPageIconForATemplateIcon() {
    withIconRoot(["ie-page": squarePNG(px: 32, r: 0, g: 1, b: 0)]) { _ in
        let keep = Keeper(), model = TabModel()
        model.active = true
        let cls: AnyClass = makeTabClass(model)
        #expect(W7SafariHookTabButton(cls))
        W7SafariFacsimileSetEnabled(true)
        defer { W7SafariFacsimileSetEnabled(false) }
        let w = makeWindow()
        W7SafariSetWindowThemed(w, true)
        defer { W7SafariSetWindowThemed(w, false) }
        let t = makeTab(cls, in: w.contentView!, keep: keep)
        let star = NSImage(size: NSSize(width: 16, height: 16), flipped: false) { r in NSColor.systemOrange.setFill(); r.fill(); return true }
        star.isTemplate = true
        t.icon.image = star
        call(t.button, "layout")
        let fac = W7SafariFacsimileViewForButton(t.button)!
        var px = render(fac)
        let p = px(13, 14)
        #expect(p.g > 200 && p.r < 60 && p.b < 60, "the user's page icon \(p)")
        t.icon.image = NSImage(size: NSSize(width: 16, height: 16), flipped: false) { r in NSColor.systemOrange.setFill(); r.fill(); return true }
        call(t.button, "layout")
        px = render(fac)
        #expect(px(13, 14).r > 200 && px(13, 14).b < 120)                     // a real favicon as it is
        _ = keep
    }
}

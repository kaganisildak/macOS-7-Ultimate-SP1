import AppKit
import ObjectiveC
import Testing
import Win7ChromeCore

// Safari's Liquid Glass toolbar buttons tinted as IE7 through NSGlassEffectView's public API (the tabs are
// drawn by the facsimile since SafariFacsimileTests.swift). Pure models (tint table, allow-list, exclusion
// predicate) and the AppKit side on a stand-in glass view (an NSGlassEffectView subclass counting every set) inside
// run-time fake toolbar platters with AppKit's exact encodings. No window is ordered on screen.

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

/// Keeps the objects run-time ivars hold unretained alive for a test.
private final class Keeper { var objects: [AnyObject] = [] }

@MainActor private func makeWindow() -> NSWindow {
    _ = NSApplication.shared
    let w = NSWindow(contentRect: .init(x: 0, y: 0, width: 600, height: 400),
                     styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: true)
    w.isReleasedWhenClosed = false
    w.appearance = NSAppearance(named: .aqua)
    return w
}

private func hex(_ c: NSColor?) -> UInt32? {
    guard let s = c?.usingColorSpace(.sRGB) else { return nil }
    return UInt32((s.redComponent * 255).rounded()) << 16 | UInt32((s.greenComponent * 255).rounded()) << 8
        | UInt32((s.blueComponent * 255).rounded())
}

private func matches(_ c: NSColor?, _ t: W7SafariGlassTint) -> Bool {
    guard let s = c?.usingColorSpace(.sRGB) else { return false }
    return hex(c) == t.rgb && abs(s.alphaComponent - t.alpha) < 0.01
}

/// The stand-in glass: the real NSGlassEffectView (so the class checks find it), counting every set.
@available(macOS 26.0, *)
@MainActor final class W7StandInGlass: NSGlassEffectView {
    var tintSets = 0, styleSets = 0, radiusSets = 0
    override var tintColor: NSColor? { didSet { tintSets += 1 } }
    override var style: NSGlassEffectView.Style { didSet { styleSets += 1 } }
    override var cornerRadius: CGFloat { didSet { radiusSets += 1 } }
    var sets: Int { tintSets + styleSets + radiusSets }
}

@available(macOS 26.0, *)
@MainActor private func makeGlass(tint: NSColor? = .systemRed, style: NSGlassEffectView.Style = .regular, radius: CGFloat = 14) -> W7StandInGlass {
    let g = W7StandInGlass(frame: NSRect(x: 0, y: 0, width: 150, height: 26))
    g.tintColor = tint
    g.style = style
    g.cornerRadius = radius
    g.tintSets = 0; g.styleSets = 0; g.radiusSets = 0
    return g
}

// MARK: - Pure models

@Test func toolbarGlassTintTable() {
    func eq(_ t: W7SafariGlassTint, _ rgb: UInt32, _ a: CGFloat) -> Bool { t.rgb == rgb && abs(t.alpha - a) < 0.001 }
    #expect(eq(W7SafariToolbarGlassTint(false), 0xF7F9FC, 0.75))
    #expect(eq(W7SafariToolbarGlassTint(true), 0xDCE6F4, 0.90))
}

@Test func glassItemAllowList() {
    for id in ["BackForwardToolbarIdentifier", "NewTabToolbarIdentifier", "TabPickerToolbarIdentifier", "ShareToolbarIdentifier",
               "SidebarToolbarIdentifier", "CombinedSidebarTabGroupToolbarIdentifier", "ReloadPageToolbarIdentifier"] {
        #expect(W7SafariGlassItemAllowed(id), "\(id)")
    }
    for id in ["InputFieldsToolbarIdentifier", "InputFieldsWithoutButtonToolbarIdentifier", "ShowDownloadsToolbarIdentifier",
               "PrivacyReportToolbarIdentifier", "LockdownModeToolbarIdentifier", "AutoFillToolbarIdentifier",
               "PerSitePreferencesToolbarIdentifier", "com.example.extension (ABCDE12345) - Example", "UnifiedTabBarToolbarIdentifier", ""] {
        #expect(!W7SafariGlassItemAllowed(id), "\(id)")
    }
    #expect(!W7SafariGlassItemAllowed(nil))
}

@Test func glassStartsOnlyWithHooksAndWithoutKillSwitch() {
    #expect(W7SafariGlassShouldStart(true, false))
    #expect(!W7SafariGlassShouldStart(true, true))
    #expect(!W7SafariGlassShouldStart(false, false))
    #expect(!W7SafariGlassShouldStart(false, true))
}

@Test func exclusionsJudgeKVOSubclassesByTheirClass() {
    #expect(W7SafariIsExcludedClassName("NSKVONotifying_UnifiedField"))
    #expect(W7SafariIsExcludedClassName("NSKVONotifying_ToolbarDownloadsButtonView"))
    #expect(W7SafariIsExcludedClassName("PrivacyReportButtonCell") && W7SafariIsExcludedClassName("LockdownModeToolbarItemView"))
    #expect(!W7SafariIsExcludedClassName("NSKVONotifying_NSToolbarPlatterView"))
}

@MainActor @Test func exclusionPredicateOnAFakeViewTree() {
    let stubClass: AnyClass = makeClass("UnifiedFieldW7Stub", superclass: NSView.self)
    let reportClass: AnyClass = makeClass("PrivacyReportW7Stub", superclass: NSView.self)
    let toolbar = NSView(), field = NSView(), plain = NSView(), report = (reportClass as! NSView.Type).init()
    for v in [field, plain, report] { toolbar.addSubview(v) }
    let holder = NSView()
    field.addSubview(holder)
    holder.addSubview((stubClass as! NSView.Type).init())   // the address field, two levels down
    plain.addSubview(NSButton(title: "New Tab", target: nil, action: nil))
    let inReport = NSView()
    report.addSubview(inReport)

    #expect(W7SafariGlassExclusionIn(field, toolbar)?.hasPrefix("UnifiedFieldW7Stub") == true)
    #expect(W7SafariGlassExclusionIn(plain, toolbar) == nil)
    #expect(W7SafariGlassExclusionIn(inReport, toolbar)?.hasPrefix("PrivacyReportW7Stub") == true)   // an ancestor
    #expect(W7SafariGlassExclusionIn(inReport, report) == nil)                                      // stops at `stop`
    let popoverClass: AnyClass = makeClass("NSPopoverW7Frame", superclass: NSView.self)
    let popoverContent = (popoverClass as! NSView.Type).init()
    plain.addSubview(popoverContent)
    #expect(W7SafariGlassExclusionIn(plain, toolbar)?.hasPrefix("NSPopoverW7Frame") == true)
}

// MARK: - One glass view

@MainActor @Test func glassIsSnapshotStyledAndRestoredExactly() {
    guard #available(macOS 26.0, *) else { return }
    W7SafariGlassSetEnabled(true)
    defer { W7SafariGlassSetEnabled(false) }
    let red = NSColor.systemRed
    let g = makeGlass(tint: red, style: .regular, radius: 14)
    let tint = W7SafariGlassTint(rgb: 0xFFFFFF, alpha: 0.95)
    let other = W7SafariGlassTint(rgb: 0xF3F7FC, alpha: 0.88)
    #expect(!W7SafariGlassIsStyled(g))
    #expect(W7SafariGlassApply(g, tint, true, 3))
    #expect(W7SafariGlassIsStyled(g))
    #expect(matches(g.tintColor, tint) && g.style == .clear && g.cornerRadius == 3)
    #expect(g.tintSets == 1 && g.styleSets == 1 && g.radiusSets == 1)
    // Nothing changed: nothing is set again.
    #expect(W7SafariGlassApply(g, tint, true, 3))
    #expect(g.sets == 3)
    // Something else reset the style and radius (AppKit's layout): only those are set again.
    g.style = .regular; g.cornerRadius = 18
    g.tintSets = 0; g.styleSets = 0; g.radiusSets = 0
    #expect(W7SafariGlassApply(g, tint, true, 3))
    #expect(g.tintSets == 0 && g.styleSets == 1 && g.radiusSets == 1)
    // A new tint is one set.
    #expect(W7SafariGlassApply(g, other, true, 3))
    #expect(g.tintSets == 1 && matches(g.tintColor, other))

    W7SafariGlassRestore(g)
    #expect(!W7SafariGlassIsStyled(g))
    #expect(g.tintColor === red && g.style == .regular && g.cornerRadius == 14)   // the originals, exactly
    // Without a corner radius request (toolbar), the radius is never touched and so not restored either.
    let t = makeGlass(tint: nil, style: .regular, radius: 18)
    #expect(W7SafariGlassApply(t, W7SafariToolbarGlassTint(false), true, -1))
    #expect(t.radiusSets == 0 && t.cornerRadius == 18)
    W7SafariGlassRestore(t)
    #expect(t.tintColor == nil && t.style == .regular && t.radiusSets == 0)
    // A view without the glass API is left alone.
    let plain = NSView()
    #expect(!W7SafariGlassApply(plain, tint, true, 3) && !W7SafariGlassIsStyled(plain))
}

@MainActor @Test func glassKillSwitchChangesNothing() {
    let w = makeWindow()
    W7SafariSetWindowThemed(w, true)
    defer { W7SafariSetWindowThemed(w, false) }
    W7SafariGlassSetEnabled(false)
    let platter = NSView()
    #expect(W7SafariGlassStylePlatter(platter, nil) == "disabled")
    W7SafariGlassUpdateWindow(w)
    #expect(W7SafariGlassStyledCount(w) == 0)
}

// MARK: - Toolbar platters

/// A platter like AppKit's NSToolbarPlatterView: _glassView, -containedItems (item viewers answering -item) and a
/// -layout that resets its glass's style and radius (as AppKit's does).
@available(macOS 26.0, *)
@MainActor private func makePlatterClasses() -> (platter: AnyClass, viewer: AnyClass) {
    let viewer: AnyClass = makeClass("W7FakeToolbarItemViewer", superclass: NSObject.self, ivars: [("_item", "@\"NSToolbarItem\"")],
                                     methods: [("item", "@16@0:8", { (me: AnyObject) -> AnyObject? in
                                         object_getIvar(me, class_getInstanceVariable(object_getClass(me), "_item")!) as AnyObject?
                                     } as @convention(block) (AnyObject) -> AnyObject?)])
    let platter: AnyClass = makeClass("W7FakeToolbarPlatterView", superclass: NSView.self,
                                      ivars: [("_glassView", "@\"NSGlassEffectView\""), ("_containedItems", "@\"NSArray\"")],
                                      methods: [
        ("containedItems", "@16@0:8", { (me: AnyObject) -> AnyObject? in
            object_getIvar(me, class_getInstanceVariable(object_getClass(me), "_containedItems")!) as AnyObject?
        } as @convention(block) (AnyObject) -> AnyObject?),
        ("layout", "v16@0:8", { (me: AnyObject) in
            if let g = object_getIvar(me, class_getInstanceVariable(object_getClass(me), "_glassView")!) as? NSGlassEffectView {
                g.style = .regular
                g.cornerRadius = 18
            }
        } as @convention(block) (AnyObject) -> Void),
    ])
    return (platter, viewer)
}

@available(macOS 26.0, *)
@MainActor private func makePlatter(_ classes: (platter: AnyClass, viewer: AnyClass), item: String, in parent: NSView,
                                    keep: Keeper, inside: NSView? = nil) -> (NSView, W7StandInGlass) {
    let platter = (classes.platter as! NSView.Type).init()
    platter.frame = NSRect(x: 0, y: 0, width: 40, height: 36)
    let glass = makeGlass(tint: nil, style: .regular, radius: 18)
    glass.contentView = inside ?? NSButton(title: "+", target: nil, action: nil)
    platter.addSubview(glass)
    let viewer = (classes.viewer as! NSObject.Type).init()
    let toolbarItem = NSToolbarItem(itemIdentifier: NSToolbarItem.Identifier(item))
    let items = [viewer] as NSArray
    keep.objects += [glass, viewer, toolbarItem, items]
    setIvar(viewer, "_item", toolbarItem)
    setIvar(platter, "_glassView", glass)
    setIvar(platter, "_containedItems", items)
    parent.addSubview(platter)
    return (platter, glass)
}

@MainActor @Test func toolbarPlattersAreTintedUnlessExcludedOrNotAllowed() {
    guard #available(macOS 26.0, *) else { return }
    let keep = Keeper()
    let classes = makePlatterClasses()
    #expect(W7SafariHookPlatterLayout(classes.platter))
    #expect(W7SafariHookPlatterLayout(classes.platter))   // idempotent
    let w = makeWindow()
    let toolbar = NSView(frame: NSRect(x: 0, y: 0, width: 600, height: 52))
    w.contentView!.addSubview(toolbar)
    W7SafariSetWindowThemed(w, true)
    W7SafariGlassSetEnabled(true)
    defer { W7SafariGlassSetEnabled(false); W7SafariSetWindowThemed(w, false) }

    let (newTab, newTabGlass) = makePlatter(classes, item: "NewTabToolbarIdentifier", in: toolbar, keep: keep)
    let (backForward, backForwardGlass) = makePlatter(classes, item: "BackForwardToolbarIdentifier", in: toolbar, keep: keep,
                                                      inside: NSSegmentedControl(labels: ["<", ">"], trackingMode: .momentary, target: nil, action: nil))
    let stub = (makeClass("UnifiedFieldW7Stub", superclass: NSView.self) as! NSView.Type).init()
    let (address, addressGlass) = makePlatter(classes, item: "NewTabToolbarIdentifier", in: toolbar, keep: keep, inside: stub)
    let (downloads, downloadsGlass) = makePlatter(classes, item: "ShowDownloadsToolbarIdentifier", in: toolbar, keep: keep)

    #expect(W7SafariGlassStylePlatter(newTab, toolbar) == nil)
    #expect(matches(newTabGlass.tintColor, W7SafariToolbarGlassTint(false)) && newTabGlass.style == .clear)
    #expect(newTabGlass.radiusSets == 0 && newTabGlass.cornerRadius == 18)   // AppKit's radius stays
    #expect(W7SafariGlassStylePlatter(backForward, toolbar) == nil)
    #expect(matches(backForwardGlass.tintColor, W7SafariToolbarGlassTint(true)))
    // A platter holding the address field (here a UnifiedField stand-in, even under an allowed identifier): untouched.
    #expect(W7SafariGlassStylePlatter(address, toolbar)?.contains("UnifiedFieldW7Stub") == true)
    #expect(addressGlass.sets == 0)
    #expect(W7SafariGlassStylePlatter(downloads, toolbar) == "item not on the allow-list")
    #expect(downloadsGlass.sets == 0)
    #expect(W7SafariGlassStyledCount(w) == 2)

    // AppKit's platter layout resets the style; the hook puts .clear back (and only on platters styled here).
    call(newTab, "layout")
    #expect(newTabGlass.style == .clear && matches(newTabGlass.tintColor, W7SafariToolbarGlassTint(false)))
    call(downloads, "layout")
    #expect(downloadsGlass.style == .regular && downloadsGlass.tintColor == nil)

    // Un-theming: every styled glass gets Safari's values back, exactly.
    W7SafariGlassRemoveWindow(w)
    #expect(newTabGlass.tintColor == nil && newTabGlass.style == .regular && newTabGlass.cornerRadius == 18)
    #expect(backForwardGlass.tintColor == nil && backForwardGlass.style == .regular)
    #expect(W7SafariGlassStyledCount(w) == 0)
    // A platter layout after un-theming leaves it alone and forgets it.
    W7SafariSetWindowThemed(w, false)
    call(newTab, "layout")
    #expect(newTabGlass.style == .regular && newTabGlass.tintColor == nil)
}

// MARK: - The menu strip stays above the tab bar

@Test func menuStripMovesOnlyWhenNotFirst() {
    #expect(!W7SafariMenuStripNeedsMove(UInt(NSNotFound)))
    #expect(!W7SafariMenuStripNeedsMove(0))
    #expect(W7SafariMenuStripNeedsMove(1) && W7SafariMenuStripNeedsMove(3))
}

/// After a relaunch Safari's tab bar accessory can land above the menu strip (address row → tabs → menu). The
/// strip goes back to index 0, above it: address row → menu strip → tabs, IE7's order.
@MainActor @Test func menuStripIsMovedAboveTheTabBarAccessory() {
    _ = NSApplication.shared
    let w = makeWindow()
    let tabBar = NSTitlebarAccessoryViewController()
    tabBar.view = NSView(frame: NSRect(x: 0, y: 0, width: 400, height: 30))
    tabBar.layoutAttribute = .bottom
    let other = NSTitlebarAccessoryViewController()
    other.view = NSView(frame: NSRect(x: 0, y: 0, width: 400, height: 24))
    other.layoutAttribute = .bottom
    let strip = W7MenuStripController()
    w.addTitlebarAccessoryViewController(tabBar)
    w.addTitlebarAccessoryViewController(other)
    w.addTitlebarAccessoryViewController(strip)
    #expect(w.titlebarAccessoryViewControllers.firstIndex { $0 === strip } == 2)

    #expect(W7SafariEnsureMenuStripFirst(w))
    let order = w.titlebarAccessoryViewControllers
    #expect(order.count == 3 && order[0] === strip && order[1] === tabBar && order[2] === other)
    #expect(!W7SafariEnsureMenuStripFirst(w))      // already first: nothing moves
    #expect(w.titlebarAccessoryViewControllers.first === strip)

    let bare = makeWindow()                          // no strip at all: nothing to do
    bare.addTitlebarAccessoryViewController(NSTitlebarAccessoryViewController())
    #expect(!W7SafariEnsureMenuStripFirst(bare))
}

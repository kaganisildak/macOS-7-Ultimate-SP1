import AppKit
import ObjectiveC
import Testing
import Win7ChromeCore

// IE7's tab row (left-aligned, title-sized tabs within 100…180 pt, 2 pt apart, first at x 8), with the
// command bar and the 28 pt new-tab stub.

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

private func readInt(_ object: AnyObject, _ sel: String) -> Int {
    typealias F = @convention(c) (AnyObject, Selector) -> Int
    let s = sel_registerName(sel)
    return unsafeBitCast(class_getMethodImplementation(object_getClass(object), s), to: F.self)(object, s)
}

private func setInt(_ object: AnyObject, _ sel: String, _ value: Int) {
    typealias F = @convention(c) (AnyObject, Selector, Int) -> Void
    let s = sel_registerName(sel)
    unsafeBitCast(class_getMethodImplementation(object_getClass(object), s), to: F.self)(object, s, value)
}

private func setObject(_ object: AnyObject, _ sel: String, _ value: AnyObject?) {
    typealias F = @convention(c) (AnyObject, Selector, AnyObject?) -> Void
    let s = sel_registerName(sel)
    unsafeBitCast(class_getMethodImplementation(object_getClass(object), s), to: F.self)(object, s, value)
}

private final class Keeper { var objects: [AnyObject] = [] }

// MARK: - Pure layout

private func layout(_ titles: [CGFloat], start: CGFloat = 8, maxX: CGFloat = 600) -> (Bool, [CGFloat], [CGFloat]) {
    var xs = [CGFloat](repeating: -1, count: titles.count), widths = [CGFloat](repeating: -1, count: titles.count)
    let ok = W7SafariIETabLayout(titles, titles.count, start, maxX, W7SafariIETabDefaultMetrics, &xs, &widths)
    return (ok, xs, widths)
}

@Test func ieTabRowIsLeftAlignedAndTitleSized() {
    let m = W7SafariIETabDefaultMetrics
    #expect(m.minWidth == 120 && m.maxWidth == 220 && m.gap == 2 && m.padding == 76 && m.floorWidth == 100)
    // A short title gets the minimum, a long one the maximum, one in between its title plus padding.
    let (ok, xs, widths) = layout([10, 400, 90])
    #expect(ok)
    #expect(widths == [120, 220, 166])
    #expect(xs == [8, 130, 352])          // first at 8, then 2 pt gaps
    // After pinned tabs: from the given start.
    let pinned = layout([10, 10], start: 60)
    #expect(pinned.0 && pinned.1 == [60, 182])
    // No tabs: nothing to do.
    #expect(W7SafariIETabLayout(nil, 0, 8, 100, m, nil, nil))
}

@Test func ieTabRowShrinksBeforeLeavingOverflowToSafari() {
    // The live case: 4 long tabs between the Favorites group (x 128) and the command bar (802) need 4 × 220 + 6 pt.
    let (ok, xs, widths) = layout([400, 400, 400, 400], start: 128, maxX: 802)
    #expect(ok)
    #expect(widths == [167, 167, 167, 167] && xs == [128, 297, 466, 635])   // shrunk in proportion
    #expect(xs[3] + widths[3] <= 802)
    // Mixed: the shorter tab shrinks less in points, none below the 100 pt floor, and all of them fit.
    let mixed = layout([10, 400, 400, 400], start: 8, maxX: 480)
    #expect(mixed.0 && mixed.2.allSatisfy { $0 >= 100 } && mixed.2[0] <= mixed.2[1])
    #expect(mixed.1[3] + mixed.2[3] <= 480)
    let floored = layout([400, 10, 10], start: 0, maxX: 304)          // two at the floor, the long one takes the rest
    #expect(floored.0 && floored.2[1] == 100 && floored.2[2] == 100 && floored.2[0] >= 100 && floored.1[2] + floored.2[2] <= 304)
    // Not even at the floor (12 × 100 + 11 × 2 > 1092): nothing written, Safari's layout and scrolling stay.
    let (over, overXs, _) = layout([CGFloat](repeating: 400, count: 12), start: 8, maxX: 1100)
    #expect(!over)
    #expect(overXs.allSatisfy { $0 == -1 })
}

/// a pass that sees every title unsized (intrinsic width 0: the fields are empty or not yet sized at window
/// restore) must not freeze every tab at the floor: it defers to Safari's widths; one sized title is enough to lay out.
@Test func layoutDefersToSafariWhileEveryTitleIsUnsized() {
    let m = W7SafariIETabDefaultMetrics
    var xs = [CGFloat](repeating: -1, count: 3), widths = [CGFloat](repeating: -1, count: 3)
    #expect(W7SafariIETabLayoutDecide([0, 0, 0], 3, 8, 600, m, &xs, &widths) == .titlesUnsized)
    #expect(xs.allSatisfy { $0 == -1 } && widths.allSatisfy { $0 == -1 })          // nothing written
    #expect(W7SafariIETabLayoutDecide([0, 50, 0], 3, 8, 600, m, &xs, &widths) == .applied)
    #expect(widths == [120, 126, 120] && xs == [8, 130, 258])
    #expect(W7SafariIETabLayoutDecide([CGFloat](repeating: 400, count: 12), 12, 8, 1100, m, nil, nil) == .overflow)
    #expect(W7SafariIETabLayoutDecide(nil, 0, 8, 600, m, nil, nil) == .applied)     // no tabs: nothing to defer
    #expect(W7SafariIETabRelayoutInterval == 0.1)
}

// MARK: - Re-framing Safari's tab buttons (hook b)

/// Safari's own hover model: what its `-_tabBarButtonAtPoint:` answers from its layout, and how often it
/// re-resolved the highlighted tab (`-_updateHighlightedTabBarButton`).
private final class HoverModel { var answer: NSView?; var highlightUpdates = 0 }

@MainActor private func makeTabBar(keep: Keeper, safariLayouts: UnsafeMutablePointer<Int>, hover: HoverModel = HoverModel()) -> (AnyClass, AnyClass) {
    let buttonClass: AnyClass = makeClass("W7FakeRowTabButton", superclass: NSView.self,
        ivars: [("_titleTextField", "@\"NSTextField\""), ("_pinned", "@\"NSNumber\"")],
        methods: [("isPinned", "B16@0:8", { (me: AnyObject) -> Bool in
            (object_getIvar(me, class_getInstanceVariable(object_getClass(me), "_pinned")!) as? NSNumber)?.boolValue ?? false
        } as @convention(block) (AnyObject) -> Bool)])
    // Safari's own layout: equal widths across the row inside the scroll view (as on Safari 26/27).
    let relayout: @convention(block) (AnyObject, Bool) -> Void = { me, _ in
        safariLayouts.pointee += 1
        let set = object_getIvar(me, class_getInstanceVariable(object_getClass(me), "_visibleTabBarButtons")!) as! NSMutableSet
        let buttons = (set.allObjects as! [NSView]).sorted { $0.frame.minX < $1.frame.minX }
        let width = 584 / CGFloat(max(1, buttons.count))
        for (i, b) in buttons.enumerated() { b.frame = NSRect(x: CGFloat(i) * width, y: 0, width: width, height: 32) }
    }
    let barClass: AnyClass = makeClass("W7FakeRowTabBar", superclass: NSView.self,
        ivars: [("_visibleTabBarButtons", "@\"NSMutableSet\""), ("_scrollView", "@\"NSScrollView\""),
                ("_draggedTabButton", "@\"UnifiedTabBarButton\"")],
        methods: [("layout", "v16@0:8", { (_: AnyObject) in } as @convention(block) (AnyObject) -> Void),
                  ("_layoutButtonsAnimated:", "v20@0:8B16", relayout),
                  // Safari resolves the pointer from its own layout model: a fixed answer stands in for it.
                  ("_tabBarButtonAtPoint:", "@32@0:8{CGPoint=dd}16", { (_: AnyObject, _: CGPoint) -> AnyObject? in hover.answer } as @convention(block) (AnyObject, CGPoint) -> AnyObject?),
                  ("_updateHighlightedTabBarButton", "v16@0:8", { (_: AnyObject) in hover.highlightUpdates += 1 } as @convention(block) (AnyObject) -> Void)])
    return (barClass, buttonClass)
}

/// Safari's `-_tabBarButtonAtPoint:` as hooked (called through the class's IMP, as Safari calls it on every mouse move).
@MainActor private func buttonAt(_ bar: AnyObject, _ p: CGPoint) -> NSView? {
    typealias F = @convention(c) (AnyObject, Selector, CGPoint) -> AnyObject?
    let s = sel_registerName("_tabBarButtonAtPoint:")
    return unsafeBitCast(class_getMethodImplementation(object_getClass(bar), s), to: F.self)(bar, s, p) as? NSView
}

// MARK: - the hovered tab from OUR frames

/// Live: Safari answered the hovered tab from its own layout model (its frames: 8…343 / 345…680 / …), so
/// the × showed on the tab whose SAFARI frame held the pointer. While the IE7 layout is applied, the answer is the
/// visible button whose real frame holds the point (a button Safari re-parented into its backdrop container included),
/// nil between tabs and in the left margin (where our ★ group sits); Safari's own answer when the layout is not ours (un-themed, dragging);
/// Safari's highlight is re-resolved once after a pass that moved buttons; the diagnostics count both paths.
@MainActor @Test func hoveredTabFollowsOurFramesAfterTheIE7Pass() {
    _ = NSApplication.shared
    let keep = Keeper(), hover = HoverModel()
    let safariLayouts = UnsafeMutablePointer<Int>.allocate(capacity: 1)
    safariLayouts.pointee = 0
    defer { safariLayouts.deallocate() }
    let (barClass, buttonClass): (AnyClass, AnyClass) = makeTabBar(keep: keep, safariLayouts: safariLayouts, hover: hover)
    #expect(W7SafariHookTabBar(barClass))
    #expect(W7SafariHookTabBarButtonAtPoint(barClass))                   // idempotent
    let w = NSWindow(contentRect: .init(x: 0, y: 0, width: 640, height: 300), styleMask: [.titled], backing: .buffered, defer: true)
    w.isReleasedWhenClosed = false
    let bar = (barClass as! NSView.Type).init()
    bar.frame = NSRect(x: 0, y: 0, width: 600, height: 38)
    let scroll = NSView(frame: NSRect(x: 8, y: 6, width: 584, height: 32))
    bar.addSubview(scroll)
    w.contentView!.addSubview(bar)
    let set = NSMutableSet()
    setIvar(bar, "_visibleTabBarButtons", set)
    setIvar(bar, "_scrollView", scroll)
    var buttons: [NSView] = []
    for (i, title) in ["A", "B", "C"].enumerated() {
        let b = (buttonClass as! NSView.Type).init()
        b.frame = NSRect(x: CGFloat(i) * 194, y: 0, width: 194, height: 32)   // Safari: equal widths filling the row
        let field = NSTextField(labelWithString: title)
        b.addSubview(field)
        setIvar(b, "_titleTextField", field)
        scroll.addSubview(b)
        set.add(b)
        buttons.append(b)
        keep.objects += [b, field]
    }
    keep.objects += [set, scroll]
    hover.answer = buttons[0]                                            // Safari's model: tab 1 wherever we ask
    W7SafariIETabLayoutSetEnabled(true)
    defer { W7SafariIETabLayoutSetEnabled(false) }

    #expect(buttonAt(bar, CGPoint(x: 200, y: 20)) === buttons[0])       // not themed: Safari's answer
    W7SafariSetWindowThemed(w, true)
    call(bar, "layout")
    #expect(buttons.map { bar.convert($0.frame, from: $0.superview).minX } == [8, 130, 252])   // 120 wide, 2 pt apart
    #expect(hover.highlightUpdates == 1)                                 // the highlight re-resolved once after the pass
    call(bar, "layout")
    #expect(hover.highlightUpdates == 1)                                 // nothing moved: not again
    #expect(buttonAt(bar, CGPoint(x: 60, y: 20)) === buttons[0])
    #expect(buttonAt(bar, CGPoint(x: 200, y: 20)) === buttons[1])       // Safari's model said tab 1
    #expect(buttonAt(bar, CGPoint(x: 4, y: 20)) == nil)                 // the left margin (where ★ sits in Safari): no tab
    #expect(buttonAt(bar, CGPoint(x: 129, y: 20)) == nil)               // the 2 pt gap between two tabs (8…128, 130…250)
    buttons[1].isHidden = true
    #expect(buttonAt(bar, CGPoint(x: 200, y: 20)) == nil)               // a hidden button never answers
    buttons[1].isHidden = false
    // Safari moves the selected tab into its backdrop container (another superview): its real frame still counts.
    let backdrop = NSView(frame: NSRect(x: 200, y: 6, width: 400, height: 32))
    bar.addSubview(backdrop)
    keep.objects.append(backdrop)
    let inBar = bar.convert(buttons[2].frame, from: scroll)
    buttons[2].removeFromSuperview()
    buttons[2].frame = backdrop.convert(inBar, from: bar)
    backdrop.addSubview(buttons[2])
    #expect(buttonAt(bar, CGPoint(x: 300, y: 20)) === buttons[2])
    setIvar(bar, "_draggedTabButton", buttons[0])                         // a drag: Safari's layout and Safari's answer
    #expect(buttonAt(bar, CGPoint(x: 200, y: 20)) === buttons[0])
    setIvar(bar, "_draggedTabButton", nil)
    // Six answered from our frames, one (the drag) passed to Safari; the un-themed call above preceded any row state.
    #expect(W7SafariIETabLayoutDiagnostics(bar).contains("hover: _tabBarButtonAtPoint: hooked (6 answered by frames, 1 passed to Safari)"),
            "\(W7SafariIETabLayoutDiagnostics(bar))")
    W7SafariSetWindowThemed(w, false)
    call(bar, "layout")
    #expect(buttonAt(bar, CGPoint(x: 200, y: 20)) === buttons[0])       // un-themed: Safari's answer again
    _ = keep
}

/// A `-_tabBarButtonAtPoint:` with another encoding is left alone (Safari's own answer), reported once.
@MainActor @Test func hoverHookRefusesAnotherEncoding() {
    let model = HoverModel()
    let cls: AnyClass = makeClass("W7FakeHoverBadBar", superclass: NSView.self,
        methods: [("_tabBarButtonAtPoint:", "@24@0:8@16", { (_: AnyObject, _: AnyObject?) -> AnyObject? in model.answer } as @convention(block) (AnyObject, AnyObject?) -> AnyObject?)])
    #expect(!W7SafariHookTabBarButtonAtPoint(cls))
    #expect(!W7SafariHookTabBarButtonAtPoint(nil))
    #expect(W7SafariIETabLayoutDiagnostics((cls as! NSView.Type).init()).contains("hover: _tabBarButtonAtPoint: not hooked"))
}

@MainActor @Test func hookBReframesTabsToTheIERowAndGivesSafarisBack() {
    _ = NSApplication.shared
    let keep = Keeper()
    let safariLayouts = UnsafeMutablePointer<Int>.allocate(capacity: 1)
    safariLayouts.pointee = 0
    defer { safariLayouts.deallocate() }
    let (barClass, buttonClass): (AnyClass, AnyClass) = makeTabBar(keep: keep, safariLayouts: safariLayouts)
    #expect(W7SafariHookTabBar(barClass))
    let w = NSWindow(contentRect: .init(x: 0, y: 0, width: 640, height: 300), styleMask: [.titled], backing: .buffered, defer: true)
    w.isReleasedWhenClosed = false
    let bar = (barClass as! NSView.Type).init()
    bar.frame = NSRect(x: 0, y: 0, width: 600, height: 38)
    let scroll = NSView(frame: NSRect(x: 8, y: 6, width: 584, height: 32))
    bar.addSubview(scroll)
    w.contentView!.addSubview(bar)
    let set = NSMutableSet()
    setIvar(bar, "_visibleTabBarButtons", set)
    setIvar(bar, "_scrollView", scroll)
    var buttons: [NSView] = []
    for (i, title) in ["A", String(repeating: "Wikipedia ", count: 8), "Başlangıç Sayfası"].enumerated() {
        let b = (buttonClass as! NSView.Type).init()
        b.frame = NSRect(x: CGFloat(i) * 194, y: 0, width: 194, height: 32)   // Safari: equal widths filling the row
        let field = NSTextField(labelWithString: title)
        b.addSubview(field)
        setIvar(b, "_titleTextField", field)
        scroll.addSubview(b)
        set.add(b)
        buttons.append(b)
        keep.objects += [b, field]
    }
    keep.objects += [set, scroll]
    let titleWidth = buttons[2].subviews[0].intrinsicContentSize.width
    W7SafariIETabLayoutSetEnabled(true)
    defer { W7SafariIETabLayoutSetEnabled(false) }

    call(bar, "layout")   // not themed: Safari's equal widths stay
    #expect(buttons.map(\.frame.width) == [194, 194, 194])

    W7SafariSetWindowThemed(w, true)
    call(bar, "layout")
    let inBar = buttons.map { bar.convert($0.frame, from: $0.superview) }
    #expect(inBar.map(\.minX) == [8, 130, 352])
    #expect(inBar[0].width == 120 && inBar[1].width == 220)
    #expect(abs(inBar[2].width - max(120, min(220, ceil(titleWidth + 76)))) < 0.5)
    #expect(inBar.allSatisfy { $0.minY == 6 && $0.height == 32 })   // heights and rows stay Safari's
    let frames = buttons.map(\.frame)
    call(bar, "layout")                                               // nothing changed: nothing set
    #expect(buttons.map(\.frame) == frames)

    // Un-theming asks Safari to lay its row out again.
    let before = safariLayouts.pointee
    W7SafariSetWindowThemed(w, false)
    call(bar, "layout")
    #expect(safariLayouts.pointee == before + 1)
    #expect(buttons.map(\.frame.width).allSatisfy { abs($0 - 584.0 / 3) < 0.5 })
    _ = keep
}

@MainActor @Test func hookBLeavesOverflowAndPinnedTabsToSafari() {
    _ = NSApplication.shared
    let keep = Keeper()
    let safariLayouts = UnsafeMutablePointer<Int>.allocate(capacity: 1)
    safariLayouts.pointee = 0
    defer { safariLayouts.deallocate() }
    let (barClass, buttonClass): (AnyClass, AnyClass) = makeTabBar(keep: keep, safariLayouts: safariLayouts)
    #expect(W7SafariHookTabBar(barClass))
    let w = NSWindow(contentRect: .init(x: 0, y: 0, width: 640, height: 300), styleMask: [.titled], backing: .buffered, defer: true)
    w.isReleasedWhenClosed = false
    let bar = (barClass as! NSView.Type).init()
    bar.frame = NSRect(x: 0, y: 0, width: 600, height: 38)
    let scroll = NSView(frame: NSRect(x: 8, y: 6, width: 584, height: 32))
    bar.addSubview(scroll)
    w.contentView!.addSubview(bar)
    let set = NSMutableSet()
    setIvar(bar, "_visibleTabBarButtons", set)
    setIvar(bar, "_scrollView", scroll)
    keep.objects += [set, scroll]
    func add(_ title: String, x: CGFloat, width: CGFloat, pinned: Bool = false) -> NSView {
        let b = (buttonClass as! NSView.Type).init()
        b.frame = NSRect(x: x, y: 0, width: width, height: 32)
        let field = NSTextField(labelWithString: title)
        b.addSubview(field)
        setIvar(b, "_titleTextField", field)
        if pinned { setIvar(b, "_pinned", NSNumber(value: true)); keep.objects.append(NSNumber(value: true)) }
        scroll.addSubview(b)
        set.add(b)
        keep.objects += [b, field]
        return b
    }
    W7SafariIETabLayoutSetEnabled(true)
    W7SafariSetWindowThemed(w, true)
    defer { W7SafariIETabLayoutSetEnabled(false); W7SafariSetWindowThemed(w, false) }

    // A pinned tab stays where Safari put it; ours start after it.
    let pin = add("P", x: 0, width: 40, pinned: true)
    let tab = add("A", x: 40, width: 544)
    call(bar, "layout")
    #expect(pin.frame == NSRect(x: 0, y: 0, width: 40, height: 32))
    #expect(bar.convert(tab.frame, from: scroll).minX == 8 + 40 + 2 && tab.frame.width == 120)

    // Four long tabs: shrunk in proportion so they fit, not left to Safari.
    set.removeAllObjects()
    let long = String(repeating: "Wikipedia ", count: 8)
    let four = (0..<4).map { add(long, x: CGFloat($0) * 146, width: 146) }
    call(bar, "layout")
    let fourWidth = four.map(\.frame.width)
    #expect(fourWidth.allSatisfy { $0 >= 100 && $0 < 146 } && Set(fourWidth).count == 1)
    // Too many for the row even at the 100 pt floor: Safari's layout (and its scrolling) stays.
    set.removeAllObjects()
    let many = (0..<6).map { add(long, x: CGFloat($0) * 97, width: 97) }
    call(bar, "layout")
    #expect(many.map(\.frame.width).allSatisfy { abs($0 - 584.0 / 6) < 0.5 })   // Safari laid them out again, its way
}

/// A title that fits under the cap is never truncated: when Safari's own button layout truncates it, the tab learns
/// the chrome around the title (button width minus title width) and grows by what the title lacked.
@MainActor @Test func hookBGrowsATabUntilSafariShowsItsWholeTitle() {
    _ = NSApplication.shared
    let keep = Keeper()
    let safariLayouts = UnsafeMutablePointer<Int>.allocate(capacity: 1)
    safariLayouts.pointee = 0
    defer { safariLayouts.deallocate() }
    let (barClass, _): (AnyClass, AnyClass) = makeTabBar(keep: keep, safariLayouts: safariLayouts)
    // Safari's button: 100 pt of icon, close button and insets around the title, which is truncated to what is left.
    let buttonClass: AnyClass = makeClass("W7FakeTruncatingTabButton", superclass: NSView.self,
        ivars: [("_titleTextField", "@\"NSTextField\"")],
        methods: [("layout", "v16@0:8", { (me: AnyObject) in
            let b = me as! NSView
            guard let t = object_getIvar(me, class_getInstanceVariable(object_getClass(me), "_titleTextField")!) as? NSTextField else { return }
            t.frame = NSRect(x: 50, y: 8, width: max(0, min(t.intrinsicContentSize.width, b.bounds.width - 100)), height: 16)
        } as @convention(block) (AnyObject) -> Void)])
    #expect(W7SafariHookTabBar(barClass))
    let w = NSWindow(contentRect: .init(x: 0, y: 0, width: 640, height: 300), styleMask: [.titled], backing: .buffered, defer: true)
    w.isReleasedWhenClosed = false
    let bar = (barClass as! NSView.Type).init()
    bar.frame = NSRect(x: 0, y: 0, width: 600, height: 38)
    let scroll = NSView(frame: NSRect(x: 8, y: 6, width: 584, height: 32))
    bar.addSubview(scroll)
    w.contentView!.addSubview(bar)
    let set = NSMutableSet()
    setIvar(bar, "_visibleTabBarButtons", set)
    setIvar(bar, "_scrollView", scroll)
    var tabs: [(NSView, NSTextField)] = []
    for (i, title) in ["Başlangıç Sayfası", String(repeating: "Wikipedia ", count: 8)].enumerated() {
        let b = (buttonClass as! NSView.Type).init()
        b.frame = NSRect(x: CGFloat(i) * 292, y: 0, width: 292, height: 32)
        let field = NSTextField(labelWithString: title)
        b.addSubview(field)
        setIvar(b, "_titleTextField", field)
        scroll.addSubview(b)
        set.add(b)
        tabs.append((b, field))
        keep.objects += [b, field]
    }
    keep.objects += [set, scroll]
    W7SafariIETabLayoutSetEnabled(true)
    W7SafariSetWindowThemed(w, true)
    defer { W7SafariIETabLayoutSetEnabled(false); W7SafariSetWindowThemed(w, false) }

    call(bar, "layout")
    let (short, shortTitle) = tabs[0]
    let need = shortTitle.intrinsicContentSize.width
    #expect(abs(short.frame.width - ceil(need + 100)) < 0.5)    // grown past the 76 pt guess to Safari's 100
    #expect(shortTitle.frame.width + 0.5 >= need)                // the whole title shows
    #expect(tabs[1].0.frame.width == 220)                        // a title longer than the cap: the cap
    _ = keep
}

// MARK: - launch with unsized titles; late separators

/// At window restore the first pass finds every title empty: Safari's frames stay (counted as deferred), and the pass
/// after the titles arrive lays the IE row out.
@MainActor @Test func firstPassWithEmptyTitlesKeepsSafarisFramesUntilTitlesArrive() {
    _ = NSApplication.shared
    let keep = Keeper()
    let safariLayouts = UnsafeMutablePointer<Int>.allocate(capacity: 1)
    safariLayouts.pointee = 0
    defer { safariLayouts.deallocate() }
    let (barClass, buttonClass): (AnyClass, AnyClass) = makeTabBar(keep: keep, safariLayouts: safariLayouts)
    #expect(W7SafariHookTabBar(barClass))
    let w = NSWindow(contentRect: .init(x: 0, y: 0, width: 640, height: 300), styleMask: [.titled], backing: .buffered, defer: true)
    w.isReleasedWhenClosed = false
    let bar = (barClass as! NSView.Type).init()
    bar.frame = NSRect(x: 0, y: 0, width: 600, height: 38)
    let scroll = NSView(frame: NSRect(x: 8, y: 6, width: 584, height: 32))
    bar.addSubview(scroll)
    w.contentView!.addSubview(bar)
    let set = NSMutableSet()
    setIvar(bar, "_visibleTabBarButtons", set)
    setIvar(bar, "_scrollView", scroll)
    keep.objects += [set, scroll]
    var tabs: [(NSView, NSTextField)] = []
    for i in 0..<3 {
        let b = (buttonClass as! NSView.Type).init()
        b.frame = NSRect(x: CGFloat(i) * 194, y: 0, width: 194, height: 32)
        let field = NSTextField(labelWithString: "")                 // not restored yet
        b.addSubview(field)
        setIvar(b, "_titleTextField", field)
        scroll.addSubview(b)
        set.add(b)
        tabs.append((b, field))
        keep.objects += [b, field]
    }
    W7SafariIETabLayoutSetEnabled(true)
    W7SafariSetWindowThemed(w, true)
    defer { W7SafariIETabLayoutSetEnabled(false); W7SafariSetWindowThemed(w, false) }
    call(bar, "layout")
    #expect(tabs.map(\.0.frame.width) == [194, 194, 194])            // Safari's own widths, not the floor
    var counts = W7SafariIETabLayoutCountsFor(bar)
    #expect(counts.deferred == 1 && counts.passes == 0)
    for (i, title) in ["A", String(repeating: "Wikipedia ", count: 8), "Başlangıç Sayfası"].enumerated() {
        tabs[i].1.stringValue = title
        tabs[i].1.sizeToFit()                                        // as Safari's button layout sizes its field
    }
    call(bar, "layout")
    let inBar = tabs.map { bar.convert($0.0.frame, from: scroll) }
    #expect(inBar.map(\.minX) == [8, 130, 352] && inBar[0].width == 120 && inBar[1].width == 220)
    counts = W7SafariIETabLayoutCountsFor(bar)
    #expect(counts.deferred == 1 && counts.passes == 1)
    _ = keep
}

/// Safari's -_layoutButtonsAnimated: creates a tab's separator after hook b's last -layout pass: it would show at
/// Safari's own tab boundary inside our tab. Our pass after it zeroes it as -layout does.
@MainActor @Test func separatorCreatedBySafarisButtonLayoutIsKeptInvisible() {
    _ = NSApplication.shared
    let keep = Keeper()
    let separatorClass: AnyClass = makeClass("W7FakeLateSeparator", superclass: NSView.self, methods: [
        ("setSeparatorAlphaValue:", "v24@0:8d16", { (me: AnyObject, a: Double) in (me as! NSView).alphaValue = a } as @convention(block) (AnyObject, Double) -> Void)])
    let map = NSMapTable<AnyObject, AnyObject>.strongToStrongObjects()
    let relayout: @convention(block) (AnyObject, Bool) -> Void = { me, _ in
        let bar = me as! NSView
        let set = object_getIvar(me, class_getInstanceVariable(object_getClass(me), "_visibleTabBarButtons")!) as! NSMutableSet
        let buttons = (set.allObjects as! [NSView]).sorted { $0.frame.minX < $1.frame.minX }
        let width = 584 / CGFloat(max(1, buttons.count))
        for (i, b) in buttons.enumerated() {
            b.frame = NSRect(x: CGFloat(i) * width, y: 0, width: width, height: 32)
            if map.object(forKey: b) == nil {                         // a separator per tab, visible, at Safari's boundary
                let s = (separatorClass as! NSView.Type).init(frame: NSRect(x: CGFloat(i + 1) * width - 1, y: 6, width: 1, height: 20))
                s.alphaValue = 1
                bar.addSubview(s)
                map.setObject(s, forKey: b)
            }
        }
    }
    let barClass: AnyClass = makeClass("W7FakeSeparatorTabBar", superclass: NSView.self,
        ivars: [("_visibleTabBarButtons", "@\"NSMutableSet\""), ("_scrollView", "@\"NSScrollView\""),
                ("_tabBarItemsToTabBarButtonSeparators", "@\"NSMapTable\"")],
        methods: [("layout", "v16@0:8", { (_: AnyObject) in } as @convention(block) (AnyObject) -> Void),
                  ("_layoutButtonsAnimated:", "v20@0:8B16", relayout)])
    #expect(W7SafariHookTabBar(barClass))
    #expect(W7SafariHookTabBarButtonLayout(barClass))                // hooked for this class too (not only the first)
    let w = NSWindow(contentRect: .init(x: 0, y: 0, width: 640, height: 300), styleMask: [.titled], backing: .buffered, defer: true)
    w.isReleasedWhenClosed = false
    let bar = (barClass as! NSView.Type).init()
    bar.frame = NSRect(x: 0, y: 0, width: 600, height: 38)
    let scroll = NSView(frame: NSRect(x: 8, y: 6, width: 584, height: 32))
    bar.addSubview(scroll)
    w.contentView!.addSubview(bar)
    let set = NSMutableSet()
    setIvar(bar, "_visibleTabBarButtons", set)
    setIvar(bar, "_scrollView", scroll)
    setIvar(bar, "_tabBarItemsToTabBarButtonSeparators", map)
    keep.objects += [set, scroll, map]
    for i in 0..<2 {
        let b = NSView(frame: NSRect(x: CGFloat(i) * 292, y: 0, width: 292, height: 32))
        scroll.addSubview(b)
        set.add(b)
        keep.objects.append(b)
    }
    W7SafariIETabLayoutSetEnabled(true)
    W7SafariSetWindowThemed(w, true)
    defer { W7SafariIETabLayoutSetEnabled(false); W7SafariSetWindowThemed(w, false) }
    call(bar, "layout")                                               // hook b: no separators yet
    #expect(map.count == 0)
    typealias F = @convention(c) (AnyObject, Selector, Bool) -> Void
    let sel = sel_registerName("_layoutButtonsAnimated:")
    unsafeBitCast(class_getMethodImplementation(barClass, sel), to: F.self)(bar, sel, false)   // Safari creates them here
    #expect(map.count == 2)
    for s in map.objectEnumerator()!.allObjects as! [NSView] { #expect(s.alphaValue == 0 && !s.isHidden) }
    _ = keep
}

// MARK: - Separators outside hook b's table; the verbose tab bar dump

/// A fake UnifiedTabBar with separators held every way Safari might: hook b's table, a tab bar ivar, an array ivar, a
/// button's own ivar, the backdrop's tab container and the scroll view's document view. Only views whose class name
/// contains "Separator" are touched.
@MainActor private func makeSeparatorBar(keep: Keeper) -> (bar: NSView, separators: [NSView], others: [NSView], field: NSTextField) {
    // Safari's UnifiedTabBarSeparator (the live dump): -setSeparatorAlphaValue: fades only a 1×16 sliver subview; the
    // separator itself and its full-height opaque backdrop keep alpha 1.
    let settable: AnyClass = makeClass("FakeTabButtonSeparatorA", superclass: NSView.self, methods: [
        ("setSeparatorAlphaValue:", "v24@0:8d16", { (me: AnyObject, a: Double) in (me as! NSView).subviews.last?.alphaValue = a } as @convention(block) (AnyObject, Double) -> Void)])
    let plain: AnyClass = makeClass("FakeTabSeparatorB", superclass: NSView.self)
    let buttonClass: AnyClass = makeClass("FakeHoldingTabButton", superclass: NSView.self,
        ivars: [("_trailingSeparator", "@\"FakeTabSeparatorB\""), ("_titleTextField", "@\"NSTextField\"")])
    let barClass: AnyClass = makeClass("FakeStorageTabBar", superclass: NSView.self,
        ivars: [("_visibleTabBarButtons", "@\"NSMutableSet\""), ("_scrollView", "@\"NSScrollView\""),
                ("_tabBarItemsToTabBarButtonSeparators", "@\"NSMapTable\""), ("_leadingSeparator", "@\"FakeTabSeparatorB\""),
                ("_separatorViews", "@\"NSArray\""), ("_tabContainer", "@\"NSView\""), ("_dividerCount", "q")],
        methods: [("layout", "v16@0:8", { (_: AnyObject) in } as @convention(block) (AnyObject) -> Void)])
    #expect(W7SafariHookTabBar(barClass))
    let bar = (barClass as! NSView.Type).init(frame: NSRect(x: 0, y: 0, width: 600, height: 38))
    let scroll = NSScrollView(frame: NSRect(x: 8, y: 6, width: 584, height: 32))
    let document = NSView(frame: NSRect(x: 0, y: 0, width: 584, height: 32))
    scroll.documentView = document
    bar.addSubview(scroll)
    let container = NSView(frame: NSRect(x: 8, y: 6, width: 584, height: 32))
    bar.addSubview(container)
    let set = NSMutableSet()
    let button = (buttonClass as! NSView.Type).init(frame: NSRect(x: 0, y: 0, width: 292, height: 32))
    document.addSubview(button)
    set.add(button)
    let field = NSTextField(labelWithString: "Secret Page Title")
    button.addSubview(field)
    setIvar(button, "_titleTextField", field)
    func sep(_ cls: AnyClass, x: CGFloat, in parent: NSView) -> NSView {
        let s = (cls as! NSView.Type).init(frame: NSRect(x: x, y: 0, width: 1, height: 32))
        parent.addSubview(s)
        return s
    }
    let inTable = sep(settable, x: 100, in: document), leading = sep(plain, x: 0, in: document)
    let backdrop = NSView(frame: NSRect(x: 0, y: 0, width: 1, height: 32)), sliver = NSView(frame: NSRect(x: 0, y: 8, width: 1, height: 16))
    inTable.addSubview(backdrop)
    inTable.addSubview(sliver)                                           // the setter's target
    inTable.alphaValue = 0.9                                             // Safari's own value, to be put back exactly
    let inArray = [sep(plain, x: 200, in: document), sep(plain, x: 300, in: document)]
    let ofButton = sep(plain, x: 291, in: button), inContainer = sep(plain, x: 292, in: container)
    let other = NSView(frame: NSRect(x: 400, y: 0, width: 1, height: 32))
    container.addSubview(other)
    let map = NSMapTable<AnyObject, AnyObject>.strongToStrongObjects()
    map.setObject(inTable, forKey: button)
    let array: NSArray = [inArray[0], inArray[1], other]                // a non-separator in the array is left alone
    setIvar(bar, "_visibleTabBarButtons", set)
    setIvar(bar, "_scrollView", scroll)
    setIvar(bar, "_tabBarItemsToTabBarButtonSeparators", map)
    setIvar(bar, "_leadingSeparator", leading)
    setIvar(bar, "_separatorViews", array)
    setIvar(bar, "_tabContainer", container)
    setIvar(button, "_trailingSeparator", ofButton)
    keep.objects += [bar, scroll, document, container, set, button, field, inTable, leading, ofButton, inContainer, other, map, array, backdrop, sliver] + inArray
    return (bar, [inTable, leading, ofButton, inContainer] + inArray, [other, button, container, document], field)
}

@MainActor @Test func zeroTabSeparatorsCoversEverySeparatorStorageAndRestores() {
    _ = NSApplication.shared
    let keep = Keeper()
    let (bar, separators, others, _) = makeSeparatorBar(keep: keep)
    let w = NSWindow(contentRect: .init(x: 0, y: 0, width: 640, height: 300), styleMask: [.titled], backing: .buffered, defer: true)
    w.isReleasedWhenClosed = false
    w.contentView!.addSubview(bar)
    W7SafariZeroTabSeparators(bar)
    #expect(separators.allSatisfy { $0.alphaValue == 0 && !$0.isHidden })   // the separator itself, setter or not
    #expect(separators[0].subviews.last?.alphaValue == 0)                  // and Safari's setter still called
    #expect(others.allSatisfy { $0.alphaValue == 1 && !$0.isHidden })
    W7SafariRestoreTabBar(bar)
    #expect(separators[0].alphaValue == 0.9 && separators.dropFirst().allSatisfy { $0.alphaValue == 1 })   // the alphas found
    // Through hook b in a themed window, and left alone once un-themed.
    W7SafariSetWindowThemed(w, true)
    call(bar, "layout")
    #expect(separators.allSatisfy { $0.alphaValue == 0 } && others.allSatisfy { $0.alphaValue == 1 })
    separators[1].alphaValue = 0.5                                   // Safari's own change after our pass
    W7SafariSetWindowThemed(w, false)
    call(bar, "layout")
    #expect(separators[1].alphaValue == 0.5 && separators[2].alphaValue == 1 && separators[3].alphaValue == 1)
    _ = keep
}

/// The verbose dump: every view of the tab bar subtree with class, frame, alpha, hidden and layer flags; separators say
/// which ivar or table holds them; the separator/divider/line ivars of the tab bar and button classes are listed by
/// name and value class; never a title.
@MainActor @Test func tabBarDumpNamesSeparatorHoldersAndNeverText() {
    _ = NSApplication.shared
    let keep = Keeper()
    let (bar, _, _, field) = makeSeparatorBar(keep: keep)
    bar.addTrackingArea(NSTrackingArea(rect: NSRect(x: 0, y: 0, width: 100, height: 20), options: [.mouseMoved, .activeAlways], owner: bar))
    let lines = W7SafariTabBarDump(bar)
    #expect(lines.count > 8 && lines.count <= 160)
    // Method names, geometry ivars and tracking areas (names only).
    let barClass = NSStringFromClass(type(of: bar))
    #expect(lines.contains { $0.hasPrefix("methods of \(barClass) (") })
    #expect(lines.contains { $0.contains("geometry ivar _visibleTabBarButtons (@") })
    #expect(lines.contains { $0.hasPrefix("tracking area of the tab bar (\(barClass)): rect (0,0 100x20) options 0x82 mouseMoved activeAlways owner \(barClass)") })
    #expect(lines.contains { $0.hasPrefix("tracking areas of the tab scroll view") || $0.hasPrefix("tracking area of the tab scroll view") })
    #expect(lines.contains { $0.hasPrefix("tracking areas of tab button 0") || $0.hasPrefix("tracking area of tab button 0") })
    let first = lines.first ?? ""
    #expect(first.hasPrefix(NSStringFromClass(type(of: bar))) && first.contains("(0,0 600x38)") && first.contains("alpha=1"))
    #expect(lines.contains { $0.contains("FakeTabSeparatorB") && $0.contains("held by _leadingSeparator") })
    #expect(lines.contains { $0.contains("held by _tabBarItemsToTabBarButtonSeparators") })
    #expect(lines.contains { $0.contains("held by _separatorViews[") })
    #expect(lines.contains { $0.contains("held by _trailingSeparator") })
    #expect(lines.contains { $0.contains("ivar _leadingSeparator") && $0.contains("FakeTabSeparatorB") })
    #expect(lines.contains { $0.contains("ivar _dividerCount") })
    #expect(lines.contains { $0.contains("ivar _trailingSeparator") })
    #expect(!lines.contains { $0.contains(field.stringValue) || $0.contains("Secret") })
    #expect(lines.contains { $0.contains("NSTextField") })                    // the view is listed, not its text
    _ = keep
}

// MARK: - The selected tab's glass

private func readObject(_ object: AnyObject, _ sel: String) -> AnyObject? {
    typealias F = @convention(c) (AnyObject, Selector) -> AnyObject?
    let s = sel_registerName(sel)
    return unsafeBitCast(class_getMethodImplementation(object_getClass(object), s), to: F.self)(object, s)
}

/// A main menu holding only Safari's Bookmarks sidebar item: ★ Favorites resolves, every other command stays hidden.
@MainActor private func bookmarksSidebarOnlyMenu() -> NSMenu {
    let main = NSMenu(title: "Main"), view = NSMenu(title: "View")
    view.addItem(NSMenuItem(title: "Show Bookmarks Sidebar", action: NSSelectorFromString("toggleBookmarksSidebar:"), keyEquivalent: ""))
    let holder = NSMenuItem(title: "View", action: nil, keyEquivalent: "")
    holder.submenu = view
    main.addItem(holder)
    return main
}

/// with the command bar on, the ★ Favorites group takes the tab row's left (the tabs start after it), the
/// blank new-tab stub follows the last tab, and Safari's own items it could not find (a main menu holding only the
/// Bookmarks sidebar item here; resolves ★ through the menu) stay hidden.
@MainActor @Test func commandBarGroupAndStubFrameTheTabs() {
    _ = NSApplication.shared
    let keep = Keeper()
    W7SafariCommandBarSetMainMenu(bookmarksSidebarOnlyMenu())
    defer { W7SafariCommandBarSetMainMenu(nil) }
    let safariLayouts = UnsafeMutablePointer<Int>.allocate(capacity: 1)
    safariLayouts.pointee = 0
    defer { safariLayouts.deallocate() }
    let (barClass, buttonClass): (AnyClass, AnyClass) = makeTabBar(keep: keep, safariLayouts: safariLayouts)
    #expect(W7SafariHookTabBar(barClass))
    let w = NSWindow(contentRect: .init(x: 0, y: 0, width: 640, height: 300), styleMask: [.titled], backing: .buffered, defer: true)
    w.isReleasedWhenClosed = false
    let bar = (barClass as! NSView.Type).init()
    bar.frame = NSRect(x: 0, y: 0, width: 600, height: 38)
    let scroll = NSView(frame: NSRect(x: 8, y: 6, width: 584, height: 32))
    bar.addSubview(scroll)
    w.contentView!.addSubview(bar)
    let set = NSMutableSet()
    setIvar(bar, "_visibleTabBarButtons", set)
    setIvar(bar, "_scrollView", scroll)
    let tab = (buttonClass as! NSView.Type).init()
    tab.frame = NSRect(x: 0, y: 0, width: 584, height: 32)
    let field = NSTextField(labelWithString: "A")
    tab.addSubview(field)
    setIvar(tab, "_titleTextField", field)
    scroll.addSubview(tab)
    set.add(tab)
    keep.objects += [set, scroll, tab, field]
    W7SafariIETabLayoutSetEnabled(true)
    W7SafariCommandBarSetEnabled(true)
    W7SafariSetWindowThemed(w, true)
    defer { W7SafariIETabLayoutSetEnabled(false); W7SafariCommandBarSetEnabled(false) }

    call(bar, "layout")
    let ours = bar.subviews.filter { NSStringFromClass(type(of: $0)).contains("CommandButton") }
    #expect(ours.count == 2)                                         // ★ Favorites and the stub (no menus here)
    let favorites = ours.min { $0.frame.minX < $1.frame.minX }!
    #expect(favorites.frame.minX == 8)
    let tabFrame = bar.convert(tab.frame, from: scroll)
    #expect(tabFrame.minX >= favorites.frame.maxX + 4)               // the tabs after the group
    let stub = ours.max { $0.frame.minX < $1.frame.minX }!
    #expect(stub.frame.minX == tabFrame.maxX + 2 && stub.frame.width == 28 && !stub.isHidden)

    W7SafariSetWindowThemed(w, false)                                // un-theming takes them away again
    call(bar, "layout")
    #expect(!bar.subviews.contains { NSStringFromClass(type(of: $0)).contains("CommandButton") })
    _ = keep
}

/// More tabs than fit at the floor with the command bar on: Safari's own layout runs inside the room between
/// the Favorites group and the stub's room (its scroll view narrowed to it, Safari's frame back afterwards), and no
/// control of ours is drawn over a tab.
@MainActor @Test func overflowReservesTheRoomBetweenTheGroupAndTheCommandBar() {
    _ = NSApplication.shared
    let keep = Keeper()
    let safariLayouts = UnsafeMutablePointer<Int>.allocate(capacity: 1)
    safariLayouts.pointee = 0
    defer { safariLayouts.deallocate() }
    let (barClass, buttonClass): (AnyClass, AnyClass) = makeTabBar(keep: keep, safariLayouts: safariLayouts)
    #expect(W7SafariHookTabBar(barClass))
    let w = NSWindow(contentRect: .init(x: 0, y: 0, width: 640, height: 300), styleMask: [.titled], backing: .buffered, defer: true)
    w.isReleasedWhenClosed = false
    let bar = (barClass as! NSView.Type).init()
    bar.frame = NSRect(x: 0, y: 0, width: 600, height: 38)
    let scroll = NSView(frame: NSRect(x: 8, y: 6, width: 584, height: 32))
    bar.addSubview(scroll)
    w.contentView!.addSubview(bar)
    let set = NSMutableSet()
    setIvar(bar, "_visibleTabBarButtons", set)
    setIvar(bar, "_scrollView", scroll)
    keep.objects += [set, scroll]
    for i in 0..<6 {
        let b = (buttonClass as! NSView.Type).init()
        b.frame = NSRect(x: CGFloat(i) * 97, y: 0, width: 97, height: 32)
        let field = NSTextField(labelWithString: String(repeating: "Wikipedia ", count: 8))
        b.addSubview(field)
        setIvar(b, "_titleTextField", field)
        scroll.addSubview(b)
        set.add(b)
        keep.objects += [b, field]
    }
    W7SafariIETabLayoutSetEnabled(true)
    W7SafariCommandBarSetEnabled(true)
    W7SafariCommandBarSetMainMenu(bookmarksSidebarOnlyMenu())
    W7SafariSetWindowThemed(w, true)
    defer { W7SafariIETabLayoutSetEnabled(false); W7SafariCommandBarSetEnabled(false); W7SafariCommandBarSetMainMenu(nil) }

    let before = safariLayouts.pointee
    call(bar, "layout")
    let favorites = bar.subviews.filter { NSStringFromClass(type(of: $0)).contains("CommandButton") }.min { $0.frame.minX < $1.frame.minX }!
    #expect(scroll.frame.minX >= favorites.frame.maxX)          // Safari's tabs start after the group…
    #expect(scroll.frame.maxX <= 600 - 8 - 30)                   // …and end before the stub's room
    #expect(safariLayouts.pointee > before)                      // Safari laid its tabs out inside it
    let tabs = (set.allObjects as! [NSView]).map { bar.convert($0.frame, from: $0.superview).insetBy(dx: 1, dy: 1) }
    let ours = bar.subviews.filter { NSStringFromClass(type(of: $0)).contains("CommandButton") && !$0.isHidden }
    #expect(!ours.contains { o in tabs.contains { $0.intersects(o.frame) } })   // nothing of ours over a tab

    W7SafariSetWindowThemed(w, false)                            // un-theming: Safari's scroll view back
    call(bar, "layout")
    #expect(scroll.frame == NSRect(x: 8, y: 6, width: 584, height: 32))
    _ = keep
}

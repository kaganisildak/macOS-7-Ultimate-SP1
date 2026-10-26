import AppKit
import Testing
import Win7ChromeCore

// and the Windows 7 command-bar look for every app toolbar. The band is painted
// behind the toolbar view, every Liquid Glass platter is tinted through NSGlassEffectView's public API and covered by
// an opaque plate under its item views, and each plain button gets a flat Windows 7 hover/pressed face below it.
// Items, their order, labels, images, actions, visibility and custom views are never changed. Real AppKit toolbars
// on windows that are never ordered on screen.

@MainActor private final class ToolbarFixture: NSObject, NSToolbarDelegate {
    static let ids: [NSToolbarItem.Identifier] = [
        .init("img"), .init("btn"), .flexibleSpace, .init("grp"), .init("search"), .init("popup"),
    ]
    let toolbar = NSToolbar(identifier: "w7.test.toolbarlook.\(UUID().uuidString)")
    let window: NSWindow

    init(decorate: Bool = true, dark: Bool = false) {
        _ = NSApplication.shared
        window = NSWindow(contentRect: .init(x: 0, y: 0, width: 720, height: 400),
                          styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: true)
        super.init()
        window.isReleasedWhenClosed = false
        window.title = "Secret Document Title"
        window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        toolbar.delegate = self
        toolbar.autosavesConfiguration = false
        window.toolbar = toolbar
        if decorate { W7ChromeController.decorateWindow(window) }
        window.layoutIfNeeded()
        window.displayIfNeeded()
    }

    @objc func act(_ sender: Any?) {}

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] { Self.ids }
    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] { Self.ids }
    func toolbar(_ toolbar: NSToolbar, itemForItemIdentifier id: NSToolbarItem.Identifier,
                 willBeInsertedIntoToolbar flag: Bool) -> NSToolbarItem? {
        switch id.rawValue {
        case "img":
            let item = NSToolbarItem(itemIdentifier: id)
            item.label = "Delete"
            item.image = NSImage(systemSymbolName: "trash", accessibilityDescription: nil)
            item.target = self
            item.action = #selector(act(_:))
            return item
        case "btn":
            let item = NSToolbarItem(itemIdentifier: id)
            item.label = "Favourite"
            let b = NSButton(image: NSImage(systemSymbolName: "star", accessibilityDescription: nil)!, target: self,
                             action: #selector(act(_:)))
            b.bezelStyle = .texturedRounded
            item.view = b
            return item
        case "grp":
            return NSToolbarItemGroup(itemIdentifier: id, titles: ["A", "B"], selectionMode: .selectOne, labels: ["A", "B"],
                                      target: self, action: #selector(act(_:)))
        case "search":
            return NSSearchToolbarItem(itemIdentifier: id)
        case "popup":
            let item = NSToolbarItem(itemIdentifier: id)
            item.label = "View"
            let p = NSPopUpButton(frame: .init(x: 0, y: 0, width: 80, height: 24), pullsDown: false)
            p.addItems(withTitles: ["One", "Two"])
            item.view = p
            return item
        default:
            return nil
        }
    }

    func close() { window.close() }
}

/// AppKit's toolbar view: the title bar view's child whose class name ends in "ToolbarView".
@MainActor private func toolbarView(_ w: NSWindow) -> NSView? {
    w.standardWindowButton(.closeButton)?.superview?.subviews.first { NSStringFromClass(type(of: $0)).hasSuffix("ToolbarView") }
}

@MainActor private func views<T: NSView>(_ type: T.Type, under v: NSView?) -> [T] {
    guard let v else { return [] }
    var out: [T] = []
    if let t = v as? T { out.append(t) }
    for s in v.subviews { out += views(type, under: s) }
    return out
}

@MainActor private func named(_ prefix: String, _ w: NSWindow) -> [NSView] {
    views(NSView.self, under: w.standardWindowButton(.closeButton)?.superview).filter {
        NSStringFromClass(type(of: $0)).hasPrefix(prefix)
    }
}

@MainActor private func faces(_ w: NSWindow) -> [NSView] { named("W7ToolbarButtonFace", w) }
@MainActor private func plates(_ w: NSWindow) -> [NSView] { named("W7ToolbarPlate", w) }

@MainActor private func bandPainter(_ w: NSWindow) -> W7TitlebarBandPainter? {
    W7TitlebarBandPainterForIdentifier(w, W7ToolbarLookBandPainterIdentifier)
}

/// Every item's identity and what the look must never change, in toolbar order.
private struct ItemRecord: Equatable {
    let id: String, view: ObjectIdentifier?, image: ObjectIdentifier?, label: String, bordered: Bool
    let action: Selector?, viewBordered: Bool?, viewBezel: UInt?, hidden: Bool?
}

@MainActor private func itemRecords(_ t: NSToolbar) -> [ItemRecord] {
    t.items.map { item in
        let b = item.view as? NSButton
        return ItemRecord(id: item.itemIdentifier.rawValue, view: item.view.map(ObjectIdentifier.init),
                          image: item.image.map(ObjectIdentifier.init), label: item.label, bordered: item.isBordered,
                          action: item.action, viewBordered: b?.isBordered, viewBezel: b.map { $0.bezelStyle.rawValue },
                          hidden: item.view?.isHidden)
    }
}

/// Every NSButton AppKit shows in the toolbar view (its own NSToolbarButtons included): border, bezel, image, action.
private struct ButtonRecord: Equatable {
    let button: ObjectIdentifier, bordered: Bool, bezel: UInt, image: ObjectIdentifier?, action: Selector?, hidden: Bool
}

@MainActor private func buttonRecords(_ w: NSWindow) -> [ButtonRecord] {
    views(NSButton.self, under: toolbarView(w)).map {
        ButtonRecord(button: ObjectIdentifier($0), bordered: $0.isBordered, bezel: $0.bezelStyle.rawValue,
                     image: $0.image.map(ObjectIdentifier.init), action: $0.action, hidden: $0.isHidden)
    }
}

/// Every control in the toolbar view and its frame in the window.
@MainActor private func controlFrames(_ w: NSWindow) -> [NSRect] {
    views(NSControl.self, under: toolbarView(w)).map { $0.convert($0.bounds, to: nil) }
}

@MainActor private func glassViews(_ w: NSWindow) -> [NSView] {
    guard let cls = NSClassFromString("NSGlassEffectView") else { return [] }
    return views(NSView.self, under: toolbarView(w)).filter { $0.isKind(of: cls) }
}

@MainActor private func visibleGlass(_ w: NSWindow) -> [NSView] { glassViews(w).filter { !$0.isHiddenOrHasHiddenAncestor } }

/// A glass view's public settings (tint identity, style, corner radius), read by key (the class is macOS 26+).
private struct GlassSettings: Equatable { let tint: NSColor?, style: Int, radius: Double }
@MainActor private func glassSettings(_ g: NSView) -> GlassSettings {
    GlassSettings(tint: g.value(forKey: "tintColor") as? NSColor, style: (g.value(forKey: "style") as? Int) ?? -1,
                  radius: (g.value(forKey: "cornerRadius") as? Double) ?? -1)
}

/// A tint as sRGB hex and alpha in hundredths.
private struct Tint: Equatable { let rgb: UInt32, alpha: Int }
@MainActor private func tint(_ g: NSView) -> Tint? {
    guard let c = (g.value(forKey: "tintColor") as? NSColor)?.usingColorSpace(.sRGB) else { return nil }
    let rgb = UInt32((c.redComponent * 255).rounded()) << 16 | UInt32((c.greenComponent * 255).rounded()) << 8 |
        UInt32((c.blueComponent * 255).rounded())
    return Tint(rgb: rgb, alpha: Int((c.alphaComponent * 100).rounded()))
}

/// The look's values on a platter glass: the command bar's middle (white for the search field), clear, radius 3.
@MainActor private func expectApplied(_ g: NSView, sourceLocation: SourceLocation = #_sourceLocation) {
    let search = !views(NSSearchField.self, under: g).isEmpty
    let s = glassSettings(g)
    #expect(tint(g) == (search ? Tint(rgb: 0xFFFFFF, alpha: 90) : Tint(rgb: 0xE9F0F8, alpha: 80)),
            "tint \(String(describing: tint(g)))", sourceLocation: sourceLocation)
    #expect(s.style == 1 && abs(s.radius - 3) < 0.01, "style \(s.style) radius \(s.radius)", sourceLocation: sourceLocation)
}

/// Runs the main run loop's default mode for `seconds` (the look's coalesced re-apply runs there).
private func spin(_ seconds: CFTimeInterval = 0.05) { _ = CFRunLoopRunInMode(.defaultMode, seconds, false) }
private func spin(_ mode: RunLoop.Mode, _ seconds: CFTimeInterval = 0.03) {
    _ = CFRunLoopRunInMode(CFRunLoopMode(mode.rawValue as CFString), seconds, false)
}

/// A 1x sRGB bitmap of `view`'s bounds, drawn by `body` with the view's coordinates (non-flipped).
private struct Bitmap {
    let rep: NSBitmapImageRep
    func rgb(_ x: CGFloat, _ y: CGFloat) -> UInt32 {   // y from the bottom
        guard let c = rep.colorAt(x: Int(x), y: rep.pixelsHigh - 1 - Int(y))?.usingColorSpace(.sRGB) else { return 0 }
        return UInt32((c.redComponent * 255).rounded()) << 16 | UInt32((c.greenComponent * 255).rounded()) << 8 |
            UInt32((c.blueComponent * 255).rounded())
    }
    var isBlank: Bool {
        for y in 0..<rep.pixelsHigh { for x in 0..<rep.pixelsWide where (rep.colorAt(x: x, y: y)?.alphaComponent ?? 0) > 0.01 { return false } }
        return true
    }
}

@MainActor private func render(_ view: NSView, _ body: (CGContext) -> Void) -> Bitmap {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: max(1, Int(view.bounds.width)),
                               pixelsHigh: max(1, Int(view.bounds.height)), bitsPerSample: 8, samplesPerPixel: 4,
                               hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    let ctx = NSGraphicsContext(bitmapImageRep: rep)!
    NSGraphicsContext.current = ctx
    body(ctx.cgContext)
    NSGraphicsContext.restoreGraphicsState()
    return Bitmap(rep: rep)
}

private func near(_ a: UInt32, _ b: UInt32, _ d: Int = 3) -> Bool {
    [16, 8, 0].allSatisfy { abs(Int((a >> UInt32($0)) & 0xFF) - Int((b >> UInt32($0)) & 0xFF)) <= d }
}

@MainActor private func ids(_ items: [NSToolbarItem]) -> [ObjectIdentifier] { items.map(ObjectIdentifier.init) }

@Suite(.serialized) @MainActor struct ToolbarLookTests {
    // MARK: Decision

    @Test func bundlesThatKeepTheirOwnToolbars() {
        #expect(!W7ToolbarLookAppliesToBundle("com.apple.Safari"))
        #expect(!W7ToolbarLookAppliesToBundle("com.apple.finder"))
        #expect(!W7ToolbarLookAppliesToBundle("com.win7mac.shell"))
        #expect(W7ToolbarLookAppliesToBundle("com.apple.Notes"))
        #expect(W7ToolbarLookAppliesToBundle("com.apple.helpviewer"))
        #expect(W7ToolbarLookAppliesToBundle(nil))   // the test runner has none
    }

    @Test func appliesSkipsTable() {
        let f = ToolbarFixture()
        defer { f.close() }
        #expect(W7ToolbarLookApplies("com.apple.Notes", f.window, false))
        #expect(W7ToolbarLookApplies(nil, f.window, false))
        #expect(!W7ToolbarLookApplies("com.apple.Notes", f.window, true), "kill switch")
        #expect(!W7ToolbarLookApplies("com.apple.Safari", f.window, false), "Safari keeps W7SafariGlass")
        #expect(!W7ToolbarLookApplies("com.apple.finder", f.window, false), "Finder has the Explorer bars")
        #expect(!W7ToolbarLookApplies("com.win7mac.shell", f.window, false), "the shell")
        #expect(!W7ToolbarLookApplies("com.apple.Notes", nil, false))
        f.toolbar.displayMode = .labelOnly
        if f.toolbar.displayMode == .labelOnly {   // macOS 27 does not take .labelOnly here (seen in this test)
            #expect(!W7ToolbarLookApplies("com.apple.Notes", f.window, false), "label-only toolbars have no buttons to restyle")
        }
        f.toolbar.displayMode = .default

        let undecorated = ToolbarFixture(decorate: false)
        defer { undecorated.close() }
        #expect(!W7ToolbarLookApplies("com.apple.Notes", undecorated.window, false), "only windows with the Aero caption")

        let plain = NSWindow(contentRect: .init(x: 0, y: 0, width: 300, height: 200), styleMask: [.titled, .closable],
                             backing: .buffered, defer: true)
        plain.isReleasedWhenClosed = false
        defer { plain.close() }
        W7ChromeController.decorateWindow(plain)
        #expect(!W7ToolbarLookApplies("com.apple.Notes", plain, false), "no toolbar")
    }

    @Test func killSwitchOverride() {
        W7ToolbarLookUseDisabledOverride(1)
        #expect(W7ToolbarLookDisabled())
        W7ToolbarLookUseDisabledOverride(0)
        #expect(!W7ToolbarLookDisabled())
        W7ToolbarLookUseDisabledOverride(-1)
    }

    @Test func glassTintsAreTheCommandBarsMiddleAndTheSearchBoxWhite() {
        let t = W7ToolbarLookGlassTint()
        #expect(t.rgb == 0xE9F0F8 && abs(t.alpha - 0.80) < 0.001)
        let s = W7ToolbarLookSearchGlassTint()
        #expect(s.rgb == 0xFFFFFF && abs(s.alpha - 0.90) < 0.001)
    }

    // MARK: Apply and restore

    @Test func applyTintsEveryPlatterAndFacesPlainButtonsOnly() throws {
        let f = ToolbarFixture()
        defer { f.close() }
        let tv = try #require(toolbarView(f.window), "decorated window has a toolbar view")
        #expect(bandPainter(f.window) == nil)
        W7ToolbarLookApply(f.window)
        #expect(W7ToolbarLookIsApplied(f.window))
        #expect(bandPainter(f.window) != nil, "the command-bar band behind the toolbar")
        // The image item (AppKit's NSToolbarButton) and the custom NSButton get faces; the group, search field and
        // pop-up do not.
        #expect(W7ToolbarLookButtonCount(f.window) == 2)
        #expect(faces(f.window).count == 2)
        let custom = try #require(f.toolbar.items.first { $0.itemIdentifier.rawValue == "btn" }?.view as? NSButton)
        let face = try #require(faces(f.window).first { custom.isDescendant(of: $0.superview!) })
        let container = try #require(face.superview)
        #expect(face.frame == container.convert(custom.bounds, from: custom), "the face sits exactly under its button")
        let anchor = try #require(container.subviews.first { custom.isDescendant(of: $0) })
        #expect(container.subviews.firstIndex(of: face)! + 1 == container.subviews.firstIndex(of: anchor)!,
                "just below the view holding the button, never over it")
        #expect(face.hitTest(NSPoint(x: face.frame.midX, y: face.frame.midY)) == nil, "click-through")
        let search = try #require(views(NSSearchField.self, under: tv).first)
        #expect(!faces(f.window).contains { search.isDescendant(of: $0.superview!) }, "the search field gets no face")
        if !glassViews(f.window).isEmpty {   // macOS 26+: Liquid Glass platters
            // every visible platter is tinted (the tint is the platter's, the controls are untouched); the
            // search field's platter white like the Windows 7 search box, the others the command bar's middle.
            let visible = visibleGlass(f.window)
            #expect(visible.count >= 4, "image, button, group, search (and the pop-up)")
            #expect(visible.allSatisfy { W7SafariGlassIsStyled($0) })
            #expect(W7ToolbarLookGlassCount(f.window) == visible.count)
            for g in visible { expectApplied(g) }
            #expect(visible.contains { search.isDescendant(of: $0) } && visible.contains { custom.isDescendant(of: $0) })
        }
    }

    /// item 3: AppKit resets a platter glass's style and radius when it lays the platter out (seen on macOS
    /// 27); the look observes the three public properties and puts its values back on the next run-loop pass.
    @Test func appliedGlassValuesSurviveAPlatterLayout() throws {
        let f = ToolbarFixture()
        defer { f.close() }
        let frames = controlFrames(f.window)
        W7ToolbarLookApply(f.window)
        let visible = visibleGlass(f.window)
        let titlebar = try #require(f.window.standardWindowButton(.closeButton)?.superview)
        for g in visible { g.superview?.needsLayout = true; g.needsLayout = true }
        titlebar.layoutSubtreeIfNeeded()
        f.window.displayIfNeeded()
        spin()
        for g in visible { expectApplied(g) }
        // Re-applying does not start a layout ↔ re-apply loop (which would hit the per-second cap and leave AppKit's).
        for _ in 0..<3 { titlebar.layoutSubtreeIfNeeded(); f.window.displayIfNeeded(); spin(0.1) }
        for g in visible { expectApplied(g) }
        // the plates moved no control, not even on AppKit's next layout pass (review-task-69 item 2).
        #expect(controlFrames(f.window) == frames, "no control moved after layout, display and a run-loop pass")
        #expect(W7ToolbarLookPlateCount(f.window) == visible.count, "the plates stay in")
        for g in visible { #expect(NSStringFromClass(type(of: (g.value(forKey: "contentView") as! NSView).subviews.first!)).hasPrefix("W7ToolbarPlate")) }
    }

    @Test func glassValuesResetFromOutsideAreReappliedUntilRestore() throws {
        let f = ToolbarFixture()
        defer { f.close() }
        W7ToolbarLookApply(f.window)
        guard let g = visibleGlass(f.window).first else { return }   // before macOS 26: no glass
        g.setValue(0, forKey: "style")
        g.setValue(14.0, forKey: "cornerRadius")
        g.setValue(nil, forKey: "tintColor")
        spin()
        expectApplied(g)
        W7ToolbarLookRestore(f.window)
        let restored = glassSettings(g)
        g.setValue(restored.style == 1 ? 0 : 1, forKey: "style")
        spin()
        #expect(glassSettings(g).style != restored.style, "nothing re-applied once restored")
    }

    @Test func reapplyingIsCappedPerSecond() throws {
        let f = ToolbarFixture()
        defer { f.close() }
        W7ToolbarLookApply(f.window)
        guard let g = visibleGlass(f.window).first else { return }
        for _ in 0..<30 {   // something resetting the glass on every pass: the look gives up for now
            g.setValue(0, forKey: "style")
            spin(0.005)
        }
        #expect(glassSettings(g).style == 0, "re-applying paused")
        W7ToolbarLookApply(f.window)   // the next full update (key change, toolbar change) starts again
        expectApplied(g)
        g.setValue(0, forKey: "style")
        spin()
        expectApplied(g)
    }

    /// item 2: an opaque plate, the first subview of each tinted platter's glass contentView, hides the pill
    /// and its sheen under the item views; it draws the band's own slice, so it joins the band without a seam.
    @Test func platesCoverEveryTintedPlatterWithoutMovingAControl() throws {
        let f = ToolbarFixture()
        defer { f.close() }
        let tv = try #require(toolbarView(f.window))
        let frames = controlFrames(f.window), items = itemRecords(f.toolbar), buttons = buttonRecords(f.window)
        W7ToolbarLookApply(f.window)
        #expect(controlFrames(f.window) == frames, "no control moved")
        #expect(itemRecords(f.toolbar) == items && buttonRecords(f.window) == buttons)
        let visible = visibleGlass(f.window)
        guard !visible.isEmpty else { return }
        #expect(plates(f.window).count == visible.count)
        #expect(W7ToolbarLookPlateCount(f.window) == visible.count)
        let search = try #require(views(NSSearchField.self, under: tv).first)
        let titlebar = try #require(f.window.standardWindowButton(.closeButton)?.superview)
        let band = render(titlebar) { ctx in bandPainter(f.window)?.w7DrawBands(inTitlebarView: titlebar, window: f.window, context: ctx) }
        for g in visible {
            let content = try #require(g.value(forKey: "contentView") as? NSView)
            let plate = try #require(content.subviews.first)
            #expect(NSStringFromClass(type(of: plate)).hasPrefix("W7ToolbarPlate"), "first, under every item view")
            #expect(plate.frame == content.bounds)
            #expect(plate.hitTest(NSPoint(x: plate.frame.midX, y: plate.frame.midY)) == nil, "click-through")
            let mid = render(plate) { _ in plate.draw(plate.bounds) }.rgb(plate.bounds.midX, plate.bounds.midY)
            if search.isDescendant(of: g) {
                #expect(near(mid, 0xFFFFFF), "the search box is white \(String(mid, radix: 16))")
            } else {
                let p = titlebar.convert(NSPoint(x: plate.bounds.midX, y: plate.bounds.midY), from: plate)
                let want = band.rgb(p.x, p.y)
                #expect(near(mid, want), "the band's slice: \(String(mid, radix: 16)) vs \(String(want, radix: 16))")
            }
        }
        W7ToolbarLookRestore(f.window)
        #expect(plates(f.window).isEmpty)
        #expect(controlFrames(f.window) == frames)
    }

    @Test func plateIsRefusedWhereTheContainerWouldMoveItsViews() throws {
        final class Shuffling: NSView {
            override func didAddSubview(_ v: NSView) {
                super.didAddSubview(v)
                for s in subviews where s !== v { s.frame.origin.x += 5 }
            }
        }
        let calm = NSView(frame: .init(x: 0, y: 0, width: 60, height: 28))
        let child = NSView(frame: .init(x: 4, y: 2, width: 20, height: 20))
        calm.addSubview(child)
        let plate = try #require(W7ToolbarLookInsertPlate(calm, nil, false))
        #expect(calm.subviews.first === plate && plate.frame == calm.bounds && child.frame.origin.x == 4)
        #expect(W7ToolbarLookInsertPlate(calm, nil, false) === plate, "one plate per container")
        #expect(calm.subviews.count == 2)

        let moving = Shuffling(frame: .init(x: 0, y: 0, width: 60, height: 28))
        let other = NSView(frame: .init(x: 4, y: 2, width: 20, height: 20))
        moving.addSubview(other)
        other.frame.origin.x = 4
        #expect(W7ToolbarLookInsertPlate(moving, nil, false) == nil, "a plate that moves the controls is not kept")
        #expect(moving.subviews == [other] && other.frame.origin.x == 4, "and the views are back where they were")
    }

    /// (review-task-69 item 1): a container that moves its children in `layout` (Auto Layout, a stack) does
    /// so on its next layout pass, after `addSubview:` returns; the plate is checked after a forced layout too.
    @Test func plateIsRefusedWhereTheContainerMovesItsViewsOnItsNextLayout() throws {
        final class Stacking: NSView {   // lays every subview out left to right, from x 4, on each layout pass
            override func didAddSubview(_ v: NSView) { super.didAddSubview(v); needsLayout = true }
            override func layout() {
                super.layout()
                var x: CGFloat = 4
                for s in subviews { s.frame.origin.x = x; x += s.frame.width + 2 }
            }
        }
        let stack = Stacking(frame: .init(x: 0, y: 0, width: 200, height: 28))
        let a = NSView(frame: .init(x: 4, y: 2, width: 20, height: 20))
        let b = NSView(frame: .init(x: 26, y: 2, width: 20, height: 20))
        stack.addSubview(a)
        stack.addSubview(b)
        stack.layoutSubtreeIfNeeded()
        #expect(a.frame.origin.x == 4 && b.frame.origin.x == 26)
        #expect(W7ToolbarLookInsertPlate(stack, nil, false) == nil, "the plate would move the views on the next layout")
        #expect(stack.subviews == [a, b], "the plate is gone")
        #expect(a.frame.origin.x == 4 && b.frame.origin.x == 26, "and the views are back where they were")
        stack.layoutSubtreeIfNeeded()
        #expect(a.frame.origin.x == 4 && b.frame.origin.x == 26, "and stay there")
    }

    /// (review-task-69 item 3): AppKit rebuilds a platter's contentView (the search field expanding or
    /// collapsing) or inserts a view under everything; the plate is put back first on the next re-apply pass.
    @Test func platesComeBackAfterAContentViewSwapOrAViewInsertedBelow() throws {
        let f = ToolbarFixture()
        defer { f.close() }
        W7ToolbarLookApply(f.window)
        let visible = visibleGlass(f.window)
        guard let g = visible.first else { return }   // before macOS 26: no glass
        func content() -> NSView? { g.value(forKey: "contentView") as? NSView }
        func plateFirst() -> Bool {
            content()?.subviews.first.map { NSStringFromClass(type(of: $0)).hasPrefix("W7ToolbarPlate") } ?? false
        }
        #expect(plateFirst())
        let frames = controlFrames(f.window)

        // A view AppKit inserts below everything, then a platter layout (it resets the glass's style).
        let below = NSView(frame: content()?.bounds ?? .zero)
        content()?.addSubview(below, positioned: .below, relativeTo: nil)
        #expect(!plateFirst())
        g.setValue(0, forKey: "style")
        spin()
        #expect(plateFirst(), "the plate is first again")
        #expect(content()?.subviews.dropFirst().first === below, "the inserted view stays, above the plate")
        below.removeFromSuperview()

        // A new contentView holding the old one's item views.
        let old = try #require(content())
        let fresh = NSView(frame: old.frame)
        for v in old.subviews where !NSStringFromClass(type(of: v)).hasPrefix("W7ToolbarPlate") {
            let r = v.frame
            v.removeFromSuperview()
            fresh.addSubview(v)
            v.frame = r
        }
        g.setValue(fresh, forKey: "contentView")
        spin()
        #expect(content() === fresh)
        #expect(plateFirst(), "a plate in the new contentView, under its item views")
        #expect(W7ToolbarLookPlateCount(f.window) == visible.count, "one plate per tinted platter, the old one not counted")
        #expect(controlFrames(f.window) == frames)
        W7ToolbarLookRestore(f.window)
        #expect(plates(f.window).isEmpty, "every plate removed")
        #expect(!old.subviews.contains { NSStringFromClass(type(of: $0)).hasPrefix("W7ToolbarPlate") },
                "the old contentView's too")
    }

    /// (review-task-69 item 4): a glass that deallocates while observed is safe only with automatic KVO
    /// notification (the macOS 10.13 relaxed unregistration), so only keys its class notifies automatically are observed.
    @Test func onlyAutomaticallyNotifiedGlassKeysAreObserved() {
        final class Manual: NSView {
            override class func automaticallyNotifiesObservers(forKey key: String) -> Bool {
                key == "style" ? false : super.automaticallyNotifiesObservers(forKey: key)
            }
        }
        #expect(W7ToolbarLookObservableGlassKeys(Manual.self) == ["tintColor", "cornerRadius", "contentView"])
        #expect(W7ToolbarLookObservableGlassKeys(NSView.self) == ["tintColor", "style", "cornerRadius", "contentView"])
        if let glass = NSClassFromString("NSGlassEffectView") {
            #expect(W7ToolbarLookObservableGlassKeys(glass) == ["tintColor", "style", "cornerRadius", "contentView"],
                    "NSGlassEffectView notifies all four automatically")
        }
    }

    @Test func applyThenRestoreLeavesEveryItemAsItWas() throws {
        let f = ToolbarFixture()
        defer { f.close() }
        let items = itemRecords(f.toolbar), buttons = buttonRecords(f.window)
        let itemIDs = ids(f.toolbar.items), visibleIDs = ids(f.toolbar.visibleItems ?? [])
        let glass = glassViews(f.window)
        let before = glass.map(glassSettings)
        #expect(items.count == ToolbarFixture.ids.count && !buttons.isEmpty)

        W7ToolbarLookApply(f.window)
        #expect(itemRecords(f.toolbar) == items, "applied: items untouched")
        #expect(buttonRecords(f.window) == buttons, "applied: no button's border, bezel, image, action or visibility changed")
        #expect(ids(f.toolbar.items) == itemIDs && ids(f.toolbar.visibleItems ?? []) == visibleIDs)

        W7ToolbarLookRestore(f.window)
        #expect(!W7ToolbarLookIsApplied(f.window))
        #expect(bandPainter(f.window) == nil)
        #expect(faces(f.window).isEmpty && plates(f.window).isEmpty)
        #expect(itemRecords(f.toolbar) == items)
        #expect(buttonRecords(f.window) == buttons)
        #expect(ids(f.toolbar.items) == itemIDs && ids(f.toolbar.visibleItems ?? []) == visibleIDs)
        #expect(glassViews(f.window).allSatisfy { !W7SafariGlassIsStyled($0) })
        #expect(glass.map(glassSettings) == before, "every glass view's tint, style and radius restored")
    }

    @Test func applyIsIdempotent() {
        let f = ToolbarFixture()
        defer { f.close() }
        W7ToolbarLookApply(f.window)
        let painter = bandPainter(f.window)
        let n = W7ToolbarLookButtonCount(f.window), g = W7ToolbarLookGlassCount(f.window), p = W7ToolbarLookPlateCount(f.window)
        let faceIDs = Set(faces(f.window).map(ObjectIdentifier.init)), plateIDs = Set(plates(f.window).map(ObjectIdentifier.init))
        W7ToolbarLookApply(f.window)
        W7ToolbarLookApply(f.window)
        #expect(bandPainter(f.window) === painter)
        #expect(W7TitlebarBandPainterIdentifiers(f.window) == [W7ToolbarLookBandPainterIdentifier], "one band")
        #expect(W7ToolbarLookButtonCount(f.window) == n && W7ToolbarLookGlassCount(f.window) == g)
        #expect(W7ToolbarLookPlateCount(f.window) == p)
        #expect(Set(faces(f.window).map(ObjectIdentifier.init)) == faceIDs, "no second face")
        #expect(Set(plates(f.window).map(ObjectIdentifier.init)) == plateIDs, "no second plate")
        W7ToolbarLookRestore(f.window)
        W7ToolbarLookRestore(f.window)   // twice: harmless
        #expect(faces(f.window).isEmpty && plates(f.window).isEmpty)
    }

    /// review item 5: an item that leaves the toolbar takes its face, plate and tint with it.
    @Test func aGroupThatStopsQualifyingGetsItsNativeLookBack() throws {
        let f = ToolbarFixture()
        defer { f.close() }
        let custom = try #require(f.toolbar.items.first { $0.itemIdentifier.rawValue == "btn" }?.view as? NSButton)
        let glass = visibleGlass(f.window).first { custom.isDescendant(of: $0) }
        let original = glass.map(glassSettings)
        W7ToolbarLookApply(f.window)
        let n = W7ToolbarLookButtonCount(f.window)
        let index = try #require(f.toolbar.items.firstIndex { $0.itemIdentifier.rawValue == "btn" })
        f.toolbar.removeItem(at: index)
        f.window.layoutIfNeeded()
        W7ToolbarLookApply(f.window)
        #expect(W7ToolbarLookButtonCount(f.window) == n - 1 && faces(f.window).count == n - 1, "one face fewer")
        #expect(!faces(f.window).contains { ($0.value(forKey: "button") as? NSButton) === custom })
        if let glass {
            #expect(!W7SafariGlassIsStyled(glass), "that glass restored")
            #expect(glassSettings(glass) == original)
            let content = glass.value(forKey: "contentView") as? NSView
            #expect(!(content?.subviews ?? []).contains { NSStringFromClass(type(of: $0)).hasPrefix("W7ToolbarPlate") })
            glass.setValue(0, forKey: "style")
            spin()
            #expect(glassSettings(glass).style == 0, "no longer observed")
        }
    }

    @Test func closingAStyledWindowRestoresIt() {
        let f = ToolbarFixture()
        W7ToolbarLookApply(f.window)
        let glass = glassViews(f.window).filter { W7SafariGlassIsStyled($0) }
        #expect(W7ToolbarLookIsApplied(f.window))
        f.window.close()
        #expect(!W7ToolbarLookIsApplied(f.window))
        #expect(faces(f.window).isEmpty && plates(f.window).isEmpty)
        #expect(bandPainter(f.window) == nil)
        #expect(glass.allSatisfy { !W7SafariGlassIsStyled($0) })
    }

    // MARK: Faces

    /// review item 3: a toolbar button that opens a modal dialog (Print, an alert) keeps the run loop in the
    /// modal-panel mode; its pressed face resets there too, but never during the button's own tracking loop.
    @Test func aPressedFaceResetsInTheDefaultAndModalModesOnly() throws {
        let f = ToolbarFixture()
        defer { f.close() }
        W7ToolbarLookApply(f.window)
        let custom = try #require(f.toolbar.items.first { $0.itemIdentifier.rawValue == "btn" }?.view as? NSButton)
        let face = try #require(faces(f.window).first { ($0.value(forKey: "button") as? NSButton) === custom })
        let p = face.convert(NSPoint(x: face.bounds.midX, y: face.bounds.midY), to: nil)
        func pressed() -> Bool { (face.value(forKey: "pressed") as? Bool) ?? false }

        #expect(W7ToolbarLookPressAt(f.window, p))
        #expect(pressed())
        spin(.eventTracking)
        #expect(pressed(), "still pressed while the button tracks the mouse")
        spin(.modalPanel)
        #expect(!pressed(), "reset while a modal dialog runs")

        #expect(W7ToolbarLookPressAt(f.window, p))
        spin(.default)
        #expect(!pressed(), "reset after the tracking loop")
        #expect(!W7ToolbarLookPressAt(f.window, NSPoint(x: -50, y: -50)), "nothing pressed outside the faces")
    }

    /// review item 4: a live resize can move a button into the overflow menu before the face is detached; a
    /// face whose button is no longer in its window draws and presses nothing.
    @Test func aFaceWhoseButtonLeftTheWindowDrawsAndPressesNothing() throws {
        let f = ToolbarFixture()
        defer { f.close() }
        W7ToolbarLookApply(f.window)
        let custom = try #require(f.toolbar.items.first { $0.itemIdentifier.rawValue == "btn" }?.view as? NSButton)
        let face = try #require(faces(f.window).first { ($0.value(forKey: "button") as? NSButton) === custom })
        let p = face.convert(NSPoint(x: face.bounds.midX, y: face.bounds.midY), to: nil)
        face.setValue(true, forKey: "hover")
        #expect(!render(face) { _ in face.draw(face.bounds) }.isBlank, "a hover face in place")

        let holder = try #require(custom.superview)
        let frame = custom.frame
        custom.removeFromSuperview()
        defer { holder.addSubview(custom); custom.frame = frame }
        #expect(render(face) { _ in face.draw(face.bounds) }.isBlank, "nothing drawn over empty glass")
        #expect(!W7ToolbarLookPressAt(f.window, p))
        #expect((face.value(forKey: "pressed") as? Bool) == false)
    }

    @Test func darkAppearanceKeepsTheNativeToolbar() {
        let f = ToolbarFixture(dark: true)
        defer { f.close() }
        W7ToolbarLookApply(f.window)
        #expect(!W7ToolbarLookIsApplied(f.window) && faces(f.window).isEmpty)
        #expect(bandPainter(f.window) == nil)
        // Light, styled, then dark: everything comes off.
        f.window.appearance = NSAppearance(named: .aqua)
        W7ToolbarLookApply(f.window)
        #expect(W7ToolbarLookIsApplied(f.window))
        f.window.appearance = NSAppearance(named: .darkAqua)
        W7ToolbarLookApply(f.window)
        #expect(!W7ToolbarLookIsApplied(f.window) && faces(f.window).isEmpty && plates(f.window).isEmpty)
        #expect(glassViews(f.window).allSatisfy { !W7SafariGlassIsStyled($0) })
    }

    @Test func updateFollowsTheKillSwitch() {
        let f = ToolbarFixture()
        defer { f.close(); W7ToolbarLookUseDisabledOverride(-1) }
        W7ToolbarLookUseDisabledOverride(0)
        W7ToolbarLookUpdate(f.window)
        #expect(W7ToolbarLookIsApplied(f.window))
        W7ToolbarLookUseDisabledOverride(1)
        W7ToolbarLookUpdate(f.window)
        #expect(!W7ToolbarLookIsApplied(f.window) && faces(f.window).isEmpty && plates(f.window).isEmpty)
    }

    /// item 5: the toolbar band is one identified painter among others (Safari's legacy slot, later the
    /// Messenger band); it never replaces or removes another.
    @Test func otherBandPaintersStayBesideTheToolbarBand() {
        final class Other: NSObject, W7TitlebarBandPainter {
            func w7DrawBands(inTitlebarView view: NSView, window: NSWindow, context: CGContext) {}
        }
        let f = ToolbarFixture()
        defer { f.close() }
        let legacy = Other(), messenger = Other()
        W7SetTitlebarBandPainter(f.window, legacy)
        W7SetTitlebarBandPainterForIdentifier(f.window, "test.messenger", messenger)
        W7ToolbarLookApply(f.window)
        #expect(W7TitlebarBandPainterForWindow(f.window) === legacy)
        #expect(W7TitlebarBandPainterForIdentifier(f.window, "test.messenger") === messenger)
        #expect(bandPainter(f.window) != nil)
        W7ToolbarLookRestore(f.window)
        #expect(W7TitlebarBandPainterForWindow(f.window) === legacy)
        #expect(W7TitlebarBandPainterForIdentifier(f.window, "test.messenger") === messenger)
        #expect(bandPainter(f.window) == nil)
        W7SetTitlebarBandPainter(f.window, nil)
        W7SetTitlebarBandPainterForIdentifier(f.window, "test.messenger", nil)
    }

    @Test func bandIsTheCommandBar() throws {
        let f = ToolbarFixture()
        defer { f.close() }
        W7ToolbarLookApply(f.window)
        let painter = try #require(bandPainter(f.window))
        let titlebar = try #require(f.window.standardWindowButton(.closeButton)?.superview)
        let tv = try #require(toolbarView(f.window))
        let band = titlebar.convert(tv.bounds, from: tv)
        let width = Int(titlebar.bounds.width), height = Int(titlebar.bounds.height)
        let ctx = try #require(CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                                         space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                         bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        painter.w7DrawBands(inTitlebarView: titlebar, window: f.window, context: ctx)
        let data = try #require(ctx.data).assumingMemoryBound(to: UInt8.self)
        func rgb(_ y: CGFloat) -> UInt32 {   // y from the bottom, in points (1x); the middle of the band
            let row = height - 1 - Int(y), i = row * width * 4 + Int(band.midX) * 4
            return UInt32(data[i]) << 16 | UInt32(data[i + 1]) << 8 | UInt32(data[i + 2])
        }
        #expect(near(rgb(band.minY), 0xA0AFC3), "the bottom line \(String(rgb(band.minY), radix: 16))")
        #expect(near(rgb(band.minY + 2), 0xDAE5F3), "lower half \(String(rgb(band.minY + 2), radix: 16))")
        let upper = rgb(band.maxY - 3)
        #expect(upper >> 16 >= 0xE9, "upper half is the light #F5F9FD→#E9F0F8 \(String(upper, radix: 16))")
        #expect(rgb(band.maxY + 4) == 0, "nothing above the toolbar (the caption is the glass's)")
    }

    /// an app look (Messages' Messenger band) may give the window's toolbar band its own fill; the band and
    /// the plates then draw it instead of the command bar, and nil puts the command bar back.
    @Test func bandFillOverrideReplacesTheCommandBarInTheBandAndThePlates() throws {
        let f = ToolbarFixture()
        defer { f.close() }
        W7ToolbarLookApply(f.window)
        let painter = try #require(bandPainter(f.window))
        let titlebar = try #require(f.window.standardWindowButton(.closeButton)?.superview)
        let tv = try #require(toolbarView(f.window))
        let band = titlebar.convert(tv.bounds, from: tv)
        let container = NSView(frame: NSRect(x: band.midX - 20, y: band.minY + 10, width: 40, height: 28))
        titlebar.addSubview(container)
        defer { container.removeFromSuperview() }
        let plate = try #require(W7ToolbarLookInsertPlate(container, tv, false))
        func bandMid() -> UInt32 {
            render(titlebar) { painter.w7DrawBands(inTitlebarView: titlebar, window: f.window, context: $0) }.rgb(band.midX, band.minY + 1)
        }
        func plateMid() -> UInt32 { render(plate) { _ in plate.draw(plate.bounds) }.rgb(plate.bounds.midX, 1) }
        #expect(W7ToolbarLookBandFill(f.window) == nil)
        let commandBar = bandMid()
        #expect(near(commandBar, 0xDAE5F3, 4) || near(commandBar, 0xDFE9F5, 6), "the command bar \(String(commandBar, radix: 16))")

        let red: W7ToolbarBandFill = { ctx, rect in
            ctx.setFillColor(red: 1, green: 0, blue: 0, alpha: 1)
            ctx.fill(rect)
        }
        W7ToolbarLookSetBandFill(f.window, red)
        #expect(W7ToolbarLookBandFill(f.window) != nil)
        #expect(near(bandMid(), 0xFF0000), "the band's fill \(String(bandMid(), radix: 16))")
        #expect(near(plateMid(), 0xFF0000), "the plate draws the same slice \(String(plateMid(), radix: 16))")

        W7ToolbarLookSetBandFill(f.window, nil)
        #expect(W7ToolbarLookBandFill(f.window) == nil)
        #expect(bandMid() == commandBar, "the command bar again")
        #expect(!near(plateMid(), 0xFF0000))
    }

    // MARK: Verbose dump (W7ToolbarVerboseLog)

    @Test func treeDumpHasClassNamesAndFramesOnly() {
        let f = ToolbarFixture()
        defer { f.close() }
        let dump = W7ToolbarLookTreeDump(f.window)
        #expect(dump.contains("ToolbarView"))
        #expect(dump.contains("{"), "frames")
        #expect(!dump.contains("Secret Document Title"), "never a title")
        #expect(!dump.contains("Delete") && !dump.contains("Favourite"), "never a label")
        #expect(dump.split(separator: "\n").count <= 200)
    }
}

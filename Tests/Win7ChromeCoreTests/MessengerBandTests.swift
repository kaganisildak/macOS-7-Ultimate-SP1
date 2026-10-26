import AppKit
import Testing
import Win7ChromeCore

// Messages framed like Windows Live Messenger, chrome only. In a decorated Messages
// main window the Aero title bar paints the Messenger header band in the toolbar's band through the stackable band
// painters, and the toolbar look's band takes the Messenger colours. Nothing is read from the window (a sentinel in the
// title and every toolbar label never matters), no item moves or hides, the kill switch turns it all off. Synthetic
// windows that are never ordered on screen; Messages itself is never launched.

private let sentinel = "W7SENTINEL-Alice-says-meet-at-noon"
private let sms = "com.apple.MobileSMS"

@MainActor private final class MessengerFixture: NSObject, NSToolbarDelegate {
    static let ids: [NSToolbarItem.Identifier] = [.init("compose"), .flexibleSpace, .init("facetime"), .init("info")]
    let toolbar = NSToolbar(identifier: "w7.test.messenger.\(UUID().uuidString)")
    let window: NSWindow

    init(decorate: Bool = true, toolbar withToolbar: Bool = true, title: String = sentinel, panel: Bool = false,
         style: NSWindow.StyleMask = [.titled, .closable, .miniaturizable, .resizable]) {
        _ = NSApplication.shared
        let rect = NSRect(x: 0, y: 0, width: 900, height: 500)
        window = panel ? NSPanel(contentRect: rect, styleMask: style, backing: .buffered, defer: true)
                       : NSWindow(contentRect: rect, styleMask: style, backing: .buffered, defer: true)
        super.init()
        window.isReleasedWhenClosed = false
        window.title = title
        window.appearance = NSAppearance(named: .aqua)
        if withToolbar {
            toolbar.delegate = self
            toolbar.autosavesConfiguration = false
            window.toolbar = toolbar
        }
        if decorate { W7ChromeController.decorateWindow(window) }
        window.layoutIfNeeded()
        window.displayIfNeeded()
    }

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] { Self.ids }
    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] { Self.ids }
    func toolbar(_ toolbar: NSToolbar, itemForItemIdentifier id: NSToolbarItem.Identifier,
                 willBeInsertedIntoToolbar flag: Bool) -> NSToolbarItem? {
        let item = NSToolbarItem(itemIdentifier: id)
        item.label = sentinel
        item.paletteLabel = sentinel
        item.toolTip = sentinel
        item.image = NSImage(systemSymbolName: "square.and.pencil", accessibilityDescription: sentinel)
        return item
    }

    var titlebar: NSView { window.standardWindowButton(.closeButton)!.superview! }
    var toolbarView: NSView? { titlebar.subviews.first { NSStringFromClass(type(of: $0)).hasSuffix("ToolbarView") } }
    func close() { window.close() }
}

@MainActor private func painter(_ w: NSWindow) -> W7TitlebarBandPainter? {
    W7TitlebarBandPainterForIdentifier(w, W7MessagesBandPainterIdentifier)
}

/// The titlebar view drawn by every band painter of the window, in order, into a 1x sRGB bitmap.
@MainActor private func renderBands(_ f: MessengerFixture) -> (CGFloat, CGFloat) -> (r: Int, g: Int, b: Int, a: Int) {
    let view = f.titlebar
    let width = Int(view.bounds.width), height = Int(view.bounds.height)
    var data = [UInt8](repeating: 0, count: width * height * 4)
    data.withUnsafeMutableBytes { buf in
        let ctx = CGContext(data: buf.baseAddress, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        for id in W7TitlebarBandPainterIdentifiers(f.window) {
            ctx.saveGState()
            W7TitlebarBandPainterForIdentifier(f.window, id)?.w7DrawBands(inTitlebarView: view, window: f.window, context: ctx)
            ctx.restoreGState()
        }
    }
    return { x, y in
        let row = height - 1 - Int(y), i = (row * width + Int(x)) * 4
        let a = Int(data[i + 3])
        func un(_ v: UInt8) -> Int { a == 0 ? 0 : min(255, Int((Double(v) * 255 / Double(a)).rounded())) }
        return (un(data[i]), un(data[i + 1]), un(data[i + 2]), a)
    }
}

private func near(_ p: (r: Int, g: Int, b: Int, a: Int), _ hex: UInt32, _ d: Int = 6) -> Bool {
    p.a > 240 && abs(p.r - Int(hex >> 16 & 0xFF)) <= d && abs(p.g - Int(hex >> 8 & 0xFF)) <= d && abs(p.b - Int(hex & 0xFF)) <= d
}

/// Every view under the toolbar view with its frame and hidden flag.
@MainActor private func itemSnapshot(_ f: MessengerFixture) -> [String] {
    var out: [String] = []
    func walk(_ v: NSView) {
        out.append("\(ObjectIdentifier(v)) \(v.frame) \(v.isHidden)")
        v.subviews.forEach(walk)
    }
    if let tv = f.toolbarView { walk(tv) }
    return out + f.toolbar.items.map { "\($0.itemIdentifier.rawValue) \($0.isHidden)" }
}

@MainActor private func controls(under v: NSView?) -> [NSView] {
    guard let v else { return [] }
    return v.subviews.flatMap { $0 is NSControl && !$0.isHidden ? [$0] : controls(under: $0) }
}

/// An empty asset root and no embedded icons for the body (no user.png), or a `user.png` of `rgb` when given.
private func withUserIcon(_ rgb: (CGFloat, CGFloat, CGFloat)?, _ body: () throws -> Void) rethrows {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("w7messenger-\(UUID().uuidString)")
    try? FileManager.default.createDirectory(at: root.appendingPathComponent("icons"), withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    if let rgb {
        let ctx = CGContext(data: nil, width: 64, height: 64, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.setFillColor(red: rgb.0, green: rgb.1, blue: rgb.2, alpha: 1)
        ctx.fill(CGRect(x: 0, y: 0, width: 64, height: 64))
        let png = NSBitmapImageRep(cgImage: ctx.makeImage()!).representation(using: .png, properties: [:])!
        try? png.write(to: root.appendingPathComponent("icons/user.png"))
    }
    W7UserIconsUseEmbedded([:])
    W7FolderIconUseAssetRoot(root.path)
    defer {
        W7UserIconsUseEmbedded(nil)
        W7FolderIconUseAssetRoot(nil)
    }
    try body()
}

@MainActor @Suite(.serialized) struct MessengerBandTests {
    // MARK: Pure decisions

    @Test func variantFollowsTheToolbarBandHeight() {
        #expect(W7MessengerBandVariantForHeight(80) == .full)
        #expect(W7MessengerBandVariantForHeight(64) == .full)
        #expect(W7MessengerBandVariantForHeight(63.5) == .compact)
        #expect(W7MessengerBandVariantForHeight(51) == .compact)
        #expect(W7MessengerBandVariantForHeight(32) == .compact)
        #expect(W7MessengerBandVariantForHeight(31) == .none)
        #expect(W7MessengerBandVariantForHeight(0) == .none)
    }

    @Test func geometryIsTheToolbarBandUnderTheCaption() {
        let bounds = CGRect(x: 0, y: 0, width: 900, height: 83)
        // A 51 pt toolbar under a 30 pt caption: compact, the 32 pt box centred in the band.
        let g = W7MessengerBandGeometryFor(bounds, CGRect(x: 0, y: 0, width: 900, height: 51), 2, nil, 0)
        #expect(g.variant == .compact)
        #expect(g.band == CGRect(x: 2, y: 0, width: 896, height: 51))
        #expect(g.box.height == 32 && abs(g.box.midY - g.band.midY) <= 0.5 && g.box.minX == 2 && g.box.width == 896)
        #expect(g.content == CGRect(x: 2, y: g.box.minY, width: 896, height: 32), "no items: the whole box")
        // The caption is never part of the band, even when the toolbar view reaches into it.
        let tall = W7MessengerBandGeometryFor(CGRect(x: 0, y: 0, width: 900, height: 110), CGRect(x: 0, y: 0, width: 900, height: 100), 0, nil, 0)
        #expect(tall.variant == .full && tall.band.maxY == 80 && tall.box.height == 64)
        // No toolbar band: nothing.
        let none = W7MessengerBandGeometryFor(CGRect(x: 0, y: 0, width: 900, height: 30), .zero, 2, nil, 0)
        #expect(none.variant == .none && none.band == .zero && none.content == .zero)
        let short = W7MessengerBandGeometryFor(bounds, CGRect(x: 0, y: 0, width: 900, height: 20), 2, nil, 0)
        #expect(short.variant == .none && short.content == .zero)
    }

    @Test func contentIsTheWidestSpanBetweenItems() {
        let bounds = CGRect(x: 0, y: 0, width: 900, height: 83)
        let toolbar = CGRect(x: 0, y: 0, width: 900, height: 51)
        let items = [CGRect(x: 10, y: 12, width: 40, height: 28), CGRect(x: 780, y: 12, width: 40, height: 28),
                     CGRect(x: 830, y: 12, width: 60, height: 28),
                     CGRect(x: 300, y: 60, width: 200, height: 20)]   // above the box: does not count
        let g = W7MessengerBandGeometryFor(bounds, toolbar, 2, items, UInt(items.count))
        #expect(g.content.minX == 56 && g.content.maxX == 774, "between the items, 6 pt clear of each: \(g.content)")
        #expect(g.content.minY == g.box.minY && g.content.height == 32)
        // No span wide enough: no header (the background still fills the band).
        let crowded = (0..<10).map { CGRect(x: CGFloat($0) * 90, y: 12, width: 60, height: 28) }
        let c = W7MessengerBandGeometryFor(bounds, toolbar, 2, crowded, UInt(crowded.count))
        #expect(c.variant == .compact && c.content == .zero && c.band.width == 896)
        #expect(W7MessengerBandMinimumContentWidth(false) == 140 && W7MessengerBandMinimumContentWidth(true) == 90)
    }

    @Test func appliesOnlyToDecoratedMessagesMainWindowsInLightAppearance() {
        let f = MessengerFixture()
        defer { f.close() }
        #expect(W7MessagesBandApplies(sms, f.window, false))
        #expect(!W7MessagesBandApplies(sms, f.window, true), "the kill switch")
        #expect(!W7MessagesBandApplies("com.apple.Notes", f.window, false), "Messages only")
        #expect(!W7MessagesBandApplies(nil, f.window, false))
        #expect(!W7MessagesBandApplies(sms, nil, false))
        let plain = MessengerFixture(decorate: false)
        defer { plain.close() }
        #expect(!W7MessagesBandApplies(sms, plain.window, false), "only under the Aero caption")
        let panel = MessengerFixture(panel: true)
        defer { panel.close() }
        #expect(!W7MessagesBandApplies(sms, panel.window, false), "main windows only")
        let dark = MessengerFixture()
        defer { dark.close() }
        dark.window.appearance = NSAppearance(named: .darkAqua)
        #expect(!W7MessagesBandApplies(sms, dark.window, false), "dark appearance keeps the native look")
    }

    // MARK: Registration and removal

    @Test func applyRegistersThePainterLastAndTheMessengerToolbarFillThenRestoreRemovesBoth() throws {
        let f = MessengerFixture()
        defer { f.close() }
        W7ToolbarLookApply(f.window)
        #expect(painter(f.window) == nil && !W7MessagesBandIsApplied(f.window))
        W7MessagesBandApply(f.window)
        #expect(W7MessagesBandIsApplied(f.window))
        #expect(painter(f.window) != nil)
        #expect(W7TitlebarBandPainterIdentifiers(f.window) == [W7ToolbarLookBandPainterIdentifier, W7MessagesBandPainterIdentifier])
        #expect(W7MessagesBandPainterIdentifier == "com.win7mac.band.messenger")
        #expect(W7ToolbarLookBandFill(f.window) != nil, "the toolbar band in Messenger colours")
        W7MessagesBandApply(f.window)
        #expect(W7TitlebarBandPainterIdentifiers(f.window).filter { $0 == W7MessagesBandPainterIdentifier }.count == 1, "idempotent")

        // Another painter added after it: the band puts itself last again.
        final class Other: NSObject, W7TitlebarBandPainter {
            func w7DrawBands(inTitlebarView view: NSView, window: NSWindow, context: CGContext) {}
        }
        let other = Other()
        W7SetTitlebarBandPainterForIdentifier(f.window, "test.other", other)
        W7MessagesBandApply(f.window)
        #expect(W7TitlebarBandPainterIdentifiers(f.window).last == W7MessagesBandPainterIdentifier)
        W7SetTitlebarBandPainterForIdentifier(f.window, "test.other", nil)

        W7MessagesBandRestore(f.window)
        #expect(!W7MessagesBandIsApplied(f.window))
        #expect(painter(f.window) == nil)
        #expect(W7TitlebarBandPainterIdentifiers(f.window) == [W7ToolbarLookBandPainterIdentifier], "the toolbar band stays")
        #expect(W7ToolbarLookBandFill(f.window) == nil, "the command bar again")
        W7ToolbarLookRestore(f.window)
    }

    @Test func aPainterAddedAfterTheBandIsMovedBehindItWhenTheBandDraws() throws {
        let f = MessengerFixture()
        defer { f.close() }
        W7MessagesBandApply(f.window)
        defer { W7MessagesBandRestore(f.window) }
        W7ToolbarLookApply(f.window)   // its painter is added after ours (as after a dark → light switch)
        defer { W7ToolbarLookRestore(f.window) }
        #expect(W7TitlebarBandPainterIdentifiers(f.window).last == W7ToolbarLookBandPainterIdentifier)
        _ = renderBands(f)
        _ = CFRunLoopRunInMode(.defaultMode, 0.05, false)
        #expect(W7TitlebarBandPainterIdentifiers(f.window).last == W7MessagesBandPainterIdentifier)
    }

    @Test func updateFollowsTheKillSwitchTheBundleAndTheWindow() {
        defer { W7MessagesLookUseDisabledOverride(-1) }
        let f = MessengerFixture()
        defer { f.close() }
        W7MessagesLookUseDisabledOverride(0)
        #expect(!W7MessagesBandUpdateForBundle(f.window, "com.apple.Notes"))
        #expect(painter(f.window) == nil)
        #expect(W7MessagesBandUpdateForBundle(f.window, sms))
        #expect(painter(f.window) != nil)
        W7MessagesLookUseDisabledOverride(1)
        #expect(!W7MessagesBandUpdateForBundle(f.window, sms), "W7MessagesLookDisabled")
        #expect(painter(f.window) == nil && W7ToolbarLookBandFill(f.window) == nil, "taken off")
        #expect(!W7MessagesBandUpdateForBundle(nil, sms))
    }

    @Test func closingTheWindowTakesTheBandOff() {
        let f = MessengerFixture()
        W7MessagesBandApply(f.window)
        #expect(painter(f.window) != nil)
        f.close()
        #expect(painter(f.window) == nil && !W7MessagesBandIsApplied(f.window) && W7ToolbarLookBandFill(f.window) == nil)
    }

    // MARK: Drawing

    @Test func bandFillsTheToolbarBandWithTheHeaderInItsFreeSpanAndLeavesTheCaptionAlone() {
        withUserIcon(nil) {
            let f = MessengerFixture()
            defer { f.close() }
            W7ToolbarLookApply(f.window)
            W7MessagesBandApply(f.window)
            defer { W7MessagesBandRestore(f.window); W7ToolbarLookRestore(f.window) }
            let g = W7MessagesBandGeometryForWindow(f.window, f.titlebar)
            #expect(g.variant == .compact, "a 51 pt toolbar band: compact")
            #expect(!g.content.isEmpty, "the flexible space leaves room")
            let px = renderBands(f)
            #expect(near(px(g.band.midX, g.band.maxY - 1), 0xDFEFFC, 4), "top of the band \(px(g.band.midX, g.band.maxY - 1))")
            #expect(near(px(g.band.minX + 1, g.band.minY), 0xC4DDF5, 4), "bottom of the band \(px(g.band.minX + 1, g.band.minY))")
            #expect(px(g.band.midX, g.band.maxY + 3).a == 0, "nothing in the caption")
            // The compact header: the 24 pt silhouette tile 4 pt into the content span.
            let tile = CGRect(x: g.content.minX + 4, y: (g.content.midY - 12).rounded(), width: 24, height: 24)
            #expect(near(px(tile.midX, tile.minY + 14), 0x7F9FC7, 10), "silhouette head \(px(tile.midX, tile.minY + 14))")
            // Under every toolbar item there is band background only (the header stays in its span).
            let items = controls(under: f.toolbarView).map { f.titlebar.convert($0.bounds, from: $0) }
            #expect(!items.isEmpty)
            for item in items where item.maxY > g.content.minY && item.minY < g.content.maxY {
                #expect(!item.intersects(g.content), "content clear of \(item)")
            }
        }
    }

    @Test func theUsersPictureIsTheTile() {
        withUserIcon((1, 0, 0)) {
            let f = MessengerFixture()
            defer { f.close() }
            W7MessagesBandApply(f.window)
            defer { W7MessagesBandRestore(f.window) }
            let g = W7MessagesBandGeometryForWindow(f.window, f.titlebar)
            let px = renderBands(f)
            let centre = px(g.content.minX + 16, (g.content.midY).rounded())
            #expect(near(centre, 0xFF0000, 10), "user.png in the tile \(centre)")
        }
    }

    @Test func darkAppearanceOrAHiddenToolbarDrawsNothing() {
        let f = MessengerFixture()
        defer { f.close() }
        W7MessagesBandApply(f.window)
        defer { W7MessagesBandRestore(f.window) }
        f.window.appearance = NSAppearance(named: .darkAqua)
        let g = W7MessagesBandGeometryForWindow(f.window, f.titlebar)
        #expect(renderBands(f)(g.band.midX, g.band.midY).a == 0, "dark: native")
        f.window.appearance = NSAppearance(named: .aqua)
        f.toolbar.isVisible = false
        f.window.layoutIfNeeded()
        #expect(W7MessagesBandGeometryForWindow(f.window, f.titlebar).variant == .none)
        #expect(renderBands(f)(450, 10).a == 0)
    }

    // MARK: Items untouched, nothing read

    @Test func itemsAreNeverMovedOrHidden() {
        let f = MessengerFixture()
        defer { f.close() }
        let before = itemSnapshot(f)
        W7MessagesBandApply(f.window)
        _ = renderBands(f)
        f.window.layoutIfNeeded()
        #expect(itemSnapshot(f) == before)
        W7MessagesBandRestore(f.window)
        #expect(itemSnapshot(f) == before)
    }

    @Test func noTextIsReadFromTheWindow() throws {
        #expect(W7MessagesDisplayName() == (NSFullUserName().isEmpty ? NSUserName() : NSFullUserName()))
        let strings = W7MessagesBandStrings()
        #expect(strings == [W7MessagesDisplayName(), "Available", "Send an instant message", "Send a file", "Video call", "Add a contact"])
        #expect(strings.allSatisfy { !$0.contains("W7SENTINEL") && !$0.contains("Alice") })
        // The same pixels whatever the window's title says.
        try withUserIcon(nil) {
            let a = MessengerFixture(title: sentinel), b = MessengerFixture(title: "Something else entirely")
            defer { a.close(); b.close() }
            W7MessagesBandApply(a.window)
            W7MessagesBandApply(b.window)
            defer { W7MessagesBandRestore(a.window); W7MessagesBandRestore(b.window) }
            let pa = renderBands(a), pb = renderBands(b)
            let g = W7MessagesBandGeometryForWindow(a.window, a.titlebar)
            var same = true
            for y in stride(from: g.band.minY, to: g.band.maxY, by: 1) {
                for x in stride(from: g.band.minX, to: g.band.maxX, by: 1) where pa(x, y) != pb(x, y) { same = false }
            }
            #expect(same, "the title never reaches the band")
            let line = try #require(W7MessagesBandLogLine(a.window))
            #expect(line.hasPrefix("Messenger band: compact"), "\(line)")
            #expect(!line.contains("W7SENTINEL") && !line.contains("Alice"))
            #expect(W7MessagesBandLogLine(b.window) == line, "one line per window, the same for the same layout")
        }
    }
}

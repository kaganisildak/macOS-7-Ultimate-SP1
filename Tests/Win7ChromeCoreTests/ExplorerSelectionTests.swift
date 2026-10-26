import AppKit
import ObjectiveC
import Testing
import Win7ChromeCore

// the details pane rows, the contextual command bar, the selection highlight colours and
// hooks, and the details pane layout. No window is ordered on screen and no events are posted.

private let tr = Locale(identifier: "tr_TR")
private let enUS = Locale(identifier: "en_US")
private let gmt = TimeZone(identifier: "GMT")!

private func date(_ y: Int, _ mo: Int, _ d: Int, _ h: Int, _ mi: Int) -> Date {
    var c = Calendar(identifier: .gregorian)
    c.timeZone = gmt
    return c.date(from: DateComponents(year: y, month: mo, day: d, hour: h, minute: mi))!
}

private func file(_ name: String, type: String? = "Document", size: Int64 = 1_234_567, image: Bool = false,
                  printable: Bool = false, defaultApp: Bool = true, modified: Date? = date(2026, 10, 16, 14, 32),
                  created: Date? = date(2026, 10, 15, 9, 5), pixels: NSSize = .zero) -> W7ExplorerItemInfo {
    let i = W7ExplorerItemInfo()
    i.name = name
    i.typeName = type
    i.fileSize = size
    i.isImage = image
    i.isPrintable = printable
    i.hasDefaultApp = defaultApp
    i.modified = modified
    i.created = created
    i.pixelSize = pixels
    return i
}

private func folder(_ name: String, modified: Date? = date(2026, 10, 14, 8, 0)) -> W7ExplorerItemInfo {
    let i = W7ExplorerItemInfo()
    i.name = name
    i.typeName = "Folder"
    i.isFolder = true
    i.fileSize = -1
    i.modified = modified
    return i
}

// MARK: - Formatting

@Test func sizeTextFollowsWindowsSevenRounding() {
    #expect(W7ExplorerSizeText(0, enUS) == "0 bytes")
    #expect(W7ExplorerSizeText(1, enUS) == "1 byte")
    #expect(W7ExplorerSizeText(999, enUS) == "999 bytes")
    #expect(W7ExplorerSizeText(1000, enUS) == "1 KB")
    #expect(W7ExplorerSizeText(345_600, enUS) == "346 KB")
    #expect(W7ExplorerSizeText(1_234_567, enUS) == "1.2 MB")
    #expect(W7ExplorerSizeText(12_345_678, enUS) == "12.3 MB")
    #expect(W7ExplorerSizeText(123_456_789, enUS) == "123 MB")
    #expect(W7ExplorerSizeText(5_000_000_000, enUS) == "5 GB")
    #expect(W7ExplorerSizeText(2_500_000_000_000, enUS) == "2.5 TB")
    #expect(W7ExplorerSizeText(-1, enUS) == "—")
    #expect(W7ExplorerSizeText(1_234_567, tr) == "1,2 MB")
}

@Test func dateTextUsesTheLocalesShortForms() {
    #expect(W7ExplorerDateText(date(2026, 10, 16, 14, 32), tr, gmt) == "16.10.2026 14:32")
}

// MARK: - Details rows

@Test func detailsForOneImageFile() {
    let d = W7ExplorerDetailsForItems([file("photo.jpg", type: "JPEG image", image: true, printable: true,
                                            pixels: NSSize(width: 1920, height: 1080))], "Pictures", 12, tr, gmt)
    #expect(d.title == "photo.jpg")
    #expect(d.titleStyle == .name)
    #expect(d.subtitle == "JPEG image")
    #expect(d.labels == ["Date modified:", "Size:", "Date created:", "Dimensions:"])
    #expect(d.values == ["16.10.2026 14:32", "1,2 MB", "15.10.2026 09:05", "1920 x 1080"])
}

@Test func detailsForOneFileLeaveOutUnknownValues() {
    let d = W7ExplorerDetailsForItems([file("notes", type: nil, size: -1, created: nil)], "Documents", 3, tr, gmt)
    #expect(d.title == "notes")
    #expect(d.subtitle == nil)
    #expect(d.labels == ["Date modified:"])
    #expect(d.values == ["16.10.2026 14:32"])
}

@Test func detailsForOneFolder() {
    let d = W7ExplorerDetailsForItems([folder("Projects")], "Documents", 3, tr, gmt)
    #expect(d.title == "Projects")
    #expect(d.titleStyle == .name)
    #expect(d.subtitle == "File folder")
    #expect(d.labels == ["Date modified:"])
    #expect(d.values == ["14.10.2026 08:00"])
}

@Test func detailsForSeveralItemsAggregate() {
    let items = [file("a.txt", size: 1_000_000, modified: date(2026, 10, 16, 14, 32)),
                 file("b.txt", size: 234_567, modified: date(2026, 10, 15, 9, 5)),
                 folder("Old", modified: date(2026, 10, 14, 8, 0))]
    let d = W7ExplorerDetailsForItems(items, "Documents", 9, tr, gmt)
    #expect(d.title == "3 items selected")
    #expect(d.titleStyle == .heading)
    #expect(d.subtitle == nil)
    #expect(d.labels == ["Date modified:", "Size:"])
    #expect(d.values == ["14.10.2026 08:00 - 16.10.2026 14:32", "1,2 MB"])

    let same = W7ExplorerDetailsForItems([file("a", modified: date(2026, 10, 16, 14, 32)),
                                          file("b", modified: date(2026, 10, 16, 14, 32))], "x", 2, tr, gmt)
    #expect(same.values.first == "16.10.2026 14:32")

    let folders = W7ExplorerDetailsForItems([folder("A"), folder("B")], "x", 2, tr, gmt)
    #expect(folders.labels == ["Date modified:", "Size:"])
    #expect(folders.values.last == "—")
}

@Test func detailsWithNothingSelectedShowTheFolder() {
    let d = W7ExplorerDetailsForItems([], "Documents", 16, tr, gmt)
    #expect(d.title == "16 items")
    #expect(d.titleStyle == .plain)
    #expect(d.labels.isEmpty && d.values.isEmpty)
    #expect(W7ExplorerDetailsForItems([], "Documents", 1, tr, gmt).title == "1 item")
    #expect(W7ExplorerDetailsForItems([], "Recents", -1, tr, gmt).title == "Recents")
}

// MARK: - Command set

private func commands(_ items: [W7ExplorerItemInfo], images: Bool = false) -> [W7ExplorerCommand] {
    W7ExplorerCommandsForItems(items, images).map { W7ExplorerCommand(rawValue: $0.intValue)! }
}

@Test func commandSetTable() {
    #expect(commands([]) == [.organize, .share, .burn, .newFolder])
    #expect(commands([], images: true) == [.organize, .share, .slideShow, .burn, .newFolder])
    #expect(commands([folder("A")], images: true) == [.organize, .open, .share, .burn, .newFolder])
    #expect(commands([file("p.jpg", image: true, printable: true)])
            == [.organize, .openMenu, .share, .slideShow, .print, .email, .burn, .newFolder])
    #expect(commands([file("x.bin", defaultApp: false)]) == [.organize, .openWith, .share, .email, .burn, .newFolder])
    #expect(commands([file("a.pdf", printable: true), file("b.jpg", image: true, printable: true)])
            == [.organize, .open, .share, .slideShow, .print, .email, .burn, .newFolder])
    #expect(commands([file("a.pdf", printable: true), file("b.zip")])
            == [.organize, .open, .share, .email, .burn, .newFolder])
    #expect(commands([file("b.jpg", image: true, printable: true), folder("A")])
            == [.organize, .open, .share, .slideShow, .burn, .newFolder])
}

@Test func commandTitlesAndMenus() {
    let all: [W7ExplorerCommand] = [.organize, .open, .openMenu, .openWith, .share, .slideShow, .print, .email, .burn, .newFolder]
    #expect(all.map { W7ExplorerCommandTitle($0) }
            == ["Organize", "Open", "Open", "Open with", "Share with", "Slide show", "Print", "E-mail", "Burn", "New folder"])
    #expect(all.filter { W7ExplorerCommandHasMenu($0) } == [.organize, .openMenu, .openWith, .share])
}

// MARK: - Selection colours

@Test func selectionColourTable() {
    let hover = W7ExplorerSelectionColorsForState(.hover)
    #expect((hover.border, hover.top, hover.bottom, hover.visible) == (0xB8D6FB, 0xEBF4FD, 0xDBEAFC, true))
    let sel = W7ExplorerSelectionColorsForState(.selected)
    #expect((sel.border, sel.top, sel.bottom, sel.visible) == (0x84ACDD, 0xDCEBFC, 0xC1DBFC, true))
    let unfocused = W7ExplorerSelectionColorsForState(.selectedUnfocused)
    #expect((unfocused.border, unfocused.top, unfocused.bottom, unfocused.visible) == (0xD9D9D9, 0xF8F8F8, 0xE5E5E5, true))
    #expect(!W7ExplorerSelectionColorsForState(.none).visible)
    #expect(W7ExplorerSelectionRadius == 3)
}

@Test func selectionStateTable() {
    #expect(W7ExplorerSelectionStateFor(false, true, false) == .none)
    #expect(W7ExplorerSelectionStateFor(false, false, true) == .hover)
    #expect(W7ExplorerSelectionStateFor(true, true, false) == .selected)
    #expect(W7ExplorerSelectionStateFor(true, true, true) == .selected)
    #expect(W7ExplorerSelectionStateFor(true, false, false) == .selectedUnfocused)
    #expect(W7ExplorerSelectionStateFor(true, false, true) == .selectedUnfocused)
}

/// An sRGB bitmap on white; read back as sRGB bytes at (x, y), y from the bottom.
private struct Bitmap {
    let width: Int, height: Int
    var data: [UInt8]
    func pixel(_ x: Int, _ y: Int) -> (Int, Int, Int) {
        let i = ((height - 1 - y) * width + x) * 4   // memory is top-down
        return (Int(data[i]), Int(data[i + 1]), Int(data[i + 2]))
    }
}

private func render(_ w: Int, _ h: Int, _ draw: (CGContext) -> Void) -> Bitmap {
    var data = [UInt8](repeating: 255, count: w * h * 4)   // opaque white
    data.withUnsafeMutableBytes { buf in
        let ctx = CGContext(data: buf.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        draw(ctx)
    }
    return Bitmap(width: w, height: h, data: data)
}

private func pixel(_ b: Bitmap, _ x: Int, _ y: Int) -> (Int, Int, Int) { b.pixel(x, y) }

private func hex(_ v: UInt32) -> (Int, Int, Int) { (Int(v >> 16 & 0xFF), Int(v >> 8 & 0xFF), Int(v & 0xFF)) }

private func near(_ a: (Int, Int, Int), _ b: (Int, Int, Int), _ tolerance: Int = 3) -> Bool {
    abs(a.0 - b.0) <= tolerance && abs(a.1 - b.1) <= tolerance && abs(a.2 - b.2) <= tolerance
}

@Test func drawnSelectionHasBorderAndVerticalFill() {
    let rep = render(40, 20) { W7DrawExplorerSelection($0, CGRect(x: 0, y: 0, width: 40, height: 20), .selected, false) }
    #expect(near(pixel(rep, 20, 0), hex(0x84ACDD)))          // bottom border
    #expect(near(pixel(rep, 0, 10), hex(0x84ACDD)))          // left border
    #expect(near(pixel(rep, 20, 18), hex(0xDCEBFC), 4))      // fill, near the top
    #expect(near(pixel(rep, 20, 1), hex(0xC1DBFC), 4))       // fill, near the bottom
    #expect(pixel(rep, 0, 0) != hex(0x84ACDD))               // rounded corner
    let flipped = render(40, 20) { ctx in
        ctx.translateBy(x: 0, y: 20); ctx.scaleBy(x: 1, y: -1)
        W7DrawExplorerSelection(ctx, CGRect(x: 0, y: 0, width: 40, height: 20), .selected, true)
    }
    #expect(near(pixel(flipped, 20, 18), hex(0xDCEBFC), 4))  // still light at the top
    let none = render(10, 10) { W7DrawExplorerSelection($0, CGRect(x: 0, y: 0, width: 10, height: 10), .none, false) }
    #expect(pixel(none, 5, 5) == (255, 255, 255))
}

// MARK: - Highlight hooks

@Test func highlightInstallsOnlyInFinderWithoutKillSwitch() {
    #expect(W7ExplorerSelectionHighlightShouldInstall("com.apple.finder", false))
    #expect(!W7ExplorerSelectionHighlightShouldInstall("com.apple.finder", true))
    #expect(!W7ExplorerSelectionHighlightShouldInstall("com.apple.Safari", false))
    #expect(!W7ExplorerSelectionHighlightShouldInstall(nil, false))
}

final class W7TestListRowView: NSTableRowView {}
final class W7TestIconSelectionView: NSView {
    override var wantsUpdateLayer: Bool { true }
    override func updateLayer() { layer?.backgroundColor = NSColor.systemBlue.cgColor }
}
final class W7TestIconHost: NSView {
    @objc var useActiveAppearance = true
}
/// Like Finder's TIconView: a selected title has a bubble; its text is white while the view is active,
/// the label colour otherwise.
final class W7TestIconView: NSView {
    var selected = true
    var active = true
    @objc var isTitleDimmed = false
    @objc dynamic var titleBubbleViewIsSelected: Bool { selected }
    @objc(_titleFontColor) dynamic var w7TitleFontColor: NSColor { selected && active ? .white : .labelColor }
}
/// Only the bubble, no title colour method: must not be hooked (the text would stay white).
final class W7TestBubbleOnlyIconView: NSView {
    @objc dynamic var titleBubbleViewIsSelected: Bool { true }
}
final class W7TestPlainView: NSView {}

private func cgHex(_ c: CGColor?) -> (Int, Int, Int)? {
    guard let c, let s = c.converted(to: CGColorSpace(name: CGColorSpace.sRGB)!, intent: .defaultIntent, options: nil),
          let comps = s.components, comps.count >= 3 else { return nil }
    return (Int((comps[0] * 255).rounded()), Int((comps[1] * 255).rounded()), Int((comps[2] * 255).rounded()))
}

@MainActor @Test func listRowHookDrawsWindowsSelectionWithBlackText() {
    #expect(W7ExplorerHookListRowClass(W7TestListRowView.self))
    #expect(W7ExplorerHookListRowClass(W7TestListRowView.self))   // idempotent
    let row = W7TestListRowView(frame: NSRect(x: 0, y: 0, width: 100, height: 20))
    let plain = NSTableRowView(frame: row.frame)
    for r in [row, plain] { r.appearance = NSAppearance(named: .aqua); r.isSelected = true; r.isEmphasized = true }
    // Until the draw hook has painted a row of this class, the background style is Finder's own.
    #expect(row.interiorBackgroundStyle == plain.interiorBackgroundStyle)
    func drawn() -> NSBitmapImageRep {
        let rep = row.bitmapImageRepForCachingDisplay(in: row.bounds)!
        row.cacheDisplay(in: row.bounds, to: rep)
        return rep
    }
    var rep = drawn()
    #expect(row.interiorBackgroundStyle == .normal)   // painted: black text from now on
    let mid = rep.colorAt(x: rep.pixelsWide / 2, y: rep.pixelsHigh / 2)!.usingColorSpace(.sRGB)!
    let midRGB = (Int((mid.redComponent * 255).rounded()), Int((mid.greenComponent * 255).rounded()), Int((mid.blueComponent * 255).rounded()))
    // Between the selected fill's top and bottom colours.
    #expect(midRGB.0 >= 0xC1 - 3 && midRGB.0 <= 0xDC + 3 && midRGB.2 >= 0xFA)
    row.isEmphasized = false
    rep = drawn()
    let grey = rep.colorAt(x: rep.pixelsWide / 2, y: rep.pixelsHigh / 2)!.usingColorSpace(.sRGB)!
    #expect(abs(grey.redComponent - grey.blueComponent) < 0.02 && grey.redComponent > 0.85)
    row.isSelected = false
    #expect(W7ExplorerHookListRowClass(nil) == false)
}

@MainActor @Test func iconSelectionHookRestylesTheLayer() {
    #expect(W7ExplorerHookIconSelectionClass(W7TestIconSelectionView.self))
    #expect(W7ExplorerHookIconSelectionClass(W7TestIconSelectionView.self))
    #expect(!W7ExplorerHookIconSelectionClass(W7TestPlainView.self))   // inherited -updateLayer only
    let host = W7TestIconHost(frame: NSRect(x: 0, y: 0, width: 80, height: 80))
    let sel = W7TestIconSelectionView(frame: NSRect(x: 10, y: 10, width: 60, height: 60))
    sel.wantsLayer = true
    host.addSubview(sel)
    sel.perform(#selector(NSView.updateLayer))   // through objc_msgSend: Swift calls a final override directly
    let layer = sel.layer!
    #expect(layer.backgroundColor == nil)
    #expect(cgHex(layer.borderColor).map { near($0, hex(0x84ACDD), 1) } == true)
    #expect(layer.borderWidth == 1 && layer.cornerRadius == 3)
    let gradient = layer.sublayers?.compactMap { $0 as? CAGradientLayer }.first
    #expect(gradient != nil)
    #expect(gradient?.frame == layer.bounds)
    let colours = (gradient?.colors as? [CGColor])?.compactMap(cgHex) ?? []
    #expect(colours.count == 2)
    host.useActiveAppearance = false
    sel.perform(#selector(NSView.updateLayer))   // through objc_msgSend: Swift calls a final override directly
    #expect(cgHex(layer.borderColor).map { near($0, hex(0xD9D9D9), 1) } == true)
    #expect((layer.sublayers?.compactMap { $0 as? CAGradientLayer }.count) == 1)   // reused, not stacked
}

@Test func iconTitleLookTable() {
    #expect(W7ExplorerIconTitleLookFor(true, false) == .darkNoBubble)   // selected (or drop target), light
    #expect(W7ExplorerIconTitleLookFor(false, false) == .finder)        // unselected: Finder's own
    #expect(W7ExplorerIconTitleLookFor(true, true) == .finder)          // dark: Finder's bubble and text
    #expect(W7ExplorerIconTitleLookFor(false, true) == .finder)
}

private func rgba(_ c: NSColor) -> (Int, Int, Int, Int) {
    let s = c.usingColorSpace(.sRGB)!
    return (Int((s.redComponent * 255).rounded()), Int((s.greenComponent * 255).rounded()),
            Int((s.blueComponent * 255).rounded()), Int((s.alphaComponent * 100).rounded()))
}

@MainActor @Test func iconTitleHookPairsNoBubbleWithDarkText() {
    let v = W7TestIconView(frame: .zero)
    v.appearance = NSAppearance(named: .aqua)
    #expect(v.titleBubbleViewIsSelected && v.w7TitleFontColor == .white)   // Finder: white on its bubble
    #expect(!W7ExplorerHookIconTitleClass(W7TestBubbleOnlyIconView.self))  // never the bubble alone
    #expect(W7TestBubbleOnlyIconView(frame: .zero).titleBubbleViewIsSelected)
    #expect(W7ExplorerHookIconTitleClass(W7TestIconView.self))
    #expect(W7ExplorerHookIconTitleClass(W7TestIconView.self))            // idempotent
    #expect(!W7ExplorerHookIconTitleClass(W7TestPlainView.self))

    // Selected, focused, light: no bubble, black text (never white on the white background).
    #expect(!v.titleBubbleViewIsSelected)
    #expect(rgba(v.w7TitleFontColor) == (0, 0, 0, 100))
    // Selected in an unfocused window: still no bubble and black text.
    v.active = false
    #expect(!v.titleBubbleViewIsSelected)
    #expect(rgba(v.w7TitleFontColor) == (0, 0, 0, 100))
    // A dimmed (cut) selected title: half-transparent black.
    v.isTitleDimmed = true
    #expect(rgba(v.w7TitleFontColor) == (0, 0, 0, 50))
    v.isTitleDimmed = false
    // Unselected: Finder's own colour, no bubble.
    v.selected = false
    #expect(!v.titleBubbleViewIsSelected && v.w7TitleFontColor == .labelColor)
    // Dark: Finder's bubble and white text.
    v.selected = true
    v.active = true
    v.appearance = NSAppearance(named: .darkAqua)
    #expect(v.titleBubbleViewIsSelected && v.w7TitleFontColor == .white)
}

// MARK: - Details pane view

@MainActor @Test func detailsPaneViewLaysOutRowsWithoutOverlap() {
    let content = W7ExplorerDetailsForItems([file("A rather long photograph name.jpg", type: "JPEG image", image: true,
                                                  pixels: NSSize(width: 1920, height: 1080))], "Pictures", 12, enUS, gmt)
    #expect(content.labels.count == 4)
    var counts: [Int] = []
    for width in [260.0, 560.0, 1200.0] {
        let v = W7ExplorerDetailsView(frame: NSRect(x: 0, y: 0, width: width, height: W7ExplorerDetailsPaneHeight))
        v.content = content
        v.icons = [NSImage(size: NSSize(width: 48, height: 48))]
        let icon = v.iconFrame
        #expect(icon.width == 48 && icon.height == 48)
        #expect(v.bounds.contains(icon))
        let frames = v.textFrames().map(\.rectValue)
        counts.append(frames.count)
        for (i, f) in frames.enumerated() {
            #expect(v.bounds.contains(f), "width \(width): \(f) outside")
            #expect(f.minX >= icon.maxX, "width \(width): \(f) over the icon")
            for g in frames[(i + 1)...] { #expect(!f.intersects(g), "width \(width): \(f) overlaps \(g)") }
        }
    }
    #expect(counts[2] == 2 + 2 * 4)            // title, subtitle and every row at full width
    #expect(counts[0] < counts[2])             // a narrow pane drops whole columns
    #expect(counts[0] >= 2)                    // but keeps the title and subtitle
    #expect(counts[0] % 2 == 0)                // labels never without their values
}

@MainActor @Test func detailsPaneViewWithNothingSelectedShowsOneLine() {
    let v = W7ExplorerDetailsView(frame: NSRect(x: 0, y: 0, width: 600, height: W7ExplorerDetailsPaneHeight))
    v.content = W7ExplorerDetailsForItems([], "Documents", 16, enUS, gmt)
    #expect(v.textFrames().count == 1)
    v.icons = []
    #expect(v.textFrames().first.map { $0.rectValue.minX >= v.iconFrame.maxX } == true)
}

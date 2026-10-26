import Testing
import AppKit
import Win7Theme

// The Windows 7 Computer view's drawing — group headers, drive tiles and capacity bars.

private func near(_ p: Pixel, _ hex: UInt32, _ tolerance: Int = 6) -> Bool {
    let r = Int((hex >> 16) & 0xFF), g = Int((hex >> 8) & 0xFF), b = Int(hex & 0xFF)
    return p.a > 240 && abs(p.r - r) <= tolerance && abs(p.g - g) <= tolerance && abs(p.b - b) <= tolerance
}

@Suite struct ComputerDrawingTests {
    @Test func metrics() {
        #expect(W7ComputerCapacityBarWidth == 200)
        #expect(W7ComputerCapacityBarHeight == 12)
        #expect(W7ComputerTileWidth == 266)
        #expect(W7ComputerTileHeight == 58)
        #expect(W7ComputerGroupHeaderHeight == 24)
    }

    /// The fill sits inside the 1 pt border, from the left, (width − 2) × used, rounded; used is clamped to 0…1.
    @Test func capacityFillGeometry() {
        let bar = CGRect(x: 10, y: 20, width: 200, height: 12)
        #expect(W7ComputerCapacityFillRect(bar, 0.75) == CGRect(x: 11, y: 21, width: 149, height: 10))   // 148.5 → 149
        #expect(W7ComputerCapacityFillRect(bar, 0.5) == CGRect(x: 11, y: 21, width: 99, height: 10))
        #expect(W7ComputerCapacityFillRect(bar, 0).width == 0)
        #expect(W7ComputerCapacityFillRect(bar, -0.3).width == 0)
        #expect(W7ComputerCapacityFillRect(bar, 1.4).width == 198)
        #expect(W7ComputerCapacityFillRect(bar, .nan).width == 0)
    }

    /// #06B025 fill over the used part, #E6E6E6 trough over the free part, #BCBCBC border; red #DA2626 when low.
    @Test func capacityBarColours() {
        let bar = CGRect(x: 0, y: 0, width: 200, height: 12)
        let px = render(width: 200, height: 12) { W7DrawComputerCapacityBar($0, bar, 0.5, false) }
        #expect(near(px(40, 6), 0x06B025), "fill \(px(40, 6))")
        #expect(near(px(160, 6), 0xE6E6E6), "trough \(px(160, 6))")
        #expect(near(px(0, 6), 0xBCBCBC), "left border \(px(0, 6))")
        #expect(near(px(100, 11), 0xBCBCBC), "top border \(px(100, 11))")
        let low = render(width: 200, height: 12) { W7DrawComputerCapacityBar($0, bar, 0.95, true) }
        #expect(near(low(100, 6), 0xDA2626), "low fill \(low(100, 6))")
        #expect(near(low(197, 6), 0xE6E6E6), "low trough \(low(197, 6))")
    }

    /// The title in dark blue at the left, then a #D5DFE5 rule to the right edge, never through the title.
    @Test func groupHeaderHasTitleThenRule() throws {
        let rect = CGRect(x: 0, y: 0, width: 300, height: 24)
        let px = render(width: 300, height: 24) { W7DrawComputerGroupHeader($0, rect, "Hard Disk Drives") }
        var dark = 0
        for y in 0..<24 { for x in 0..<100 where px(x, y).a > 128 && px(x, y).b > px(x, y).r + 20 && px(x, y).r < 120 { dark += 1 } }
        #expect(dark > 20, "title pixels \(dark)")
        var ruleRow = -1
        for y in 0..<24 where near(px(295, y), 0xD5DFE5) { ruleRow = y }
        try #require(ruleRow >= 0, "rule at the right edge")
        // The rule starts after the title: a column inside the title has no rule colour on the rule's row.
        #expect(!near(px(4, ruleRow), 0xD5DFE5))
        #expect(px(299, 0).a == 0 && px(299, 23).a == 0)
    }

    /// A 48 pt icon on the left, vertically centred; the name, the 200 × 12 bar and the text stacked to its right.
    @Test func tileLayout() {
        let tile = CGRect(x: 0, y: 0, width: 266, height: 58)
        let l = W7ComputerTileLayoutFor(tile)
        #expect(l.icon.size == CGSize(width: 48, height: 48))
        #expect(l.icon.midY == tile.midY && l.icon.minX == 5)
        #expect(l.bar.size == CGSize(width: 200, height: 12))
        #expect(l.name.minX == l.icon.maxX + 6 && l.bar.minX == l.name.minX && l.text.minX == l.name.minX)
        #expect(l.name.minY >= l.bar.maxY && l.bar.minY >= l.text.maxY)   // top to bottom: name, bar, text
        #expect(tile.contains(l.name) && tile.contains(l.bar) && tile.contains(l.text))
        // A narrow tile shortens the bar instead of overflowing.
        let narrow = W7ComputerTileLayoutFor(CGRect(x: 0, y: 0, width: 180, height: 58))
        #expect(narrow.bar.maxX <= 180 && narrow.bar.width > 0)
    }

    /// Selection #CCE8FF / #99D1FF and hover #E5F3FB / #70C0E7 behind the tile, as the navigation pane.
    @Test func tileHighlights() {
        let tile = CGRect(x: 0, y: 0, width: 266, height: 58)
        func draw(_ selected: Bool, _ hover: Bool) -> (Int, Int) -> Pixel {
            render(width: 266, height: 58) {
                W7DrawComputerTile($0, tile, nil, .drive, "Local Disk", "117 GB free of 460 GB", 0.75, false, selected, hover)
            }
        }
        // A blank spot right of the bar, between the name and the text.
        let selected = draw(true, false), hover = draw(false, true), plain = draw(false, false)
        #expect(near(selected(262, 29), 0xCCE8FF), "selected \(selected(262, 29))")
        #expect(near(selected(128, 0), 0x99D1FF, 10), "selected border \(selected(128, 0))")
        #expect(near(hover(262, 29), 0xE5F3FB), "hover \(hover(262, 29))")
        #expect(near(hover(128, 0), 0x70C0E7, 10), "hover border \(hover(128, 0))")
        #expect(plain(262, 29).a == 0)
    }

    /// The tile draws its icon (the fallback glyph without one), the bar and grey text where the layout says.
    @Test func tileDrawsIconBarAndText() {
        let tile = CGRect(x: 0, y: 0, width: 266, height: 58)
        let l = W7ComputerTileLayoutFor(tile)
        let px = render(width: 266, height: 58) {
            W7DrawComputerTile($0, tile, nil, .systemDrive, "Macintosh HD", "117 GB free of 460 GB", 0.75, false, false, false)
        }
        var iconPixels = 0
        for y in Int(l.icon.minY)..<Int(l.icon.maxY) { for x in Int(l.icon.minX)..<Int(l.icon.maxX) where px(x, y).a > 0 { iconPixels += 1 } }
        #expect(iconPixels > 400, "icon \(iconPixels)")
        #expect(near(px(Int(l.bar.minX) + 20, Int(l.bar.midY)), 0x06B025), "bar fill")
        var grey = 0, black = 0
        for y in Int(l.text.minY)..<Int(l.text.maxY) { for x in Int(l.text.minX)..<Int(l.text.minX) + 120 where px(x, y).a > 200 { grey += 1 } }
        for y in Int(l.name.minY)..<Int(l.name.maxY) { for x in Int(l.name.minX)..<Int(l.name.minX) + 80 where px(x, y).a > 200 && px(x, y).r < 60 { black += 1 } }
        #expect(grey > 20, "capacity text \(grey)")
        #expect(black > 20, "name \(black)")
        // No capacity: no bar.
        let none = render(width: 266, height: 58) {
            W7DrawComputerTile($0, tile, nil, .network, "Server", nil, -1, false, false, false)
        }
        #expect(none(Int(l.bar.minX) + 20, Int(l.bar.midY)).a == 0)
    }

    /// A user's icon is drawn instead of the glyph.
    @Test func tileDrawsTheGivenIcon() {
        let cs = CGColorSpace(name: CGColorSpace.sRGB)!
        let src = CGContext(data: nil, width: 48, height: 48, bitsPerComponent: 8, bytesPerRow: 0, space: cs,
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        src.setFillColor(red: 1, green: 0, blue: 0, alpha: 1)
        src.fill(CGRect(x: 0, y: 0, width: 48, height: 48))
        let red = src.makeImage()!
        let tile = CGRect(x: 0, y: 0, width: 266, height: 58)
        let l = W7ComputerTileLayoutFor(tile)
        let px = render(width: 266, height: 58) { W7DrawComputerTile($0, tile, red, .drive, "USB", nil, -1, false, false, false) }
        let p = px(Int(l.icon.midX), Int(l.icon.midY))
        #expect(p.r > 240 && p.g < 20 && p.b < 20, "\(p)")
    }

    /// The new removable and optical fallbacks draw inside their rect; the disc is light, the removable drive grey.
    @Test(arguments: [W7NavPaneGlyph.removableDrive, .opticalDrive])
    func newGlyphsDrawInsideTheirRect(glyph: W7NavPaneGlyph) {
        let px = render(width: 40, height: 40) { W7DrawNavPaneGlyph($0, CGRect(x: 12, y: 12, width: 16, height: 16), glyph) }
        var inside = 0, outside = 0
        for y in 0..<40 { for x in 0..<40 where px(x, y).a > 0 {
            if (11...28).contains(x) && (11...28).contains(y) { inside += 1 } else { outside += 1 }
        } }
        #expect(inside > 40, "\(glyph) drew \(inside) px")
        #expect(outside == 0, "\(glyph) spilled \(outside) px")
    }
}

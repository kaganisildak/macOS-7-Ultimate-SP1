import Testing
import AppKit
import Win7Theme

// the navigation pane's star, tree expander and fallback glyphs.

private func yellow(_ p: Pixel) -> Bool { p.a > 200 && p.r > 200 && p.g > 140 && p.b < 120 }

private func opaqueCount(_ px: (Int, Int) -> Pixel, _ w: Int, _ h: Int) -> Int {
    var n = 0
    for y in 0..<h { for x in 0..<w where px(x, y).a > 128 { n += 1 } }
    return n
}

@Suite struct NavPaneIconTests {
    /// A yellow five-point star: yellow in the middle and in the top point, empty in the corners and
    /// in the notch between the two lower points.
    @Test func favoritesStarIsYellowWithFivePoints() {
        let px = render(width: 32, height: 32) { W7DrawFavoritesStar($0, CGRect(x: 0, y: 0, width: 32, height: 32)) }
        #expect(yellow(px(16, 15)), "centre \(px(16, 15))")
        #expect(px(16, 28).a > 128, "top point \(px(16, 28))")
        #expect(px(1, 1).a == 0 && px(30, 30).a == 0 && px(1, 30).a == 0)
        #expect(px(16, 3).a < 60, "notch between the lower points \(px(16, 3))")
        // Darker at the bottom than at the top (the gradient runs #FFEB73 → #EDA814).
        let top = px(16, 22), bottom = px(16, 9)
        #expect(top.g > bottom.g, "top \(top) bottom \(bottom)")
    }

    /// A non-square rect gets a centred star at the shorter side.
    @Test func favoritesStarIsCentredInWideRects() {
        let px = render(width: 48, height: 16) { W7DrawFavoritesStar($0, CGRect(x: 0, y: 0, width: 48, height: 16)) }
        #expect(yellow(px(24, 7)))
        #expect(px(4, 8).a == 0 && px(43, 8).a == 0)
    }

    /// Collapsed: an outlined ▷ (inside empty). Expanded: a filled, dark ◢ in the lower right.
    @Test func expanderIsOutlinedWhenCollapsedAndFilledWhenExpanded() {
        let collapsed = render(width: 16, height: 16) { W7DrawTreeExpander($0, CGRect(x: 0, y: 0, width: 16, height: 16), false, false) }
        let expanded = render(width: 16, height: 16) { W7DrawTreeExpander($0, CGRect(x: 0, y: 0, width: 16, height: 16), true, false) }
        // ▷: its left edge is drawn, its inside is not.
        #expect(collapsed(6, 8).a > 100, "left edge \(collapsed(6, 8))")
        #expect(collapsed(8, 8).a < 60, "inside \(collapsed(8, 8))")
        // ◢: the lower-right corner area is dark and filled, the upper-left is empty.
        let filled = expanded(9, 6)
        #expect(filled.a > 200 && filled.r < 80 && filled.g < 80 && filled.b < 80, "fill \(filled)")
        #expect(expanded(5, 11).a == 0)
        #expect(opaqueCount(expanded, 16, 16) > 10 && opaqueCount(collapsed, 16, 16) > 10)
    }

    /// Hover turns the glyph blue.
    @Test func expanderHoverIsBlue() {
        let collapsed = render(width: 16, height: 16) { W7DrawTreeExpander($0, CGRect(x: 0, y: 0, width: 16, height: 16), false, true) }
        let p = collapsed(6, 8)
        #expect(p.a > 100 && p.b > p.r + 80, "hover edge \(p)")
        let expanded = render(width: 16, height: 16) { W7DrawTreeExpander($0, CGRect(x: 0, y: 0, width: 16, height: 16), true, true) }
        let q = expanded(9, 6)
        #expect(q.a > 200 && q.b > q.r + 60, "hover fill \(q)")
    }

    /// Every fallback glyph draws something inside its rect and nothing outside it.
    @Test(arguments: [W7NavPaneGlyph.computer, .drive, .systemDrive, .network, .tag, .cloud, .appBadge])
    func glyphDrawsInsideItsRect(glyph: W7NavPaneGlyph) {
        let px = render(width: 40, height: 40) { W7DrawNavPaneGlyph($0, CGRect(x: 12, y: 12, width: 16, height: 16), glyph) }
        var inside = 0, outside = 0
        for y in 0..<40 { for x in 0..<40 where px(x, y).a > 0 {
            if (11...28).contains(x) && (11...28).contains(y) { inside += 1 } else { outside += 1 }
        } }
        #expect(inside > 40, "\(glyph) drew \(inside) px")
        #expect(outside == 0, "\(glyph) spilled \(outside) px")
    }

    /// The globe and the computer screen are blue; the drive is grey.
    @Test func glyphColours() {
        let globe = render(width: 32, height: 32) { W7DrawNavPaneGlyph($0, CGRect(x: 0, y: 0, width: 32, height: 32), .network) }
        let g = globe(10, 12)
        #expect(g.a > 200 && g.b > g.r + 50, "globe \(g)")
        let computer = render(width: 32, height: 32) { W7DrawNavPaneGlyph($0, CGRect(x: 0, y: 0, width: 32, height: 32), .computer) }
        let s = computer(16, 19)
        #expect(s.a > 200 && s.b > s.r + 50, "screen \(s)")
        let drive = render(width: 32, height: 32) { W7DrawNavPaneGlyph($0, CGRect(x: 0, y: 0, width: 32, height: 32), .drive) }
        let d = drive(10, 10)   // the front face, under its top edge
        #expect(d.a > 200 && abs(d.r - d.b) < 30 && d.r > 120, "drive \(d)")
    }
}

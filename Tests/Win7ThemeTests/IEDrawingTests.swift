import Testing
import AppKit
import Win7Theme

// Internet Explorer 7 chrome pieces for Safari (W7IEDrawing.m). Pixel checks in an sRGB
// bitmap; `render` (DrawingTests.swift) samples with the origin at the bottom left.

private func rgb(_ p: Pixel) -> (Int, Int, Int) { (p.r, p.g, p.b) }
private func hex(_ v: UInt32) -> (Int, Int, Int) { (Int(v >> 16 & 0xFF), Int(v >> 8 & 0xFF), Int(v & 0xFF)) }
private func near(_ a: (Int, Int, Int), _ b: (Int, Int, Int), _ tolerance: Int = 3) -> Bool {
    abs(a.0 - b.0) <= tolerance && abs(a.1 - b.1) <= tolerance && abs(a.2 - b.2) <= tolerance
}

@Suite struct IEDrawingTests {
    @Test func tabColourTable() {
        // sampled from the IE8 reference: a #A3A7AC outline with a white inner line on every tab; selected
        // #C3DDFB→#F0F4FB, full height, no bottom line; unselected the row's #E3EEFB, 2 pt lower, on the #8B919F line.
        let normal = W7IETabColorsForState(.normal)
        #expect(normal.top == 0xE3EEFB && normal.bottom == 0xE3EEFB && normal.border == 0xA3A7AC && normal.bottomLine)
        #expect(normal.bottomBorder == 0x8B919F && normal.topInset == 2 && normal.innerLine)
        let selected = W7IETabColorsForState(.selected)
        #expect(selected.top == 0xC3DDFB && selected.bottom == 0xF0F4FB && selected.border == 0xA3A7AC && !selected.bottomLine)
        #expect(selected.topInset == 0 && selected.innerLine)
        let hover = W7IETabColorsForState(.hover)
        #expect(hover.border == 0xA3A7AC && hover.bottomLine && hover.topInset == 2 && hover.innerLine)
        #expect(W7IETabRadius == 2)
        // Hover (not in the reference) is lighter than normal at both ends, and not white.
        func sum(_ v: UInt32) -> Int { Int(v >> 16 & 0xFF) + Int(v >> 8 & 0xFF) + Int(v & 0xFF) }
        #expect(sum(hover.top) > sum(normal.top) && sum(hover.bottom) > sum(normal.bottom))
        #expect(hover.bottom != 0xFFFFFF)
    }

    /// An unselected tab (and the new-tab stub) is an outline on the row: #A3A7AC, the white line inside it, the row's
    /// #E3EEFB within, standing on the #8B919F row line (reference x 340, y 110-134).
    @Test func normalTabHasABorderAllRoundAndRoundedTopCorners() {
        let px = render(width: 80, height: 24) { W7DrawIETab($0, CGRect(x: 0, y: 0, width: 80, height: 24), .normal) }
        #expect(near(rgb(px(40, 0)), hex(0x8B919F), 2))      // bottom line, the row's
        #expect(px(40, 23).a == 0 && px(40, 22).a == 0)      // 2 pt lower than the selected tab
        #expect(near(rgb(px(40, 21)), hex(0xA3A7AC), 2))     // top line
        #expect(near(rgb(px(40, 20)), hex(0xFFFFFF), 2))     // the white line inside it
        #expect(near(rgb(px(0, 12)), hex(0xA3A7AC), 2) && near(rgb(px(1, 12)), hex(0xFFFFFF), 2))   // left side
        #expect(near(rgb(px(79, 12)), hex(0xA3A7AC), 2) && near(rgb(px(78, 12)), hex(0xFFFFFF), 2))  // right side
        #expect(near(rgb(px(40, 18)), hex(0xE3EEFB), 2) && near(rgb(px(40, 2)), hex(0xE3EEFB), 2))  // the row's colour within
        #expect(px(0, 21).a < 128)                            // rounded top-left corner
        #expect(px(0, 0).a == 255)                            // square bottom corner
    }

    @Test func tabRowLineIsOnlyTheLine() {   // test-only now: the band carries the row line in Safari
        let px = render(width: 100, height: 30) { W7DrawIETabRowLine($0, CGRect(x: 0, y: 0, width: 100, height: 30), 4) }
        #expect(near(rgb(px(50, 4)), hex(0x8DA7C8), 1) && px(50, 4).a == 255)
        #expect(px(50, 5).a == 0 && px(50, 3).a == 0 && px(50, 20).a == 0)
    }

    @Test func commandButtonIsFlatUntilHovered() {   // text on the row; a flat 1 px #A0B4CC frame under the pointer
        let normal = render(width: 60, height: 24) { W7DrawIECommandButtonFace($0, CGRect(x: 0, y: 0, width: 60, height: 24), .normal) }
        #expect(normal(30, 12).a == 0 && normal(30, 0).a == 0)
        let hover = render(width: 60, height: 24) { W7DrawIECommandButtonFace($0, CGRect(x: 0, y: 0, width: 60, height: 24), .hover) }
        #expect(hover(30, 12).a == 0)                                                   // no face: flat
        #expect(near(rgb(hover(30, 0)), hex(0xA0B4CC), 3) && hover(30, 0).a == 255)     // its frame
        #expect(near(rgb(hover(0, 12)), hex(0xA0B4CC), 3))
        let pressed = render(width: 60, height: 24) { W7DrawIECommandButtonFace($0, CGRect(x: 0, y: 0, width: 60, height: 24), .pressed) }
        #expect(near(rgb(pressed(30, 12)), hex(0xDCE6F2), 2) && near(rgb(pressed(30, 0)), hex(0xA0B4CC), 3))
    }

    @Test func commandGlyphsAndArrowDraw() {
        let star = render(width: 16, height: 16) { W7DrawIEGlyph($0, CGRect(x: 0, y: 0, width: 16, height: 16), .favorites) }
        #expect(star(8, 8).a == 255 && star(8, 8).r > 200 && star(8, 8).b < 120)        // gold
        #expect(star(0, 0).a == 0)
        for glyph in [W7IEGlyph.addFavorite, .home, .print, .help] {
            let px = render(width: 16, height: 16) { W7DrawIEGlyph($0, CGRect(x: 0, y: 0, width: 16, height: 16), glyph) }
            var painted = 0
            for y in 0..<16 { for x in 0..<16 where px(x, y).a > 0 { painted += 1 } }
            #expect(painted > 40, "\(glyph)")
        }
        let arrow = render(width: 10, height: 10) { W7DrawIEDropArrow($0, CGPoint(x: 5, y: 5)) }
        #expect(arrow(5, 5).a > 0 && arrow(5, 5).r < 60 && arrow(0, 9).a == 0)
    }

    @Test func newTabStubIsABlankUnselectedTab() {   // an #A3A7AC outline on the row's colour, 2 pt lower
        let px = render(width: 30, height: 24) { W7DrawIENewTabStub($0, CGRect(x: 0, y: 0, width: 30, height: 24), false) }
        #expect(near(rgb(px(15, 0)), hex(0x8B919F), 2) && px(15, 23).a == 0)
        #expect(near(rgb(px(15, 21)), hex(0xA3A7AC), 2) && near(rgb(px(15, 10)), hex(0xE3EEFB), 2))
    }

    /// The favourites and tab rows against the values sampled from the IE8 reference (opaque there): a white top line,
    /// #F2F7FD under it fading to #E3EEFB over 12 pt, #E3EEFB down to the #8B919F line under the tabs, #F2F6FB below.
    @Test func tabRowBandMatchesTheIE8Reference() {
        let px = render(width: 200, height: 56) { W7DrawIETabRowBand($0, CGRect(x: 0, y: 0, width: 200, height: 56), 4) }
        #expect(near(rgb(px(100, 55)), hex(0xFFFFFF), 1))   // top line
        #expect(near(rgb(px(100, 54)), hex(0xF2F7FD), 3))   // just under it
        #expect(near(rgb(px(100, 40)), hex(0xE3EEFB), 2))   // after the 12 pt fade: flat
        #expect(near(rgb(px(100, 5)), hex(0xE3EEFB), 2))    // down to the line
        #expect(near(rgb(px(100, 4)), hex(0x8B919F), 1))    // the line at the tabs' bottom edge
        #expect(near(rgb(px(100, 0)), hex(0xF2F6FB), 1))    // the strip above the page
        for y in [0, 4, 20, 55] { #expect(px(100, y).a == 255) }
        let clamped = render(width: 50, height: 10) { W7DrawIETabRowBand($0, CGRect(x: 0, y: 0, width: 50, height: 10), -20) }
        #expect(near(rgb(clamped(25, 0)), hex(0x8B919F), 1))   // a line outside the band is clamped into it
    }

    // MARK: IE8 facsimile tabs

    @Test func facsimileGeometry() {
        let bounds = CGRect(x: 0, y: 0, width: 160, height: 28)
        let close = CGRect(x: 136, y: 6, width: 16, height: 16)
        let normal = W7IETabFacsimileLayoutFor(bounds, .normal, false, close, true)
        #expect(normal.tab == CGRect(x: 0, y: 0, width: 160, height: 26))           // unselected: 2 pt shorter at the top
        #expect(normal.icon == CGRect(x: 6, y: 5, width: 16, height: 16))           // 16 pt at x + 6, centred in the tab
        #expect(normal.close == close)
        #expect(normal.title.minX == 26 && normal.title.maxX == 132)                // after the icon, before the close glyph
        let selected = W7IETabFacsimileLayoutFor(bounds, .selected, false, close, false)
        #expect(selected.tab == bounds && selected.close == .zero)                  // full height; no close shown
        #expect(selected.title.minX == 26 && selected.title.maxX == 154)            // 6 pt before the right edge
        #expect(selected.icon.midY == bounds.midY)
        let pinned = W7IETabFacsimileLayoutFor(CGRect(x: 0, y: 0, width: 40, height: 28), .selected, true, .zero, false)
        #expect(pinned.icon.midX == 20 && pinned.title == .zero)                    // icon only, centred
        #expect(W7IETabFacsimileLayoutFor(.zero, .normal, false, close, true).tab == .zero)
    }

    // MARK: the close at the left (Safari's own position, kept after a back-off) never costs the title

    @Test func facsimileKeepsTheTitleWhenTheCloseIsAtTheLeft() {
        let bounds = CGRect(x: 0, y: 0, width: 160, height: 28)
        let overIcon = CGRect(x: 6, y: 6, width: 16, height: 16)                    // Safari's ×: over the favicon
        let l = W7IETabFacsimileLayoutFor(bounds, .selected, false, overIcon, true)
        #expect(l.close == overIcon)
        #expect(l.icon == .zero)                                                    // the × wins: no icon under it
        #expect(l.title.minX == 26 && l.title.maxX == 154)                          // after the ×, to 6 pt before the edge
        let beforeTitle = CGRect(x: 24, y: 6, width: 16, height: 16)                // left of the title start, clear of the icon
        let l2 = W7IETabFacsimileLayoutFor(bounds, .selected, false, beforeTitle, true)
        #expect(l2.icon == CGRect(x: 6, y: 6, width: 16, height: 16) && l2.title.minX == 44 && l2.title.maxX == 154)
        let right = CGRect(x: 138, y: 6, width: 16, height: 16)                     // moved to the right end: as before
        let l3 = W7IETabFacsimileLayoutFor(bounds, .selected, false, right, true)
        #expect(l3.icon == CGRect(x: 6, y: 6, width: 16, height: 16) && l3.title.minX == 26 && l3.title.maxX == 134)
        // Never an empty title room when the tab is wider than icon + close + 24, wherever the × is.
        for width in stride(from: 57, through: 300, by: 7) {
            let b = CGRect(x: 0, y: 0, width: CGFloat(width), height: 28)
            for close in [overIcon, CGRect(x: b.maxX - 22, y: 6, width: 16, height: 16)] {
                for state in [W7IETabState.normal, .selected] {
                    #expect(!W7IETabFacsimileLayoutFor(b, state, false, close, true).title.isEmpty, "width \(width) close \(close)")
                }
            }
        }
    }

    @Test func closeGlyphSpansTenPoints() {   // a 10 pt ×, #6E6E6E, red under the pointer
        let px = render(width: 20, height: 20) { W7DrawIETabCloseGlyph($0, CGRect(x: 0, y: 0, width: 20, height: 20), false) }
        #expect(px(5, 5).a > 150 && px(14, 14).a > 150 && px(5, 14).a > 150)       // the arms reach 5 pt from the centre
        #expect(px(2, 2).a == 0 && px(10, 3).a == 0)
        #expect(near(rgb(px(10, 10)), hex(0x6E6E6E), 8))
        let hover = render(width: 20, height: 20) { W7DrawIETabCloseGlyph($0, CGRect(x: 0, y: 0, width: 20, height: 20), true) }
        #expect(near(rgb(hover(10, 10)), hex(0xC75050), 8))
    }

    /// IE's generic page icon: a white page with a folded top-right corner, a 1 px #7A8A9E
    /// outline and three short grey text lines, in 16 pt.
    @Test func pageIconIsAWhitePageWithAnOutline() {
        let px = render(width: 16, height: 16) { W7DrawIEPageIcon($0, CGRect(x: 0, y: 0, width: 16, height: 16)) }
        #expect(near(rgb(px(6, 11)), hex(0xFFFFFF), 1) && px(6, 11).a == 255)        // the page, white
        #expect(near(rgb(px(3, 8)), hex(0x7A8A9E), 3) && near(rgb(px(8, 1)), hex(0x7A8A9E), 3))   // left and bottom outline
        #expect(px(0, 0).a == 0 && px(15, 15).a == 0 && px(12, 14).a == 0)           // outside; the folded corner is cut off
        var grey = 0                                                                 // the text lines: grey inside the page
        for y in 3..<10 { for x in 5..<11 where px(x, y).a == 255 && px(x, y).r < 200 && abs(px(x, y).r - px(x, y).b) < 12 { grey += 1 } }
        #expect(grey >= 9)
    }

    @Test func titlesAreTruncatedInTheMiddle() {
        let font = W7UIFont(12)
        let title = "Internet Explorer 8 – Wikipedia, the free encyclopedia"
        let width = (title as NSString).size(withAttributes: [.font: font]).width
        #expect(W7IEMiddleTruncatedTitle(title, width + 1, font) == title)          // fits: as it is
        let short = W7IEMiddleTruncatedTitle(title, 120, font)
        #expect(short.contains("…") && short != title)
        #expect((short as NSString).size(withAttributes: [.font: font]).width <= 120)
        let parts = short.components(separatedBy: "…")
        #expect(parts.count == 2 && title.hasPrefix(parts[0]) && title.hasSuffix(parts[1]) && !parts[0].isEmpty && !parts[1].isEmpty)
        #expect(abs(parts[0].count - parts[1].count) <= 1)                          // the middle goes
        #expect(W7IEMiddleTruncatedTitle(title, 2, font) == "")                    // not even "…"
        #expect(W7IEMiddleTruncatedTitle(nil, 100, font) == "")
    }

    @Test func facsimileTabDrawsShapeTitleAndClose() {
        let bounds = CGRect(x: 0, y: 0, width: 160, height: 28)
        let close = CGRect(x: 136, y: 6, width: 16, height: 16)
        let selected = render(width: 160, height: 28) {
            W7DrawIETabFacsimile($0, bounds, .selected, false, nil, "Wikipedia", .null, close, .normal)
        }
        #expect(near(rgb(selected(80, 0)), hex(0xF0F4FB), 3))                       // the gradient's bottom, open to the page
        #expect(near(rgb(selected(80, 25)), hex(0xC3DDFB), 4))                      // its top
        #expect(near(rgb(selected(80, 27)), hex(0xA3A7AC), 2) && near(rgb(selected(80, 26)), hex(0xFFFFFF), 2))
        #expect(near(rgb(selected(0, 14)), hex(0xA3A7AC), 2))
        var dark = 0                                                                // the title: black text after the icon
        for y in 6..<22 { for x in 26..<90 where selected(x, y).r < 80 && selected(x, y).a == 255 { dark += 1 } }
        #expect(dark > 20)
        let glyph = selected(144, 14)                                               // the close glyph, grey
        #expect(abs(glyph.r - 0x6E) <= 30 && abs(glyph.r - glyph.b) <= 6, "\(glyph)")
        let hover = render(width: 160, height: 28) {
            W7DrawIETabFacsimile($0, bounds, .selected, false, nil, "Wikipedia", .null, close, .hover)
        }
        #expect(hover(144, 14).r > hover(144, 14).b + 60)                           // red under the pointer
        let normal = render(width: 160, height: 28) { W7DrawIETabFacsimile($0, bounds, .normal, false, nil, "", .null, close, .hidden) }
        #expect(normal(80, 27).a == 0 && normal(80, 26).a == 0)                     // 2 pt shorter
        #expect(near(rgb(normal(80, 0)), hex(0x8B919F), 2))                         // stands on the row's line
        #expect(near(rgb(normal(80, 22)), hex(0xE3EEFB), 3) && near(rgb(normal(80, 3)), hex(0xE3EEFB), 3))   // the row within
        #expect(near(rgb(normal(144, 14)), rgb(normal(120, 14)), 2))                 // no glyph when Safari shows none
        // The title is drawn as given, in the given room (the caller shortens it): nothing outside that room.
        let room = render(width: 160, height: 28) {
            W7DrawIETabFacsimile($0, bounds, .selected, false, nil, "Wikipedia Wikipedia Wikipedia",
                                 CGRect(x: 26, y: 0, width: 40, height: 28), .zero, .hidden)
        }
        var outside = 0
        for y in 6..<22 { for x in 68..<150 where room(x, y).r < 120 { outside += 1 } }
        #expect(outside == 0)
    }

    @Test func titleRoomAvoidsTheTabsOtherControls() {
        let title = CGRect(x: 26, y: 0, width: 106, height: 26)
        #expect(W7IETabTitleRectAvoiding(title, nil, 0) == title)
        let right = [CGRect(x: 112, y: 7, width: 12, height: 12)]                  // an audio button at the right
        #expect(W7IETabTitleRectAvoiding(title, right, 1) == CGRect(x: 26, y: 0, width: 82, height: 26))
        let left = [CGRect(x: 24, y: 7, width: 12, height: 12)]                    // one at the left
        #expect(W7IETabTitleRectAvoiding(title, left, 1) == CGRect(x: 40, y: 0, width: 92, height: 26))
        let outside = [CGRect(x: 140, y: 7, width: 12, height: 12)]
        #expect(W7IETabTitleRectAvoiding(title, outside, 1) == title)
        #expect(W7IETabTitleRectAvoiding(CGRect(x: 0, y: 0, width: 10, height: 26), [CGRect(x: 4, y: 0, width: 4, height: 4)], 1) == .zero)
    }

    @Test func accessoryGlyphsDraw() {
        for kind in [W7IETabAccessory.speaker, .generic] {
            let px = render(width: 16, height: 16) { W7DrawIETabAccessoryGlyph($0, CGRect(x: 0, y: 0, width: 16, height: 16), kind) }
            var painted = 0
            for y in 0..<16 { for x in 0..<16 where px(x, y).a > 0 { painted += 1; #expect(px(x, y).r < 140) } }
            #expect(painted > 15, "\(kind)")
            #expect(px(0, 0).a == 0 && px(15, 15).a == 0)                           // 12 pt, centred
        }
    }

    @Test func selectedTabIsBlueWithoutABottomLine() {   // reference x 150, y 108-135
        let px = render(width: 80, height: 24) { W7DrawIETab($0, CGRect(x: 0, y: 0, width: 80, height: 24), .selected) }
        #expect(near(rgb(px(40, 0)), hex(0xF0F4FB), 3))
        #expect(near(rgb(px(40, 21)), hex(0xC3DDFB), 4))
        #expect(near(rgb(px(40, 23)), hex(0xA3A7AC), 2) && near(rgb(px(40, 22)), hex(0xFFFFFF), 2))
        #expect(near(rgb(px(0, 2)), hex(0xA3A7AC), 2) && near(rgb(px(1, 2)), hex(0xFFFFFF), 2))   // the sides run to the bottom
    }

    @Test func hoverTabIsLighterThanNormal() {
        let normal = render(width: 80, height: 24) { W7DrawIETab($0, CGRect(x: 0, y: 0, width: 80, height: 24), .normal) }(40, 4)
        let hover = render(width: 80, height: 24) { W7DrawIETab($0, CGRect(x: 0, y: 0, width: 80, height: 24), .hover) }(40, 4)
        #expect(hover.r + hover.g + hover.b > normal.r + normal.g + normal.b)
    }

    @Test func statusBarIsGreyWithATopLine() {
        #expect(W7IEStatusBarHeight == 22)
        #expect(W7IEProgressWidth == 100)
        let px = render(width: 300, height: 22) { W7DrawIEStatusBar($0, CGRect(x: 0, y: 0, width: 300, height: 22)) }
        #expect(near(rgb(px(150, 21)), hex(0xA0A0A0), 1))
        #expect(near(rgb(px(150, 20)), hex(0xF0F0F0), 2))
        #expect(near(rgb(px(150, 0)), hex(0xE3E3E3), 2))
    }

    @Test func progressFillsItsFraction() {
        let px = render(width: 100, height: 14) { W7DrawIEProgress($0, CGRect(x: 0, y: 0, width: 100, height: 14), 0.5) }
        let filled = px(25, 7), empty = px(75, 7)
        #expect(filled.g > filled.r + 40 && filled.g > filled.b + 40)   // green bar
        #expect(abs(empty.r - empty.g) < 8 && abs(empty.g - empty.b) < 8 && empty.r > 200)   // light grey trough
        let full = render(width: 100, height: 14) { W7DrawIEProgress($0, CGRect(x: 0, y: 0, width: 100, height: 14), 2) }(90, 7)
        #expect(full.g > full.r + 40)   // clamped to 1
        let none = render(width: 100, height: 14) { W7DrawIEProgress($0, CGRect(x: 0, y: 0, width: 100, height: 14), -1) }(25, 7)
        #expect(abs(none.r - none.g) < 8)   // clamped to 0: the trough only
    }

    @Test func navOrbsDrawBothOrbsWithDisabledGrey() {
        #expect(W7IEBackOrbSize == 28 && W7IEForwardOrbSize == 24)
        let size = W7IENavOrbsSize()
        #expect(size.width == 28 + 24 - 1 && size.height == 28)
        let on = render(width: Int(size.width), height: Int(size.height)) {
            W7DrawIENavOrbs($0, CGRect(origin: .zero, size: size), true, true)
        }
        let off = render(width: Int(size.width), height: Int(size.height)) {
            W7DrawIENavOrbs($0, CGRect(origin: .zero, size: size), true, false)
        }
        let back = on(8, 10), fwdOn = on(44, 9), fwdOff = off(44, 9)
        #expect(back.b > back.r + 40)                       // blue back orb
        #expect(fwdOn.b > fwdOn.r + 40)                     // blue forward orb
        #expect(abs(fwdOff.b - fwdOff.r) < 50 && fwdOff.r > fwdOn.r)   // grey when disabled
    }

    /// The overlay's capsule is opaque across its whole width, so the native glyphs under it never show.
    @Test func navCapsuleIsOpaqueAcrossTheControl() {
        let px = render(width: 90, height: 28) { W7DrawIENavCapsule($0, CGRect(x: 0, y: 0, width: 90, height: 28)) }
        for x in [14, 45, 76] { #expect(px(x, 14).a == 255, "x \(x)") }
        #expect(px(0, 27).a < 128)   // rounded ends
    }

    @Test func orbImageHasOneAndTwoTimesRepresentations() {
        let back = W7CreateIENavOrbImage(false, 1)
        let back2 = W7CreateIENavOrbImage(false, 2)
        #expect(back?.width == 28 && back?.height == 28)
        #expect(back2?.width == 56 && back2?.height == 56)
        let fwd = W7CreateIENavOrbImage(true, 2)
        #expect(fwd?.width == 48)
        #expect(W7CreateIENavOrbImage(true, 0) == nil)
    }

    // a command glyph drawn disabled (✚ when Safari's validation turns Add Bookmark… off).
    /// Disabled = the same shape at 40 % alpha and greyed: nothing opaque, the star's centre faded and near-grey.
    @Test func disabledGlyphIsFadedAndGreyed() {
        let px = render(width: 16, height: 16) { W7DrawIEGlyphDisabled($0, CGRect(x: 0, y: 0, width: 16, height: 16), .addFavorite) }
        var opaque = 0, faded = 0
        for y in 0..<16 { for x in 0..<16 {
            if px(x, y).a == 255 { opaque += 1 }
            if px(x, y).a > 60 && px(x, y).a < 130 { faded += 1 }
        } }
        #expect(opaque == 0 && faded > 30, "opaque \(opaque) faded \(faded)")
        let centre = px(7, 9)
        #expect(centre.a > 60 && centre.a < 130)
        #expect(abs(centre.r - centre.b) < 80, "\(centre)")   // greyed (≈ 54 expected), not the gold star (180)
        let normal = render(width: 16, height: 16) { W7DrawIEGlyph($0, CGRect(x: 0, y: 0, width: 16, height: 16), .addFavorite) }
        #expect(normal(7, 9).a == 255 && normal(7, 9).r - normal(7, 9).b > 100)
    }
}

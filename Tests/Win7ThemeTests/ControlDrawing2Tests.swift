import Testing
import AppKit
import Win7Theme

/// controls slice 2: the drawing primitives (W7ControlDrawing2.m).
@Suite struct ControlDrawing2Tests {
    func near(_ p: Pixel, _ hex: Int, _ tol: Int = 6) -> Bool {
        abs(p.r - (hex >> 16 & 0xFF)) <= tol && abs(p.g - (hex >> 8 & 0xFF)) <= tol && abs(p.b - (hex & 0xFF)) <= tol && p.a >= 240
    }

    /// Text and search fields: white, a 1 pt #ABADB3 border, #3399FF when focused, grey when disabled.
    @Test func textFieldBox() {
        let r = CGRect(x: 0, y: 0, width: 100, height: 22)
        let normal = render(width: 100, height: 22) { W7DrawTextFieldBox($0, r, false, true) }
        #expect(near(normal(50, 0), 0xABADB3) && near(normal(0, 11), 0xABADB3) && near(normal(99, 11), 0xABADB3), "\(normal(50, 0))")
        #expect(near(normal(50, 11), 0xFFFFFF, 0), "fill \(normal(50, 11))")
        let focused = render(width: 100, height: 22) { W7DrawTextFieldBox($0, r, true, true) }
        #expect(near(focused(50, 21), 0x3399FF) && near(focused(0, 11), 0x3399FF), "\(focused(50, 21))")
        let disabled = render(width: 100, height: 22) { W7DrawTextFieldBox($0, r, false, false) }
        #expect(disabled(50, 11).r < 250 && disabled(50, 11).r == disabled(50, 11).b, "disabled fill \(disabled(50, 11))")
    }

    /// Pop-up button (Windows 7 combo): the push-button look, light top band over a darker bottom band,
    /// #707070 border, and a ▾ in a well at the right end.
    @Test func comboBox() {
        let r = CGRect(x: 0, y: 0, width: 120, height: 22)
        let px = render(width: 120, height: 22) { W7DrawComboBox($0, r, .normal) }
        #expect(near(px(60, 0), 0x707070, 10), "border \(px(60, 0))")
        let top = px(40, 16), bottom = px(40, 5)
        #expect(top.r > bottom.r + 8 && top.r >= 230, "bands \(top) \(bottom)")
        // The arrow: dark pixels near the middle of the well, none in the text area's middle.
        var arrow = 0
        for x in 104..<116 { for y in 7..<15 where px(x, y).r < 80 { arrow += 1 } }
        #expect(arrow >= 6, "arrow pixels \(arrow)")
        let hover = render(width: 120, height: 22) { W7DrawComboBox($0, r, .hover) }
        #expect(hover(60, 0).b > hover(60, 0).r + 40, "hover border is blue \(hover(60, 0))")
    }

    /// Tabs: unselected #F0F0F0 with a #8C8C8C border, selected white, joined to the white pane below.
    @Test func tabs() {
        let r = CGRect(x: 0, y: 0, width: 60, height: 22)
        let un = render(width: 60, height: 22) { W7DrawTabItem($0, r, false, false) }
        #expect(near(un(30, 10), 0xF0F0F0, 3) && near(un(0, 10), 0x8C8C8C, 8) && near(un(30, 21), 0x8C8C8C, 8), "\(un(30, 10))")
        let sel = render(width: 60, height: 22) { W7DrawTabItem($0, r, true, false) }
        #expect(near(sel(30, 10), 0xFFFFFF, 0) && near(sel(30, 0), 0xFFFFFF, 0), "selected \(sel(30, 10)) bottom open \(sel(30, 0))")
        let hover = render(width: 60, height: 22) { W7DrawTabItem($0, r, false, true) }
        #expect(hover(30, 10).b > hover(30, 10).r + 6, "hover \(hover(30, 10))")
        let pane = render(width: 100, height: 60) { W7DrawTabPane($0, CGRect(x: 0, y: 0, width: 100, height: 60)) }
        #expect(near(pane(50, 30), 0xFFFFFF, 0) && near(pane(0, 30), 0x8C8C8C, 8) && near(pane(50, 59), 0x8C8C8C, 8))
    }

    /// Progress bar: a grey #BCBCBC trough with the green #06B025 fill up to the fraction, glossy on top.
    @Test func progressBar() {
        let r = CGRect(x: 0, y: 0, width: 200, height: 16)
        let px = render(width: 200, height: 16) { W7DrawProgressBar($0, r, 0.4) }
        #expect(near(px(100, 0), 0xBCBCBC, 8), "trough border \(px(100, 0))")
        let fill = px(40, 5), gloss = px(40, 12), empty = px(150, 8)
        #expect(abs(fill.r - 0x06) <= 20 && abs(fill.g - 0xB0) <= 20 && abs(fill.b - 0x25) <= 20, "fill \(fill)")
        #expect(gloss.r > fill.r + 30, "gloss \(gloss)")
        #expect(empty.g < 250 && abs(empty.r - empty.g) <= 4, "empty trough \(empty)")
        let none = render(width: 200, height: 16) { W7DrawProgressBar($0, r, -1) }
        #expect(abs(none(40, 5).r - none(40, 5).g) <= 4, "no fill below 0")
        let full = render(width: 200, height: 16) { W7DrawProgressBar($0, r, 2) }
        #expect(full(196, 5).g > full(196, 5).r + 80, "clamped to full \(full(196, 5))")
    }

    /// Slider: a thin recessed track and a raised thumb; hover and pressed thumbs are blue.
    @Test func slider() {
        let track = render(width: 120, height: 22) { W7DrawSliderTrack($0, CGRect(x: 0, y: 0, width: 120, height: 22)) }
        #expect(track(60, 11).a >= 240 && track(60, 2).a == 0, "a 4 pt channel in the middle")
        let thumb = CGRect(x: 0, y: 0, width: 11, height: 21)
        let n = render(width: 11, height: 21) { W7DrawSliderThumb($0, thumb, .normal) }
        let h = render(width: 11, height: 21) { W7DrawSliderThumb($0, thumb, .hover) }
        #expect(near(n(5, 0), 0x707070, 12), "border \(n(5, 0))")
        #expect(abs(n(5, 10).r - n(5, 10).b) <= 8 && n(5, 10).r >= 200, "grey body \(n(5, 10))")
        #expect(h(5, 10).b > h(5, 10).r + 10, "hover body \(h(5, 10))")
    }

    /// Group box: an etched #D5DFE5 line with a gap for the title at the top left.
    @Test func groupBox() {
        let r = CGRect(x: 0, y: 0, width: 160, height: 80)
        let px = render(width: 160, height: 80) { W7DrawGroupBox($0, r, 40) }
        #expect(near(px(0, 40), 0xD5DFE5, 4) && near(px(80, 0), 0xD5DFE5, 4), "line \(px(0, 40))")
        #expect(near(px(100, 79), 0xD5DFE5, 4), "top line right of the title \(px(100, 79))")
        #expect(px(20, 79).a == 0, "gap for the title \(px(20, 79))")
        #expect(px(80, 40).a == 0, "inside is clear")
    }
}

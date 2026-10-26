import AppKit
import Testing
import Win7Theme

/// The Start menu's chrome, as the Windows 7 SP1 reference screenshot shows it.
@Suite struct StartMenuDrawingTests {
    let bounds = CGRect(x: 0, y: 0, width: 400, height: 535)

    /// Geometry shared by the shell's Start menu and the render tool.
    @Test func sharedGeometry() {
        #expect(W7StartMenuSearchBandHeight == 44)
        #expect(W7StartMenuSearchBoxRect(bounds, 250) == CGRect(x: 16, y: 18, width: 226, height: 24))
        #expect(W7StartMenuUserTileRect(bounds, 250) == CGRect(x: 301, y: 473, width: 48, height: 48))
        #expect(W7StartMenuPlacesTop(true) == 78 && W7StartMenuPlacesTop(false) == 16)
    }

    /// While searching, an × replaces the magnifier (Windows 7's clear button).
    @Test func searchBoxClearButton() {
        let r = CGRect(x: 0, y: 0, width: 200, height: 24)
        let clear = render(width: 200, height: 24) { W7DrawSearchBox($0, r, true, true) }
        let glass = render(width: 200, height: 24) { W7DrawSearchBox($0, r, true, false) }
        #expect(clear(188, 11).r < 150, "× centre \(clear(188, 11))")
        #expect(glass(188, 13).r > 230, "inside the magnifier ring \(glass(188, 13))")
    }

    @Test func programsPaneIsInsetInTheGlass() {
        #expect(W7StartMenuProgramsRect(bounds, 250) == CGRect(x: 8, y: 8, width: 242, height: 517))
    }

    @Test func backgroundColours() {
        let px = render(width: 400, height: 535) { W7DrawStartMenuBackground($0, bounds, 250, 44) }
        let glass = px(330, 200), margin = px(3, 200)
        #expect(glass.a >= 210 && glass.b > glass.r + 30 && glass.r < 70, "right pane glass \(glass)")
        #expect(margin.a >= 210 && margin.r < 90, "glass margin left of the pane \(margin)")
        let list = px(120, 300)
        #expect(list.r == 255 && list.g == 255 && list.b == 255, "programs list \(list)")
        let band = px(120, 30), bandTop = px(120, 8 + 44 - 1)
        #expect(abs(band.r - 0xF1) <= 2 && abs(band.g - 0xF5) <= 2 && abs(band.b - 0xFB) <= 2, "search band \(band)")
        #expect(abs(bandTop.r - 0xD3) <= 3 && abs(bandTop.b - 0xED) <= 3, "band top line \(bandTop)")
        let border = px(8, 300)
        #expect(abs(border.r - 0x9D) <= 8 && abs(border.g - 0xB2) <= 8 && abs(border.b - 0xBF) <= 8, "pane border \(border)")
    }

    @Test func separatorIsAGroove() {
        let px = render(width: 100, height: 10) { W7DrawStartMenuSeparator($0, 10, 90, 5) }
        #expect(px(50, 5).a >= 60 && px(50, 5).r < 20, "dark line \(px(50, 5))")
        #expect(px(50, 4).a >= 30 && px(50, 4).r > 230, "light line \(px(50, 4))")
        #expect(px(5, 5).a == 0)
    }

    @Test func userTileFrameRingsThePicture() {
        let pic = CGRect(x: 10, y: 10, width: 48, height: 48)
        let px = render(width: 68, height: 68) { W7DrawUserTileFrame($0, pic) }
        let ring = px(34, 62)   // in the ring above the picture
        #expect(ring.a >= 120 && ring.r > 200, "ring \(ring)")
        #expect(px(0, 0).a == 0, "rounded corner")
    }

    @Test func searchBoxHasMagnifier() {
        let px = render(width: 200, height: 24) { W7DrawSearchBox($0, CGRect(x: 0, y: 0, width: 200, height: 24), false, false) }
        #expect(px(100, 12).r == 255 && px(100, 12).a == 255)
        var dark = 0
        for x in 180..<199 { for y in 4..<20 where px(x, y).r < 120 { dark += 1 } }
        #expect(dark >= 10, "magnifier pixels \(dark)")
    }
}

@Test func leftChevronPointsLeft() {
    let px = render(width: 10, height: 10) { W7DrawChevron($0, CGPoint(x: 5, y: 5), .left, 0x000000, 1) }
    #expect(px(4, 5).a > 150 && px(6, 7).a > 150 && px(6, 2).a > 150, "base on the right, tip on the left")
    #expect(px(3, 8).a < 40)
}

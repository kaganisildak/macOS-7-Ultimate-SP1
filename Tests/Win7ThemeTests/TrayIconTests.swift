import Testing
import AppKit
import Win7Theme

private func icon(_ kind: W7TrayIcon, level: Int, flag: Bool = false) -> (Int, Int) -> Pixel {
    render(width: 16, height: 16) { W7DrawTrayIcon($0, CGRect(x: 0, y: 0, width: 16, height: 16), kind, level, flag) }
}

private func anyPixel(_ px: (Int, Int) -> Pixel, _ test: (Pixel) -> Bool) -> Bool {
    for y in 0..<16 { for x in 0..<16 where test(px(x, y)) { return true } }
    return false
}

private func redDominant(_ p: Pixel) -> Bool { p.a > 128 && p.r > 150 && p.r > p.g * 2 && p.r > p.b * 2 }

@Suite struct TrayIconTests {
    /// The tallest Wi-Fi bar sits at the top right of the icon.
    @Test func wifiFullHasLightTopRightBar() {
        let p = icon(.wifi, level: 4)(13, 12)
        #expect(p.a > 128 && p.r > 200 && p.g > 200 && p.b > 200)
    }

    @Test func wifiZeroTopRightBarIsDim() {
        let p = icon(.wifi, level: 0)(13, 12)
        #expect(p.a < 128 || (p.r < 200 && p.g < 200 && p.b < 200))
    }

    @Test func disconnectedHasRedCross() {
        #expect(anyPixel(icon(.disconnected, level: 0), redDominant))
    }

    @Test func mutedVolumeHasRedMark() {
        #expect(anyPixel(icon(.volume, level: 0), redDominant))
        #expect(!anyPixel(icon(.volume, level: 4), redDominant))
    }

    @Test func everyIconDrawsSomething() {
        for kind in [W7TrayIcon.wifi, .wired, .disconnected, .noNetwork, .volume, .battery, .chevron] {
            #expect(anyPixel(icon(kind, level: 4)) { $0.a > 128 })
        }
    }

    // MARK: Action Center flag

    private func flag(_ hasMessages: Bool) -> (Int, Int) -> Pixel {
        render(width: 16, height: 16) { W7DrawActionCenterFlag($0, CGRect(x: 0, y: 0, width: 16, height: 16), hasMessages) }
    }

    /// The flag cloth is white, up and right of the pole.
    @Test func actionCenterFlagIsWhite() {
        let p = flag(false)(7, 11)
        #expect(p.a > 200 && p.r > 220 && p.g > 220 && p.b > 220)
    }

    @Test func actionCenterBadgeOnlyWithMessages() {
        #expect(!anyPixel(flag(false), redDominant))
        #expect(anyPixel(flag(true), redDominant))
        // The badge sits in the bottom-right quadrant, and nowhere else.
        let px = flag(true)
        var bottomRight = false, elsewhere = false
        for y in 0..<16 { for x in 0..<16 where redDominant(px(x, y)) {
            if x >= 8 && y < 8 { bottomRight = true } else if x < 6 || y > 9 { elsewhere = true }
        } }
        #expect(bottomRight && !elsewhere)
    }

    @Test func actionCenterFlagScalesToRect() {
        let px = render(width: 32, height: 32) { W7DrawActionCenterFlag($0, CGRect(x: 0, y: 0, width: 32, height: 32), false) }
        let p = px(14, 22)
        #expect(p.a > 200 && p.r > 220)
    }

    // MARK: Network list signal bars

    private func bars(_ n: Int) -> (Int, Int) -> Pixel {
        render(width: 20, height: 16) { W7DrawSignalBars($0, CGRect(x: 0, y: 0, width: 20, height: 16), n) }
    }

    private func green(_ p: Pixel) -> Bool { p.a > 128 && p.g > 120 && p.g > p.r + 30 && p.g > p.b + 30 }

    /// Five ascending bars: the tallest (right) is lit only at full signal; unlit bars are grey.
    @Test func signalBarsLightFromTheLeft() {
        #expect(green(bars(5)(18, 13)))
        #expect(!green(bars(4)(18, 13)) && bars(4)(18, 13).a > 60)
        #expect(green(bars(1)(2, 2)))
        #expect(!green(bars(0)(2, 2)))
        #expect(!anyPixel(bars(0), green))
    }
}

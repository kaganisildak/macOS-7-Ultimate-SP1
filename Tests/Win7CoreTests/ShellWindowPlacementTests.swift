import CoreGraphics
import Testing
@testable import Win7Core

// The shell's framed windows (Control Panel, Device Manager, Devices and Printers) open inside the
// work area. AppKit coordinates (bottom-left origin); `usable` is each screen's visible frame, on the taskbar's
// screen ending at the bar's top edge (WorkArea.visible).

@Suite struct ShellWindowPlacementTests {
    let main = CGRect(x: 0, y: 40, width: 1440, height: 835)        // 40 pt taskbar along the bottom
    let side = CGRect(x: -1920, y: 0, width: 1920, height: 1055)    // a display left of the primary

    @Test func aFrameInsideTheWorkAreaStays() {
        let f = CGRect(x: 100, y: 200, width: 780, height: 560)
        #expect(ShellWindowPlacement.frame(current: f, defaultSize: CGSize(width: 780, height: 560), usable: [main, side],
                                           main: main) == nil)
        let onSide = CGRect(x: -1500, y: 100, width: 520, height: 460)
        #expect(ShellWindowPlacement.frame(current: onSide, defaultSize: onSide.size, usable: [main, side], main: main) == nil)
    }

    @Test func anOffScreenFrameIsCentredOnTheMainScreenAtTheDefaultSize() {
        let gone = CGRect(x: 5000, y: 5000, width: 300, height: 200)
        let f = ShellWindowPlacement.frame(current: gone, defaultSize: CGSize(width: 520, height: 460), usable: [main, side],
                                           main: main)
        #expect(f == CGRect(x: 460, y: 227.5, width: 520, height: 460))
        // A sliver on screen (less than 100 × 60) counts as off screen.
        let sliver = CGRect(x: 1400, y: 500, width: 300, height: 200)
        #expect(ShellWindowPlacement.frame(current: sliver, defaultSize: CGSize(width: 520, height: 460), usable: [main],
                                           main: main)?.size == CGSize(width: 520, height: 460))
        // A default size taller than the work area starts at its bottom, never under the bar.
        let tall = ShellWindowPlacement.frame(current: gone, defaultSize: CGSize(width: 520, height: 2000), usable: [main],
                                              main: main)
        #expect(tall?.minY == main.minY && tall?.height == main.height)
    }

    @Test func aFrameReachingUnderTheTaskbarMovesUp() {
        let low = CGRect(x: 100, y: 10, width: 780, height: 560)
        #expect(ShellWindowPlacement.frame(current: low, defaultSize: low.size, usable: [main], main: main)
                == CGRect(x: 100, y: 40, width: 780, height: 560))
        // Taller than the work area: clamped to it, x and width kept.
        let tall = CGRect(x: 100, y: 0, width: 780, height: 1000)
        #expect(ShellWindowPlacement.frame(current: tall, defaultSize: tall.size, usable: [main], main: main)
                == CGRect(x: 100, y: 40, width: 780, height: 835))
        // Its title bar above the top of the work area: brought down.
        let high = CGRect(x: 100, y: 500, width: 780, height: 560)
        #expect(ShellWindowPlacement.frame(current: high, defaultSize: high.size, usable: [main], main: main)
                == CGRect(x: 100, y: 315, width: 780, height: 560))
    }

    @Test func theWorkAreaHoldingAFrame() {
        // Its centre's area, else the one it overlaps most; none when it is on no screen.
        #expect(ShellWindowPlacement.area(holding: CGRect(x: -1500, y: 100, width: 520, height: 460), in: [main, side]) == side)
        #expect(ShellWindowPlacement.area(holding: CGRect(x: -100, y: 300, width: 600, height: 200), in: [main, side]) == main)
        #expect(ShellWindowPlacement.area(holding: CGRect(x: -2100, y: 300, width: 400, height: 200), in: [main, side]) == side)
        #expect(ShellWindowPlacement.area(holding: CGRect(x: 5000, y: 5000, width: 300, height: 200), in: [main, side]) == nil)
        #expect(ShellWindowPlacement.area(holding: CGRect(x: 100, y: 100, width: 10, height: 10), in: [.zero, main]) == main)
        #expect(ShellWindowPlacement.area(holding: CGRect(x: 100, y: 100, width: 10, height: 10), in: []) == nil)
    }

    @Test func noScreensLeavesTheFrameAlone() {
        let f = CGRect(x: 5000, y: 5000, width: 300, height: 200)
        #expect(ShellWindowPlacement.frame(current: f, defaultSize: f.size, usable: [], main: nil) == nil)
    }
}

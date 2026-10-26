import AppKit
import CoreGraphics
import Foundation
import Testing
import Win7ChromeCore
import Win7Core
import Win7Theme

/// micro-benchmarks: each times N iterations of a cached or narrowed path against what it
/// replaced, prints both medians ("bench:" lines), asserts that the new path is the faster one, and
/// asserts a generous absolute bound of about 10x the median measured on the development machine.
///
/// They run only with W7_BENCHMARKS=1, which `make test` sets; a bare `swift test` skips them.
///
/// They run in their own test product, one at a time: heavy CoreGraphics loops running in parallel
/// with the pixel-asserting tests of another suite disturbed those tests' renders (seen with
/// WallpaperTests), and timings are steadier without neighbours.
@Suite(.serialized, .enabled(if: ProcessInfo.processInfo.environment["W7_BENCHMARKS"] == "1",
                              "timing benchmarks run under make test (W7_BENCHMARKS=1)"))
struct Benchmarks {
    private static func median(runs: Int = 9, _ body: () -> Void) -> TimeInterval {
        body()   // warm-up
        var times: [TimeInterval] = []
        for _ in 0..<runs {
            let t0 = DispatchTime.now().uptimeNanoseconds
            body()
            times.append(TimeInterval(DispatchTime.now().uptimeNanoseconds - t0) / 1e9)
        }
        return times.sorted()[times.count / 2]
    }
    private static func ms(_ t: TimeInterval) -> String { String(format: "%.3f", t * 1000) }

    // MARK: Shell logic (Win7Core)

    /// Grouping a 400-window CGWindowList result for 30 apps in one pass (the on-screen snapshot) vs
    /// one pass per app (what the stack refresh did on the main thread every 1.5 s).
    @Test func windowGroupingOnePassVsPerApp() {
        let raw: [[String: Any]] = (0..<400).map { i in
            [kCGWindowOwnerPID as String: Int32(100 + i % 30), kCGWindowNumber as String: UInt32(i + 1),
             kCGWindowLayer as String: 0, kCGWindowIsOnscreen as String: true,
             kCGWindowBounds as String: ["X": 0.0, "Y": 0.0, "Width": 400.0, "Height": 300.0]]
        }
        let pids = (0..<30).map { Int32(100 + $0) }
        let perApp = Self.median { for p in pids { _ = CGWindowInfo.list(from: raw, pid: p) } }
        let onePass = Self.median { _ = CGWindowInfo.byPID(from: raw) }
        print("bench: window grouping 400 windows x 30 apps: per-app \(Self.ms(perApp)) ms, one pass \(Self.ms(onePass)) ms")
        #expect(onePass < perApp)
        #expect(onePass < 0.006)   // measured 0.56 ms (per-app scans 2.0 ms)
    }

    // MARK: Drawing (Win7Theme)

    /// 200 W7UIFont calls: each used to list ~/Library/Fonts (1.5 ms for 200 before the cache).
    @Test func uiFontCalls() {
        let t = Self.median { for _ in 0..<200 { _ = W7UIFont(12) } }
        print("bench: 200 W7UIFont(12) calls: \(Self.ms(t)) ms (1.5 ms before the cache)")
        #expect(t < 0.0004)   // measured 0.03-0.04 ms
    }

    /// A full taskbar's worth of buttons (20) drawn with their gradients and paths vs blitting the
    /// cached images.
    @Test func taskbarButtonsDrawnVsCached() {
        let rect = CGRect(x: 0, y: 0, width: 60, height: 40)
        let glow = CGColor(srgbRed: 0.2, green: 0.5, blue: 0.9, alpha: 1)
        let image = W7CreateTaskbarButtonImage(rect.size, 2, true, false, true, 3, glow)!
        let cs = CGColorSpace(name: CGColorSpace.sRGB)!
        let ctx = CGContext(data: nil, width: 2400, height: 80, bitsPerComponent: 8, bytesPerRow: 0, space: cs,
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.scaleBy(x: 2, y: 2)
        let drawn = Self.median {
            for i in 0..<20 { W7DrawTaskbarGroupButton(ctx, rect.offsetBy(dx: CGFloat(i) * 60, dy: 0), true, false, true, 3, glow) }
        }
        let blitted = Self.median { for i in 0..<20 { ctx.draw(image, in: rect.offsetBy(dx: CGFloat(i) * 60, dy: 0)) } }
        print("bench: 20 taskbar buttons at 2x: drawn \(Self.ms(drawn)) ms, cached images \(Self.ms(blitted)) ms")
        #expect(blitted < drawn)
        #expect(blitted < 0.001)   // measured 0.09 ms (drawn 4.5 ms)
    }

    // MARK: Dylib (Win7ChromeCore)

    /// A hover change used to redraw the whole title bar (glass, icon, title, three buttons); now it
    /// redraws one 43x18 caption button layer.
    @MainActor @Test func titlebarFullVsOneButton() {
        _ = NSApplication.shared
        let w = NSWindow(contentRect: .init(x: 0, y: 0, width: 600, height: 300),
                         styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: true)
        w.isReleasedWhenClosed = false
        w.title = "A document with a fairly long title.txt"
        W7ChromeController.decorateWindow(w)
        let container = w.standardWindowButton(.closeButton)!.superview!
        let bar = container.subviews.first { $0 is W7TitlebarView } as! W7TitlebarView
        let fullRep = bar.bitmapImageRepForCachingDisplay(in: bar.bounds)!
        let closeView = bar.w7CaptionButtonViews[2]
        let buttonRep = closeView.bitmapImageRepForCachingDisplay(in: closeView.bounds)!
        let full = Self.median { bar.cacheDisplay(in: bar.bounds, to: fullRep) }
        let one = Self.median { closeView.cacheDisplay(in: closeView.bounds, to: buttonRep) }
        print("bench: title bar redraw: full \(Self.ms(full)) ms, one caption button \(Self.ms(one)) ms")
        #expect(one < full)
        #expect(one < 0.0004)   // measured 0.04 ms (whole bar 0.4-0.5 ms)
        w.close()
    }

    /// Measuring a 12-title menu strip 20 times (what strip draws and hit tests did) vs the cache.
    @MainActor @Test func menuTitlesMeasuredVsCached() {
        let font = NSFont.systemFont(ofSize: 12)
        let titles = ["Safari", "File", "Edit", "View", "History", "Bookmarks", "Develop", "Window", "Help", "Format", "Insert", "Tools"]
        let attrs: [NSAttributedString.Key: Any] = [.font: font]
        let measured = Self.median { for _ in 0..<20 { for t in titles { _ = (t as NSString).size(withAttributes: attrs) } } }
        let cached = Self.median { for _ in 0..<20 { for t in titles { _ = W7TextSize(t, font) } } }
        print("bench: 240 title measurements: AppKit \(Self.ms(measured)) ms, cached \(Self.ms(cached)) ms")
        #expect(cached < measured)
        #expect(cached < 0.0005)   // measured 0.05 ms (AppKit 2.0-3.4 ms)
    }
}

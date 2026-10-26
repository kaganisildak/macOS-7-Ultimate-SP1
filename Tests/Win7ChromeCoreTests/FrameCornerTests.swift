import AppKit
import Testing
import Win7ChromeCore
import Win7Theme

/// Calls to MismatchedRadiiWindow's stand-in `_setCornerRadii:`.
nonisolated(unsafe) private var mismatchedSetterCalls = 0

/// A window whose `_setCornerRadii:` has the type encoding "v24@0:8d16" (a double argument) instead of AppKit's
/// "v24@0:8@16", counting its calls.
private final class MismatchedRadiiWindow: NSWindow {
    static let installed: Bool = {
        let block: @convention(block) (AnyObject, Double) -> Void = { _, _ in mismatchedSetterCalls += 1 }
        return class_addMethod(MismatchedRadiiWindow.self, NSSelectorFromString("_setCornerRadii:"),
                               imp_implementationWithBlock(block), "v24@0:8d16")
    }()
}

/// Windows 7 window corners. The overlay paints over macOS's rounded corners (the wedge path), and
/// where AppKit allows it the window itself gets 6 pt top / square bottom corners (the radius path).
@Suite(.serialized) struct FrameCornerTests {
    /// Framed for a plain visible window, maximized (top wedges only) for a maximized one, hidden otherwise.
    @Test func modeTable() {
        for bits in 0..<32 {
            let visible = bits & 1 != 0, mini = bits & 2 != 0, fs = bits & 4 != 0, occluded = bits & 8 != 0, maxed = bits & 16 != 0
            let shown = visible && !mini && !fs && !occluded
            let expected: W7FrameBorderMode = !shown ? .hidden : (maxed ? .maximized : .framed)
            #expect(W7FrameBorderModeFor(visible, mini, fs, occluded, maxed) == expected, "bits \(bits)")
        }
    }

    @MainActor private func makeWindow() -> NSWindow {
        _ = NSApplication.shared
        let w = NSWindow(contentRect: .init(x: 0, y: 0, width: 400, height: 300), styleMask: std, backing: .buffered, defer: true)
        w.isReleasedWhenClosed = false
        w.setFrameOrigin(NSPoint(x: -12000, y: -12000))
        return w
    }

    /// AppKit's default radius for a fresh window (16 on macOS 27).
    @MainActor private func defaultRadius() -> CGFloat {
        let w = makeWindow()
        defer { w.close() }
        return W7WindowCornerRadius(w, true)
    }

    /// Runs `body` with a decorated, "visible" window (the visibility override stands in for being on screen;
    /// the window is far off it) and the corner radius kill switch set as given.
    @MainActor private func withDecoratedWindow(radiusDisabled: Bool, _ body: (NSWindow, NSWindow) -> Void) {
        W7FrameBorderUseDisabledOverride(0)
        W7FrameBorderUseVisibilityOverride(1)
        W7CornerRadiusUseDisabledOverride(radiusDisabled ? 1 : 0)
        defer {
            W7FrameBorderUseDisabledOverride(-1)
            W7FrameBorderUseVisibilityOverride(-1)
            W7CornerRadiusUseDisabledOverride(-1)
        }
        let w = makeWindow()
        W7ChromeController.decorateWindow(w)
        guard let overlay = W7FrameBorderOverlay(w) else { Issue.record("no overlay"); w.close(); return }
        body(w, overlay)
        w.close()
    }

    /// Radius path: the window gets 6 pt top and square bottom corners, which survive a run-loop turn; the
    /// overlay keeps its frame and stays click-through; closing the window gives AppKit its radius back.
    @MainActor @Test func radiusPathGivesTheWindowWindows7Corners() {
        let standard = defaultRadius()
        // Measured on macOS 27.0.1 (26A434): the setter is there with the expected types.
        if ProcessInfo.processInfo.operatingSystemVersion.majorVersion == 27 { #expect(W7CornerRadiusSetterAvailable()) }
        guard W7CornerRadiusSetterAvailable() else {
            // No usable setter on this macOS: the wedges do the work (wedgePathKeepsTheWindowRadius covers it).
            withDecoratedWindow(radiusDisabled: false) { w, _ in #expect(W7FrameBorderCornerPath(w) == .wedges) }
            return
        }
        var window: NSWindow?
        withDecoratedWindow(radiusDisabled: false) { w, overlay in
            window = w
            #expect(W7FrameBorderCornerPath(w) == .radius)
            #expect(W7WindowCornerRadius(w, true) == 6 && W7WindowCornerRadius(w, false) == 0)
            RunLoop.main.run(until: Date().addingTimeInterval(0.05))
            #expect(W7FrameBorderCornerPath(w) == .radius, "still applied after a run-loop turn")
            #expect(W7WindowCornerRadius(w, true) == 6 && W7WindowCornerRadius(w, false) == 0)
            #expect(overlay.frame == W7FrameBorderOverlayFrame(w.frame))
            #expect(overlay.ignoresMouseEvents && overlay.contentView?.hitTest(NSPoint(x: 10, y: 10)) == nil)
        }
        if let w = window { #expect(W7WindowCornerRadius(w, true) == standard && W7WindowCornerRadius(w, false) == standard) }
    }

    /// Kill switch (W7CornerRadiusHookDisabled): the window keeps AppKit's radius and the overlay's wedges
    /// cover it; one overlay, same frame, still click-through.
    @MainActor @Test func wedgePathKeepsTheWindowRadius() {
        let standard = defaultRadius()
        let before = W7FrameBorderLiveOverlayCount()
        withDecoratedWindow(radiusDisabled: true) { w, overlay in
            #expect(W7FrameBorderCornerPath(w) == .wedges)
            #expect(W7WindowCornerRadius(w, true) == standard)
            #expect(W7FrameBorderLiveOverlayCount() == before + 1)
            #expect(overlay.frame == W7FrameBorderOverlayFrame(w.frame))
            #expect(overlay.ignoresMouseEvents && overlay.contentView?.hitTest(NSPoint(x: 10, y: 10)) == nil)
        }
    }

    /// A `_setCornerRadii:` that exists with other types (a double, not an object) is never called: the window
    /// keeps its radius and the overlay takes the wedge path.
    @MainActor @Test func mismatchedSetterEncodingIsNeverCalled() {
        #expect(MismatchedRadiiWindow.installed)
        let standard = defaultRadius()
        W7FrameBorderUseDisabledOverride(0)
        W7FrameBorderUseVisibilityOverride(1)
        W7CornerRadiusUseDisabledOverride(0)
        defer {
            W7FrameBorderUseDisabledOverride(-1)
            W7FrameBorderUseVisibilityOverride(-1)
            W7CornerRadiusUseDisabledOverride(-1)
        }
        let w = MismatchedRadiiWindow(contentRect: .init(x: 0, y: 0, width: 400, height: 300), styleMask: std,
                                      backing: .buffered, defer: true)
        w.isReleasedWhenClosed = false
        w.setFrameOrigin(NSPoint(x: -12000, y: -12000))
        mismatchedSetterCalls = 0
        #expect(!W7SetWindowCornerRadii(w, 6, 0))
        W7ChromeController.decorateWindow(w)
        #expect(W7FrameBorderOverlay(w) != nil)
        #expect(W7FrameBorderCornerPath(w) == .wedges)
        #expect(W7WindowCornerRadius(w, true) == standard && W7WindowCornerRadius(w, false) == standard)
        w.close()
        #expect(mismatchedSetterCalls == 0, "the stand-in setter was called \(mismatchedSetterCalls) times")
    }

    /// 1× bitmap of `view`, read at `p` in the view's own coordinates (bottom-left origin).
    @MainActor private func snapshot(_ view: NSView) -> (NSPoint) -> NSColor? {
        let b = view.bounds
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(b.width), pixelsHigh: Int(b.height),
                                         bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                         colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else { return { _ in nil } }
        view.cacheDisplay(in: b, to: rep)
        return { p in
            let x = Int(p.x - b.minX), y = Int(b.maxY - p.y)
            guard x >= 0, y >= 0, x < rep.pixelsWide, y < rep.pixelsHigh else { return nil }
            return rep.colorAt(x: x, y: y)
        }
    }

    /// The overlay's top wedges and edge are, pixel for pixel, what the window's own title bar draws at the
    /// same window coordinates: one glass, no tone seam (both paths).
    @MainActor @Test func overlayWedgesMatchTheTitleBarPixels() {
        for disabled in [true, false] {
            withDecoratedWindow(radiusDisabled: disabled) { w, overlay in
                guard let bar = w.standardWindowButton(.closeButton)?.superview?.subviews.compactMap({ $0 as? W7TitlebarView }).first,
                      let overlayView = overlay.contentView else { Issue.record("no title bar"); return }
                #expect(W7FrameBorderIsShowing(w))
                let glass = bar.w7GlassView
                let o = snapshot(overlayView), t = snapshot(glass)
                let W = w.frame.width, H = w.frame.height
                var points = [NSPoint(x: 0.5, y: H - 2.5), NSPoint(x: 0.5, y: H - 10.5), NSPoint(x: 0.5, y: H - 20.5),
                              NSPoint(x: W - 0.5, y: H - 2.5), NSPoint(x: W - 0.5, y: H - 12.5)]
                if W7WindowCornerRadius(w, true) >= 16 {
                    points += [NSPoint(x: 2.5, y: H - 4.5), NSPoint(x: 3.5, y: H - 2.5), NSPoint(x: W - 2.5, y: H - 4.5)]
                }
                for p in points {
                    // Window coordinates → overlay (8 pt left of and below the window) and glass view coordinates.
                    let inOverlay = NSPoint(x: p.x + W7FrameBorderWidth, y: p.y + W7FrameBorderWidth)
                    let inGlass = glass.convert(p, from: nil)
                    guard let a = o(inOverlay)?.usingColorSpace(.sRGB), let b = t(inGlass)?.usingColorSpace(.sRGB) else {
                        Issue.record("no pixel at \(p)"); continue
                    }
                    let tol = 1.5 / 255
                    #expect(abs(a.redComponent - b.redComponent) <= tol && abs(a.greenComponent - b.greenComponent) <= tol
                            && abs(a.blueComponent - b.blueComponent) <= tol && a.alphaComponent > 0.99 && b.alphaComponent > 0.99,
                            "radius disabled \(disabled) at \(p): overlay \(a) title bar \(b)")
                }
            }
        }
    }
}

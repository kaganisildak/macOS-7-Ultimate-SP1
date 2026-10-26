import AppKit
import Testing
import Win7ChromeCore

/// the static title-bar glass, per-button caption layers, cached text measurement and the
/// perf log rule. Their micro-benchmarks are in Win7PerfTests.

private let none = Int(W7CaptionHitNone)
private let minimize = W7CaptionKind.minimize.rawValue
private let maximize = W7CaptionKind.maximize.rawValue
private let close = W7CaptionKind.close.rawValue
private func bit(_ k: Int) -> UInt { 1 << UInt(k) }

// MARK: Which caption buttons a state change redraws

@Test func captionRedrawMaskCoversOnlyChangedButtons() {
    #expect(W7CaptionRedrawMask(none, none, none, none) == 0)
    #expect(W7CaptionRedrawMask(none, none, close, none) == bit(close))
    #expect(W7CaptionRedrawMask(minimize, none, maximize, none) == bit(minimize) | bit(maximize))
    #expect(W7CaptionRedrawMask(close, none, none, none) == bit(close))
    // Pressing the hovered button changes only that button (hover → pressed).
    #expect(W7CaptionRedrawMask(close, none, close, close) == bit(close))
    // Dragging off the pressed button: it goes back to normal; the button now under the pointer stays
    // normal while another is pressed.
    #expect(W7CaptionRedrawMask(close, close, maximize, close) == bit(close))
    // Releasing over another button: it turns hot.
    #expect(W7CaptionRedrawMask(maximize, close, maximize, none) == bit(maximize))
}

@Test func perfLogRuleMatchesTheShell() {
    #expect(W7PerfShouldLog(0.017, true, true))
    #expect(!W7PerfShouldLog(0.016, true, true))
    #expect(!W7PerfShouldLog(1, false, true))
    #expect(!W7PerfShouldLog(1, true, false))
}

// MARK: Title bar structure

@MainActor private func decoratedBar() -> (NSWindow, W7TitlebarView) {
    _ = NSApplication.shared
    let w = NSWindow(contentRect: .init(x: 0, y: 0, width: 600, height: 300),
                     styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: true)
    w.isReleasedWhenClosed = false
    W7ChromeController.decorateWindow(w)
    let container = w.standardWindowButton(.closeButton)!.superview!
    return (w, container.subviews.first { $0 is W7TitlebarView } as! W7TitlebarView)
}

@MainActor private func descendants(_ v: NSView) -> [NSView] { v.subviews + v.subviews.flatMap(descendants) }

/// No behind-window blur by default: every decorated window's title bar is a static drawing.
@MainActor @Test func titlebarHasNoBlurByDefault() {
    let (w, bar) = decoratedBar()
    #expect(!W7TitlebarBlurEnabled())   // `defaults write -g W7TitlebarBlur -bool YES` turns it on
    #expect(!descendants(bar).contains { $0 is NSVisualEffectView })
    w.close()
}

@MainActor @Test func blurIsKeptBehindTheDefault() {
    _ = NSApplication.shared
    let bar = W7TitlebarView(frame: NSRect(x: 0, y: 0, width: 600, height: 30), blur: true)
    #expect(descendants(bar).contains { $0 is NSVisualEffectView })
}

/// The glass and the three caption buttons are separate layer-backed views that redraw only when told.
@MainActor @Test func captionButtonsHaveTheirOwnLayers() {
    let (w, bar) = decoratedBar()
    let buttons = bar.w7CaptionButtonViews
    #expect(buttons.count == 3)
    let rects = W7CaptionLayout(bar.bounds)
    #expect(buttons.map(\.frame) == [rects.minimize, rects.maximize, rects.close])
    for v in buttons + [bar.w7GlassView] {
        #expect(v.wantsLayer)
        #expect(v.layerContentsRedrawPolicy == .onSetNeedsDisplay)
        #expect(v.hitTest(NSPoint(x: v.frame.midX, y: v.frame.midY)) == nil)
    }
    w.close()
}

/// Hovering the close button redraws the close button only, not the glass or the other buttons.
@MainActor @Test func hoverRedrawsOnlyTheHoveredButton() {
    let (w, bar) = decoratedBar()
    let buttons = bar.w7CaptionButtonViews
    let views = buttons + [bar.w7GlassView]
    // The window is never shown, so the layers are drawn by hand to clear their pending redraws.
    func drawAll() { for v in views { v.layer?.displayIfNeeded() } }
    func pending(_ v: NSView) -> Bool { v.layer?.needsDisplay() ?? true }
    drawAll()
    #expect(!views.contains(where: pending))
    bar.w7SetHover(close, pressed: none)
    #expect(buttons.map(pending) == [false, false, true])
    #expect(!pending(bar.w7GlassView))
    drawAll()
    bar.w7SetHover(maximize, pressed: none)
    #expect(buttons.map(pending) == [false, true, true])
    // A title or key change redraws everything.
    drawAll()
    bar.refresh()
    #expect(views.allSatisfy(pending))
    w.close()
}

/// The layout follows the bar's width (a window resize).
@MainActor @Test func captionButtonsFollowResize() {
    let (w, bar) = decoratedBar()
    w.setContentSize(NSSize(width: 900, height: 300))
    bar.layoutSubtreeIfNeeded()
    let rects = W7CaptionLayout(bar.bounds)
    #expect(bar.w7CaptionButtonViews.map(\.frame) == [rects.minimize, rects.maximize, rects.close])
    w.close()
}

// MARK: Text measurement

@MainActor @Test func cachedTextSizeMatchesAppKit() {
    let font = NSFont.systemFont(ofSize: 12)
    for s in ["File", "Edit", "Ctrl+Shift+S", "", "Görünüm"] {
        #expect(W7TextSize(s, font) == (s as NSString).size(withAttributes: [.font: font]))
    }
    let bold = NSFont.boldSystemFont(ofSize: 12)
    #expect(W7TextSize("Window", bold) == ("Window" as NSString).size(withAttributes: [.font: bold]))
}

// MARK: Menu strip (cached title rects, one shared menu observer)

/// The cached rects are what the strip measured on every draw and hit test before.
@MainActor @Test func menuStripTitleRectsMatchTheOldMeasurement() {
    let font = NSFont.systemFont(ofSize: 12)
    let titles = ["TextEdit", "File", "Edit", "Görünüm", ""]
    let rects = W7MenuStripTitleRects(titles, font, 20).map(\.rectValue)
    var x: CGFloat = 0
    for (t, r) in zip(titles, rects) {
        let w = ceil((t as NSString).size(withAttributes: [.font: font]).width) + 16
        #expect(r == NSRect(x: x, y: 0, width: w, height: 20), "\(t)")
        x += w
    }
    #expect(rects.count == titles.count)
    #expect(W7MenuStripTitleRects([], font, 20).isEmpty)
}

/// A renamed main-menu item reaches every window's strip through the one shared observer.
@MainActor @Test func menuStripsFollowMainMenuChanges() {
    _ = NSApplication.shared
    let saved = NSApp.mainMenu
    defer { NSApp.mainMenu = saved }
    let main = NSMenu()
    for t in ["App", "File"] {
        let item = NSMenuItem(title: t, action: nil, keyEquivalent: "")
        item.submenu = NSMenu(title: t)
        main.addItem(item)
    }
    NSApp.mainMenu = main
    let windows = (0..<2).map { _ -> NSWindow in
        let w = NSWindow(contentRect: .init(x: 0, y: 0, width: 600, height: 300),
                         styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: true)
        w.isReleasedWhenClosed = false
        W7ChromeController.decorateWindow(w)
        return w
    }
    func titles(_ w: NSWindow) -> [String]? {
        w.titlebarAccessoryViewControllers.first { $0 is W7MenuStripController }?.view.value(forKey: "titles") as? [String]
    }
    #expect(windows.allSatisfy { titles($0)?.last == "File" })
    main.items[1].title = "Datei"
    RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.1))
    #expect(windows.allSatisfy { titles($0)?.last == "Datei" }, "\(windows.map(titles))")
    for w in windows { w.close() }
}

// MARK: Explorer nav bar

/// The nav bar's glass continues the title bar's; without W7TitlebarBlur neither has a blur view.
@MainActor @Test func explorerNavBarHasNoBlurByDefault() {
    _ = NSApplication.shared
    let w = NSWindow(contentRect: .init(x: 0, y: 0, width: 800, height: 500),
                     styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                     backing: .buffered, defer: true)
    w.isReleasedWhenClosed = false
    w.titlebarAppearsTransparent = true
    w.toolbar = NSToolbar(identifier: "W7RenderPerfNavBarToolbar")
    W7ExplorerAdopt(w)
    W7ChromeController.decorateWindow(w)
    let bars = w.titlebarAccessoryViewControllers.map(\.view)
    #expect(!bars.isEmpty)
    #expect(!bars.contains { descendants($0).contains { $0 is NSVisualEffectView } })
    w.close()
}

import AppKit
import Testing
import Win7ChromeCore

let std: NSWindow.StyleMask = [.titled, .closable, .miniaturizable, .resizable]
@Test func decoratesStandard() { #expect(W7ShouldDecorateWindow(std, false, false, false)) }
@Test func skipsCustomTitlebarApps() { #expect(!W7ShouldDecorateWindow(std.union(.fullSizeContentView), false, true, false)) }
@Test func skipsOthers() {
    #expect(!W7ShouldDecorateWindow(.borderless, false, false, false))
    #expect(!W7ShouldDecorateWindow(std, true, false, false))
    #expect(!W7ShouldDecorateWindow(std, false, false, true))
    #expect(!W7ShouldDecorateWindow(std.union(.fullScreen), false, false, false))
}
@Test func layout() {
    let r = W7CaptionLayout(CGRect(x: 0, y: 0, width: 800, height: 30))
    #expect(r.close == CGRect(x: 751, y: 11, width: 43, height: 18))
    #expect(r.maximize == CGRect(x: 725, y: 11, width: 26, height: 18))
    #expect(r.minimize == CGRect(x: 699, y: 11, width: 26, height: 18))
}
@Test func hitTest() {
    let r = W7CaptionLayout(CGRect(x: 0, y: 0, width: 800, height: 30))
    #expect(W7CaptionHitTest(r, CGPoint(x: 760, y: 20)) == W7CaptionKind.close.rawValue)
    #expect(W7CaptionHitTest(r, CGPoint(x: 751, y: 11)) == W7CaptionKind.close.rawValue)
    #expect(W7CaptionHitTest(r, CGPoint(x: 10, y: 10)) == -1)
}
@Test func maximizedFrame() {
    #expect(W7MaximizedFrame(CGRect(x: 0, y: 0, width: 1440, height: 900), 40, true) == CGRect(x: 0, y: 40, width: 1440, height: 860))
    #expect(W7MaximizedFrame(CGRect(x: 1440, y: 0, width: 1920, height: 1080), 40, false) == CGRect(x: 1440, y: 0, width: 1920, height: 1080))
}
@MainActor @Test func decorateIsIdempotent() {
    _ = NSApplication.shared
    let w = NSWindow(contentRect: .init(x: 0, y: 0, width: 400, height: 300), styleMask: std, backing: .buffered, defer: true)
    W7ChromeController.decorateWindow(w); W7ChromeController.decorateWindow(w)
    let bar = w.standardWindowButton(.closeButton)!.superview!
    #expect(bar.subviews.filter { $0 is W7TitlebarView }.count == 1)
    #expect(w.standardWindowButton(.closeButton)!.isHidden)
}

@MainActor @Test func hitTestReturnsTitlebarView() {
    _ = NSApplication.shared
    let w = NSWindow(contentRect: .init(x: 0, y: 0, width: 400, height: 300), styleMask: std, backing: .buffered, defer: true)
    w.isReleasedWhenClosed = false
    W7ChromeController.decorateWindow(w)
    let container = w.standardWindowButton(.closeButton)!.superview!
    let rects = W7CaptionLayout(container.bounds)
    let center = NSPoint(x: rects.close.midX, y: rects.close.midY)
    let hit = container.hitTest(container.convert(center, to: container.superview))
    #expect(hit is W7TitlebarView)
}

@MainActor @Test func decoratedWindowDoesNotLeak() {
    _ = NSApplication.shared
    weak var weakWindow: NSWindow?
    autoreleasepool {
        let w = NSWindow(contentRect: .init(x: 0, y: 0, width: 400, height: 300), styleMask: std, backing: .buffered, defer: true)
        w.isReleasedWhenClosed = false
        W7ChromeController.decorateWindow(w)
        weakWindow = w
    }
    #expect(weakWindow == nil)
}

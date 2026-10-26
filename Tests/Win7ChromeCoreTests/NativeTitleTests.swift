import AppKit
import Testing
import Win7ChromeCore

// decorated windows show one caption title (ours). AppKit's own title field and any toolbar title
// view stay hidden, and later titleVisibility / titlebarAppearsTransparent changes are coerced.

@Test func guardedTitleVisibilityIsHiddenOnlyForDecoratedWindows() {
    #expect(W7GuardedTitleVisibility(.visible, true) == .hidden)
    #expect(W7GuardedTitleVisibility(.hidden, true) == .hidden)
    #expect(W7GuardedTitleVisibility(.visible, false) == .visible)
    #expect(W7GuardedTitleVisibility(.hidden, false) == .hidden)
}

@Test func guardedTitlebarTransparencyIsOnOnlyForDecoratedWindows() {
    #expect(W7GuardedTitlebarAppearsTransparent(false, true))
    #expect(W7GuardedTitlebarAppearsTransparent(true, true))
    #expect(!W7GuardedTitlebarAppearsTransparent(false, false))
    #expect(W7GuardedTitlebarAppearsTransparent(true, false))
}

@Test(arguments: ["NSToolbarTitleView", "_NSToolbarTitleView", "NSTitlebarTitleView", "_NSToolbarTitleField",
                  "NSToolbarTitleField"])
func nativeTitleViewClassNamesMatch(_ name: String) {
    #expect(W7IsNativeTitleViewClassName(name))
}

@Test(arguments: ["NSTextField", "NSTitlebarView", "NSToolbarView", "NSTitlebarContainerView", "NSToolbarTitleStackView",
                  "W7TitlebarView", "NSToolbarItemViewer", "", "MyToolbarTitleView", "_MyToolbarTitleField",
                  "SwiftUI.ToolbarTitleView", "N"])
func otherClassNamesDoNotMatch(_ name: String) {
    #expect(!W7IsNativeTitleViewClassName(name))
}

@Test func cClassNameMatchAgreesWithStringMatch() {
    #expect(W7IsNativeTitleViewClassCName("_NSToolbarTitleField"))
    #expect(W7IsNativeTitleViewClassCName("NSToolbarTitleView"))
    #expect(!W7IsNativeTitleViewClassCName("MyToolbarTitleView"))
    #expect(!W7IsNativeTitleViewClassCName("__"))
    #expect(!W7IsNativeTitleViewClassCName(nil))
}

@Test func nilClassNameDoesNotMatch() {
    #expect(!W7IsNativeTitleViewClassName(nil))
}

@MainActor private func makeWindow(_ mask: NSWindow.StyleMask = std, toolbar: Bool = false) -> NSWindow {
    _ = NSApplication.shared
    let w = NSWindow(contentRect: .init(x: -9000, y: -9000, width: 600, height: 400), styleMask: mask,
                     backing: .buffered, defer: false)
    w.isReleasedWhenClosed = false
    w.title = "Ekranlar"
    if toolbar {
        w.titlebarAppearsTransparent = mask.contains(.fullSizeContentView)
        w.toolbar = NSToolbar(identifier: "w7.test.nativeTitle")
    }
    return w
}

/// AppKit's own title field: the text field in the title bar view showing the window title.
@MainActor private func appKitTitleField(_ w: NSWindow) -> NSTextField? {
    w.standardWindowButton(.closeButton)?.superview?.subviews
        .compactMap { $0 as? NSTextField }.first { $0.stringValue == w.title }
}

@MainActor @Test(arguments: [false, true])
func decoratedWindowKeepsTitleHidden(_ converted: Bool) {
    W7InstallDecoratedWindowGuards()
    let w = converted ? makeWindow(std.union(.fullSizeContentView), toolbar: true) : makeWindow()
    W7ChromeController.decorateWindow(w)
    #expect(w.titleVisibility == .hidden)
    w.titleVisibility = .visible
    #expect(w.titleVisibility == .hidden)
    w.layoutIfNeeded()
    #expect(appKitTitleField(w)?.isHidden ?? true)
}

@MainActor @Test(arguments: [false, true])
func decoratedWindowKeepsTitlebarTransparent(_ converted: Bool) {
    W7InstallDecoratedWindowGuards()
    let w = converted ? makeWindow(std.union(.fullSizeContentView), toolbar: true) : makeWindow()
    W7ChromeController.decorateWindow(w)
    w.titlebarAppearsTransparent = false
    #expect(w.titlebarAppearsTransparent)
}

@MainActor @Test func undecoratedWindowKeepsItsTitleSettings() {
    W7InstallDecoratedWindowGuards()
    let w = makeWindow()
    w.titleVisibility = .hidden
    w.titleVisibility = .visible
    #expect(w.titleVisibility == .visible)
    w.titlebarAppearsTransparent = true
    w.titlebarAppearsTransparent = false
    #expect(!w.titlebarAppearsTransparent)
}

/// The conversion of a full-size window sets titlebarAppearsTransparent = NO before the window is
/// decorated; the guard must let that through so the decoration check sees an opaque title bar.
@MainActor @Test func conversionStillDecoratesWithGuardsInstalled() {
    W7InstallDecoratedWindowGuards()
    W7InstallConvertedWindowGuards()
    let w = makeWindow(std.union(.fullSizeContentView), toolbar: true)
    W7ChromeController.decorateWindow(w)
    let container = w.standardWindowButton(.closeButton)!.superview!
    #expect(container.subviews.filter { $0 is W7TitlebarView }.count == 1)
}

@MainActor @Test func hidesAppKitTitleFieldShownBehindTheGuard() throws {
    let w = makeWindow()
    W7ChromeController.decorateWindow(w)
    w.layoutIfNeeded()
    let field = try #require(appKitTitleField(w))
    field.isHidden = false   // as if the app re-showed it through a path the setter guard does not see
    #expect(W7HideNativeTitleViews(w) == 1)
    #expect(field.isHidden)
    #expect(field.superview != nil)
    let bar = w.standardWindowButton(.closeButton)!.superview!.subviews.first { $0 is W7TitlebarView }
    #expect(bar?.isHidden == false)
    #expect(W7HideNativeTitleViews(w) == 0)
}

/// Stands in for AppKit's toolbar title view; an AppKit-style runtime name so the "NS" prefix rule matches.
@objc(_NSW7TestToolbarTitleView) private final class TestToolbarTitleView: NSView {}

@MainActor private func decoratedToolbarWindow() throws -> (NSWindow, titlebar: NSView, toolbar: NSView) {
    let w = makeWindow(std.union(.fullSizeContentView), toolbar: true)
    W7ChromeController.decorateWindow(w)
    w.layoutIfNeeded()
    let titlebar = try #require(w.standardWindowButton(.closeButton)?.superview)
    let toolbar = try #require(titlebar.subviews.first { NSStringFromClass(type(of: $0)).hasSuffix("ToolbarView") })
    return (w, titlebar, toolbar)
}

@MainActor @Test func hidesToolbarTitleViewByClassName() throws {
    let (w, _, toolbar) = try decoratedToolbarWindow()
    let title = TestToolbarTitleView(frame: .init(x: 0, y: 0, width: 100, height: 20))
    toolbar.addSubview(title)
    #expect(W7HideNativeTitleViews(w) == 1)
    #expect(title.isHidden)
    #expect(!toolbar.isHidden)
    #expect(title.superview === toolbar)
}

/// The re-hide runs on every window switch, so it looks only at the title bar view's children and the
/// toolbar view's children: never into toolbar items or accessories, however deep they are.
@MainActor @Test func hidePassWalkIsBounded() throws {
    let (w, titlebar, toolbar) = try decoratedToolbarWindow()
    func deepTree(_ depth: Int) -> (root: NSView, leaf: NSView) {
        let root = NSView(frame: .init(x: 0, y: 0, width: 50, height: 20))
        var leaf = root
        for _ in 0..<depth {
            let child = NSView(frame: leaf.bounds)
            leaf.addSubview(child)
            leaf = child
        }
        return (root, leaf)
    }
    let inItem = deepTree(6), inAccessory = deepTree(6)
    toolbar.addSubview(inItem.root)
    titlebar.addSubview(inAccessory.root)
    let deepTitles = [inItem.leaf, inAccessory.leaf].map { leaf in
        let t = TestToolbarTitleView(frame: leaf.bounds)
        leaf.addSubview(t)
        return t
    }
    var visited: UInt = 0
    #expect(W7HideNativeTitleViewsVisited(w, &visited) == 0)
    #expect(Int(visited) == titlebar.subviews.count + toolbar.subviews.count)
    #expect(deepTitles.allSatisfy { !$0.isHidden })
}

@MainActor @Test func rehideRunsOncePerRunLoopTurn() {
    let w = makeWindow()
    #expect(!W7RehideNativeTitleViewsOncePerTurn(w))   // undecorated
    W7ChromeController.decorateWindow(w)
    #expect(W7RehideNativeTitleViewsOncePerTurn(w))
    #expect(!W7RehideNativeTitleViewsOncePerTurn(w))
    RunLoop.main.run(until: Date().addingTimeInterval(0.05))
    #expect(W7RehideNativeTitleViewsOncePerTurn(w))
}

@MainActor @Test func leavesUndecoratedWindowTitleAlone() throws {
    let w = makeWindow()
    w.layoutIfNeeded()
    let field = try #require(appKitTitleField(w))
    #expect(!field.isHidden)
    #expect(W7HideNativeTitleViews(w) == 0)
    #expect(!field.isHidden)
}

@MainActor @Test func diagnosticsDescribeTheTitlebar() {
    let w = makeWindow(std.union(.fullSizeContentView), toolbar: true)
    W7ChromeController.decorateWindow(w)
    let d = W7TitlebarDiagnostics(w)
    #expect(d.contains("titleVisibility=1"), "\(d)")
    #expect(d.contains("transparent=1"), "\(d)")
    #expect(d.contains("toolbar=1"), "\(d)")
    #expect(d.contains("NSTextField"), "\(d)")
    #expect(!d.contains("W7"), "\(d)")
}

/// NSLayoutAttributeTop needs FullSizeContentView, which converted windows give up, so the strip stays a
/// bottom accessory: with a toolbar it sits directly under the toolbar.
@MainActor @Test func convertedToolbarWindowGetsBottomStripUnderToolbar() throws {
    let saved = NSApp.mainMenu
    defer { NSApp.mainMenu = saved }
    let main = NSMenu()
    let file = NSMenuItem(title: "File", action: nil, keyEquivalent: "")
    file.submenu = NSMenu(title: "File")
    main.addItem(file)
    let w = makeWindow(std.union(.fullSizeContentView), toolbar: true)
    NSApp.mainMenu = main
    W7ChromeController.decorateWindow(w)
    let strips = w.titlebarAccessoryViewControllers.filter { $0 is W7MenuStripController }
    #expect(strips.count == 1)
    #expect(strips.first?.layoutAttribute == .bottom)
    w.layoutIfNeeded()
    let titlebar = w.standardWindowButton(.closeButton)!.superview!
    let strip = try #require(strips.first?.view)
    let toolbar = try #require(titlebar.subviews.first { NSStringFromClass(type(of: $0)).hasSuffix("ToolbarView") })
    let s = strip.convert(strip.bounds, to: nil), t = toolbar.convert(toolbar.bounds, to: nil)
    #expect(s.maxY <= t.minY + 0.5, "strip \(s) toolbar \(t)")
}

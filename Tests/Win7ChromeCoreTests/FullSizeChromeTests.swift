import AppKit
import Testing
import Win7ChromeCore

private let fullSize = std.union(.fullSizeContentView)

@Test(arguments: [false, true])
func convertsFullSizeToolbarWindow(_ isAppleApp: Bool) {
    #expect(W7ShouldConvertFullSizeWindow(fullSize, false, false, true, isAppleApp, "NSWindow"))
    #expect(W7ShouldConvertFullSizeWindow(fullSize, false, false, true, isAppleApp, "SwiftUI.AppKitWindow"))
}

// Apple apps (Terminal) do not draw their own caption, so their toolbar-less full-size windows convert.
@Test func convertsToolbarlessFullSizeWindowOfAppleApp() {
    #expect(W7ShouldConvertFullSizeWindow(fullSize, false, false, false, true, "NSWindow"))
    #expect(W7ShouldConvertFullSizeWindow(fullSize, false, false, false, true, "TTWindow"))
}

@Test func convertRejectsToolbarlessFullSizeWindowOfOtherApps() {
    #expect(!W7ShouldConvertFullSizeWindow(fullSize, false, false, false, false, "NSWindow"))
}

@Test(arguments: [false, true])
func convertRejectsOthers(_ isAppleApp: Bool) {
    for hasToolbar in [false, true] {
        #expect(!W7ShouldConvertFullSizeWindow(fullSize, true, false, hasToolbar, isAppleApp, "NSPanel"))
        #expect(!W7ShouldConvertFullSizeWindow(fullSize, false, true, hasToolbar, isAppleApp, "NSWindow"))
        #expect(!W7ShouldConvertFullSizeWindow(fullSize.union(.fullScreen), false, false, hasToolbar, isAppleApp, "NSWindow"))
        #expect(!W7ShouldConvertFullSizeWindow(fullSize.subtracting(.titled), false, false, hasToolbar, isAppleApp, "NSWindow"))
        #expect(!W7ShouldConvertFullSizeWindow(std, false, false, hasToolbar, isAppleApp, "NSWindow"))
    }
}

@Test(arguments: ["BrowserNativeWidgetWindow", "NativeWidgetMacNSWindow", "ElectronNSWindow", "AtomNSWindow"])
func convertRejectsSelfDrawnCaptionClasses(_ name: String) {
    for isAppleApp in [false, true] {
        for hasToolbar in [false, true] {
            #expect(!W7ShouldConvertFullSizeWindow(fullSize, false, false, hasToolbar, isAppleApp, name))
            #expect(!W7ShouldConvertFullSizeWindow(fullSize, false, false, hasToolbar, isAppleApp, name + "Subclass"))
        }
    }
}

@Test func appleAppIsDecidedByBundlePrefix() {
    #expect(W7IsAppleAppForFullSizeConversion("com.apple.Terminal"))
    #expect(W7IsAppleAppForFullSizeConversion("com.apple.TextEdit"))
    #expect(!W7IsAppleAppForFullSizeConversion("com.google.Chrome"))
    #expect(!W7IsAppleAppForFullSizeConversion("com.microsoft.VSCode"))
    #expect(!W7IsAppleAppForFullSizeConversion("com.applesauce.Editor"))
    #expect(!W7IsAppleAppForFullSizeConversion("com.apple"))
    #expect(!W7IsAppleAppForFullSizeConversion(""))
    #expect(!W7IsAppleAppForFullSizeConversion(nil))
}

@Test func appleAppExceptionsAreNotTreatedAsAppleApps() {
    for bundleID in W7AppleFullSizeConversionExceptions() {
        #expect(bundleID.hasPrefix("com.apple."))
        #expect(!W7IsAppleAppForFullSizeConversion(bundleID))
    }
}

@MainActor private func makeToolbarWindow() -> NSWindow {
    _ = NSApplication.shared
    let w = NSWindow(contentRect: .init(x: 0, y: 0, width: 400, height: 300), styleMask: fullSize,
                     backing: .buffered, defer: true)
    w.isReleasedWhenClosed = false
    w.titlebarAppearsTransparent = true
    w.toolbar = NSToolbar(identifier: "w7.test.toolbar")
    return w
}

@MainActor @Test func decoratesFullSizeToolbarWindow() {
    let w = makeToolbarWindow()
    W7ChromeController.decorateWindow(w)
    #expect(!w.styleMask.contains(.fullSizeContentView))
    let container = w.standardWindowButton(.closeButton)!.superview!
    #expect(container.subviews.filter { $0 is W7TitlebarView }.count == 1)
    #expect(w.standardWindowButton(.closeButton)!.isHidden)
    #expect(w.toolbarStyle == .expanded)
}

// Depends on the test runner's nil bundle ID (swift test runs tests in swiftpm-testing-helper, which has no
// Info.plist): the call site passes W7IsAppleAppForFullSizeConversion(Bundle.main.bundleIdentifier), so a
// com.apple.* runner would count as an Apple app and convert this window.
@MainActor @Test func toolbarlessFullSizeWindowStaysUndecorated() {
    _ = NSApplication.shared
    let w = NSWindow(contentRect: .init(x: 0, y: 0, width: 400, height: 300), styleMask: fullSize,
                     backing: .buffered, defer: true)
    w.isReleasedWhenClosed = false
    w.titlebarAppearsTransparent = true
    W7ChromeController.decorateWindow(w)
    #expect(w.styleMask.contains(.fullSizeContentView))
    #expect(!w.standardWindowButton(.closeButton)!.isHidden)
}

@MainActor @Test func convertedWindowKeepsFullSizeOff() {
    W7InstallConvertedWindowGuards()
    let w = makeToolbarWindow()
    W7ChromeController.decorateWindow(w)
    w.styleMask.insert(.fullSizeContentView)
    #expect(!w.styleMask.contains(.fullSizeContentView))
}

// AppKit raises NSGenericException when FullScreen is set outside a real full-screen transition, so the
// pass-through is tested on the pure mask function the setStyleMask: guard calls.
@Test func guardedMaskStripsFullSizeOnlyForConvertedWindowsOutsideFullScreen() {
    #expect(W7GuardedStyleMask(fullSize, true) == std)
    #expect(W7GuardedStyleMask(std, true) == std)
    #expect(W7GuardedStyleMask(fullSize.union(.fullScreen), true) == fullSize.union(.fullScreen))
    #expect(W7GuardedStyleMask(fullSize, false) == fullSize)
}

@MainActor @Test func convertedWindowStripsFullSizeOnAssignment() {
    W7InstallConvertedWindowGuards()
    let w = makeToolbarWindow()
    W7ChromeController.decorateWindow(w)
    w.styleMask = fullSize
    #expect(w.styleMask == std)
}

@MainActor @Test func unconvertedWindowKeepsFullSizeMask() {
    W7InstallConvertedWindowGuards()
    _ = NSApplication.shared
    let w = NSWindow(contentRect: .init(x: 0, y: 0, width: 400, height: 300), styleMask: std,
                     backing: .buffered, defer: true)
    w.isReleasedWhenClosed = false
    w.styleMask.insert(.fullSizeContentView)
    #expect(w.styleMask.contains(.fullSizeContentView))
}

@MainActor @Test func convertedWindowDoesNotLeak() {
    W7InstallConvertedWindowGuards()
    weak var weakWindow: NSWindow?
    autoreleasepool {
        let w = makeToolbarWindow()
        W7ChromeController.decorateWindow(w)
        weakWindow = w
    }
    #expect(weakWindow == nil)
}

// MARK: - Later fixes

@Test func captionTitleFallsBackToAppName() {
    #expect(W7CaptionTitle("Document", "TextEdit") == "Document")
    #expect(W7CaptionTitle("", "System Settings") == "System Settings")
    #expect(W7CaptionTitle(nil, "System Settings") == "System Settings")
    #expect(W7CaptionTitle("", nil) == "")
    #expect(W7CaptionTitle(nil, nil) == "")
}

@Test func guardedToolbarStyleIsExpandedOnlyForConvertedWindows() {
    #expect(W7GuardedToolbarStyle(.unified, true) == .expanded)
    #expect(W7GuardedToolbarStyle(.unifiedCompact, true) == .expanded)
    #expect(W7GuardedToolbarStyle(.automatic, true) == .expanded)
    #expect(W7GuardedToolbarStyle(.expanded, true) == .expanded)
    #expect(W7GuardedToolbarStyle(.unified, false) == .unified)
    #expect(W7GuardedToolbarStyle(.preference, false) == .preference)
}

@MainActor @Test func convertedWindowKeepsToolbarStyleExpanded() {
    W7InstallConvertedWindowGuards()
    let w = makeToolbarWindow()
    W7ChromeController.decorateWindow(w)
    w.toolbarStyle = .unified
    #expect(w.toolbarStyle == .expanded)
}

@MainActor @Test func unconvertedWindowKeepsItsToolbarStyle() {
    W7InstallConvertedWindowGuards()
    _ = NSApplication.shared
    let w = NSWindow(contentRect: .init(x: 0, y: 0, width: 400, height: 300), styleMask: std,
                     backing: .buffered, defer: true)
    w.isReleasedWhenClosed = false
    w.toolbar = NSToolbar(identifier: "w7.test.toolbar.plain")
    w.toolbarStyle = .unified
    #expect(w.toolbarStyle == .unified)
}

/// Raises once from the `titlebarAppearsTransparent = NO` that conversion sets right after stripping
/// FullSizeContentView (so after the window is marked converted, before the bar is attached) once
/// `failNext` is armed. This drives decorateWindow's catch path without real events.
private final class FailingConversionWindow: NSWindow {
    var failNext = false
    override var titlebarAppearsTransparent: Bool {
        get { super.titlebarAppearsTransparent }
        set {
            if failNext && !newValue {
                failNext = false
                NSException(name: .genericException, reason: "test: titlebarAppearsTransparent", userInfo: nil).raise()
            }
            super.titlebarAppearsTransparent = newValue
        }
    }
}

@MainActor @Test func failedDecorationUndoesConversionAndCanRetry() {
    W7InstallConvertedWindowGuards()
    _ = NSApplication.shared
    let w = FailingConversionWindow(contentRect: .init(x: 0, y: 0, width: 400, height: 300), styleMask: fullSize,
                                backing: .buffered, defer: true)
    w.isReleasedWhenClosed = false
    w.titlebarAppearsTransparent = true
    w.toolbar = NSToolbar(identifier: "w7.test.toolbar.failing")
    w.failNext = true
    W7ChromeController.decorateWindow(w)
    #expect(!w.failNext)
    // Reverted: the full-size mask and transparency are back, the window is unmarked and undecorated.
    #expect(w.styleMask.contains(.fullSizeContentView))
    #expect(w.titlebarAppearsTransparent)
    w.toolbarStyle = .unified
    #expect(w.toolbarStyle == .unified)
    let container = w.standardWindowButton(.closeButton)!.superview!
    #expect(container.subviews.filter { $0 is W7TitlebarView }.isEmpty)
    // The next attempt converts and decorates normally.
    W7ChromeController.decorateWindow(w)
    #expect(!w.styleMask.contains(.fullSizeContentView))
    #expect(w.standardWindowButton(.closeButton)!.superview!.subviews.filter { $0 is W7TitlebarView }.count == 1)
    #expect(w.toolbarStyle == .expanded)
}

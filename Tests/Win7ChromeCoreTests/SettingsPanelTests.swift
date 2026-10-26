import AppKit
import ObjectiveC
import SwiftUI
import Testing
import Win7ChromeCore

// System Settings gets a white window background (the Control Panel look that survives macOS 26's
// Liquid Glass sidebar) only while the visible pane is not one of the security panes, which stay fully
// native. Windows here are never ordered on screen and no events are posted.

// MARK: - Excluded panes

private let excludedExtensions = [
    "com.apple.settings.PrivacySecurity.extension", "com.apple.Home.PrivacySettingsExtension",
    "com.apple.SecurityImprovements-Settings.extension", "com.apple.Touch-ID-Settings.extension",
    "com.apple.Users-Groups-Settings.extension", "com.apple.Lock-Screen-Settings.extension",
    "com.apple.Passwords-Settings.extension",
]

@Test func settingsExcludedExtensionIDsAreTheSecurityPanes() {
    #expect(W7SettingsExcludedExtensionIDs() == excludedExtensions)
}

@Test func securityPaneProcessesAreOnTheDefaultDenylist() {
    for id in excludedExtensions { #expect(W7DefaultDenylist().contains(id)) }
    for id in excludedExtensions { #expect(!W7ShouldLoadInProcess(id, [:], [], false)) }
}

@Test func excludedPaneMatcherCoversBundleSidebarAndLegacyIDs() {
    for id in excludedExtensions { #expect(W7SettingsPaneIsExcluded(id)) }
    let sidebarAndLegacy = [
        "com.apple.settings.privacyAndSecurity", "com.apple.preference.security",
        "com.apple.settings.passcodeAndBiometrics", "com.apple.preferences.password",
        "com.apple.settings.usersAndGroups", "com.apple.preferences.users",
        "com.apple.settings.lockScreen", "com.apple.Passwords",
    ]
    for id in sidebarAndLegacy { #expect(W7SettingsPaneIsExcluded(id)) }
    #expect(W7SettingsExcludedPaneIDs().count == excludedExtensions.count + sidebarAndLegacy.count)
}

@Test func excludedPaneMatcherIgnoresCaseAnchorsAndSubpanes() {
    #expect(W7SettingsPaneIsExcluded("com.apple.preference.security?Privacy_Accessibility"))
    #expect(W7SettingsPaneIsExcluded("com.apple.settings.PrivacySecurity.extension#FileVault"))
    #expect(W7SettingsPaneIsExcluded("COM.APPLE.PASSWORDS-SETTINGS.EXTENSION"))
    #expect(W7SettingsPaneIsExcluded("com.apple.settings.PrivacySecurity.extension.Location"))
    #expect(W7SettingsPaneIsExcluded("  com.apple.Passwords  "))
}

@Test func unknownPaneIsExcluded() {
    #expect(W7SettingsPaneIsExcluded(nil))
    #expect(W7SettingsPaneIsExcluded(""))
    #expect(W7SettingsPaneIsExcluded("   "))
    #expect(W7SettingsPaneIsExcluded("?anchor"))
}

@Test func ordinaryPanesAreNotExcluded() {
    #expect(!W7SettingsPaneIsExcluded("com.apple.Wallpaper-Settings.extension"))
    #expect(!W7SettingsPaneIsExcluded("com.apple.Displays-Settings.extension"))
    #expect(!W7SettingsPaneIsExcluded("com.apple.PasswordsX"))            // not a sub-pane: no dot after the id
    #expect(!W7SettingsPaneIsExcluded("com.apple.preference.securityish"))
}

// MARK: - Detection ordering

@Test func paneIDPrefersTheHostConfiguration() {
    #expect(W7SettingsResolvePaneID("com.apple.Wallpaper-Settings.extension", "com.apple.other") == "com.apple.Wallpaper-Settings.extension")
    #expect(W7SettingsResolvePaneID(nil, "com.apple.Displays-Settings.extension") == "com.apple.Displays-Settings.extension")
    #expect(W7SettingsResolvePaneID("", "com.apple.Displays-Settings.extension") == "com.apple.Displays-Settings.extension")
    #expect(W7SettingsResolvePaneID(nil, nil) == nil)
    #expect(W7SettingsResolvePaneID("", "") == nil)
}

@Test func probeIsExcludedWhenEitherSourceSaysSoOrNeitherKnows() {
    #expect(!W7SettingsProbeIsExcluded("com.apple.Wallpaper-Settings.extension", nil))
    #expect(!W7SettingsProbeIsExcluded(nil, "com.apple.Wallpaper-Settings.extension"))
    #expect(W7SettingsProbeIsExcluded(nil, nil))
    #expect(W7SettingsProbeIsExcluded("com.apple.Wallpaper-Settings.extension", "com.apple.Passwords-Settings.extension"))
    #expect(W7SettingsProbeIsExcluded("com.apple.settings.PrivacySecurity.extension", "com.apple.Wallpaper-Settings.extension"))
}

@Test func stylingNeedsAtLeastOnePaneAndNoExcludedOne() {
    let wallpaper = ["configuration": "com.apple.Wallpaper-Settings.extension"]
    let privacy = ["remote": "com.apple.settings.PrivacySecurity.extension"]
    #expect(W7SettingsProbesAllowStyling([wallpaper]))
    #expect(!W7SettingsProbesAllowStyling([]))                 // nothing found yet: transitioning
    #expect(!W7SettingsProbesAllowStyling([wallpaper, privacy]))
    #expect(!W7SettingsProbesAllowStyling([wallpaper, [:]]))  // one pane unknown
}

@Test func panelInstallsOnlyInSystemSettings() {
    #expect(W7SettingsPanelShouldInstall("com.apple.systempreferences", false))
    #expect(!W7SettingsPanelShouldInstall("com.apple.systempreferences", true))   // W7SettingsPanelDisabled
    #expect(!W7SettingsPanelShouldInstall("com.apple.finder", false))
    #expect(!W7SettingsPanelShouldInstall("com.apple.settings.PrivacySecurity.extension", false))
    #expect(!W7SettingsPanelShouldInstall(nil, false))
}

// MARK: - Pane detection with stand-ins

@objc(W7TestExtensionIdentity) private final class FakeIdentity: NSObject {
    @objc let bundleIdentifier: String?
    init(_ id: String?) { bundleIdentifier = id }
}

@objc(W7TestHostConfiguration) private final class FakeConfiguration: NSObject {
    @objc let extensionIdentity: FakeIdentity
    init(_ id: String?) { extensionIdentity = FakeIdentity(id) }
}

@objc(W7TestHostViewController) private final class FakeHost: NSViewController {
    @objc var configuration: FakeConfiguration?
    override func loadView() { view = NSView(frame: .init(x: 0, y: 0, width: 300, height: 300)) }
}

@objc(W7TestRemoteViewController) private final class FakeRemoteController: NSViewController {
    @objc var serviceBundleIdentifier: String?
    override func loadView() { view = FakeRemoteView(frame: .init(x: 0, y: 0, width: 100, height: 100)) }
}

@objc(W7TestRemoteView) private final class FakeRemoteView: NSView {}

@MainActor private func hostView(config: String?, remote: String?) -> (NSView, [AnyObject]) {
    let host = FakeHost()
    host.configuration = config.map { FakeConfiguration($0) }
    var keep: [AnyObject] = [host]
    if let remote {
        let rc = FakeRemoteController()
        rc.serviceBundleIdentifier = remote
        host.view.addSubview(rc.view)
        keep.append(rc)
    }
    return (host.view, keep)
}

@MainActor @Test func probesReadTheConfigurationAndTheRemoteView() {
    let root = NSView(frame: .init(x: 0, y: 0, width: 600, height: 400))
    let (a, keepA) = hostView(config: "com.apple.Wallpaper-Settings.extension", remote: nil)
    let (b, keepB) = hostView(config: nil, remote: "com.apple.Passwords-Settings.extension")
    let wrapper = NSView(frame: root.bounds)
    wrapper.addSubview(a)
    root.addSubview(wrapper)
    root.addSubview(b)
    let probes = W7SettingsProbePanes(root, FakeHost.self, FakeRemoteView.self)
    #expect(probes.count == 2)
    #expect(probes.contains { $0["configuration"] == "com.apple.Wallpaper-Settings.extension" && $0["remote"] == nil })
    #expect(probes.contains { $0["configuration"] == nil && $0["remote"] == "com.apple.Passwords-Settings.extension" })
    #expect(!W7SettingsProbesAllowStyling(probes))
    withExtendedLifetime((keepA, keepB)) {}
}

@MainActor @Test func hiddenPanesAreNotProbed() {
    let root = NSView(frame: .init(x: 0, y: 0, width: 600, height: 400))
    let (a, keepA) = hostView(config: "com.apple.Wallpaper-Settings.extension", remote: nil)
    let (b, keepB) = hostView(config: "com.apple.Passwords-Settings.extension", remote: nil)
    b.isHidden = true
    root.addSubview(a)
    root.addSubview(b)
    let probes = W7SettingsProbePanes(root, FakeHost.self, FakeRemoteView.self)
    #expect(probes == [["configuration": "com.apple.Wallpaper-Settings.extension"]])
    #expect(W7SettingsProbesAllowStyling(probes))
    withExtendedLifetime((keepA, keepB)) {}
}

@MainActor @Test func missingHostClassesFindNothing() {
    let root = NSView(frame: .init(x: 0, y: 0, width: 600, height: 400))
    let (a, keep) = hostView(config: "com.apple.Wallpaper-Settings.extension", remote: nil)
    root.addSubview(a)
    #expect(W7SettingsProbePanes(root, nil, nil).isEmpty)
    withExtendedLifetime(keep) {}
}

// MARK: - Window background and sidebar item on a stand-in split view

/// Stands in for AppKit's _NSSplitViewItemViewWrapper (the detection matches the name's suffix and a BOOL -isSidebar).
@objc(W7TestSplitViewItemViewWrapper) private final class FakeWrapper: NSView {
    @objc var isSidebar = true
    @objc var splitViewItem: NSSplitViewItem?
}

@MainActor private final class SidebarFixture {
    let window: NSWindow
    let wrapper = FakeWrapper(frame: .init(x: 0, y: 0, width: 220, height: 500))
    let detail = FakeWrapper(frame: .init(x: 220, y: 0, width: 580, height: 500))
    let scroll = NSScrollView(frame: .init(x: 0, y: 0, width: 220, height: 500))
    let outline = NSOutlineView(frame: .init(x: 0, y: 0, width: 220, height: 500))
    let item = NSSplitViewItem(sidebarWithViewController: NSViewController())
    let effect = NSVisualEffectView(frame: .init(x: 0, y: 0, width: 220, height: 500))

    init(withEffectView: Bool = false) {
        _ = NSApplication.shared
        window = NSWindow(contentRect: .init(x: 0, y: 0, width: 800, height: 500),
                          styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: .aqua)
        window.backgroundColor = .windowBackgroundColor
        detail.isSidebar = false
        wrapper.splitViewItem = item
        scroll.documentView = outline
        scroll.drawsBackground = true
        outline.backgroundColor = .controlBackgroundColor
        if withEffectView { wrapper.addSubview(effect) }
        wrapper.addSubview(scroll)
        let content = NSView(frame: .init(x: 0, y: 0, width: 800, height: 500))
        content.addSubview(wrapper)
        content.addSubview(detail)
        window.contentView = content
        settle()
    }

    /// One render, so AppKit's own display-time adjustments (a scroll view in a vibrant appearance turns
    /// drawsBackground off) are part of the native state a snapshot is compared with.
    func settle() {
        let rep = wrapper.bitmapImageRepForCachingDisplay(in: wrapper.bounds)!
        wrapper.cacheDisplay(in: wrapper.bounds, to: rep)
    }

    /// The styled window background (white); native is the app's own.
    var whiteWindow: Bool { window.backgroundColor == .white }
}

@MainActor @Test func stylingTouchesOnlyTheWindowBackgroundAndRestoresIt() {
    let f = SidebarFixture()
    let snapshot = SidebarState(f)
    #expect(W7SettingsApplyWindowBackground(f.window, true) == 1)
    #expect(W7SettingsApplyWindowBackground(f.window, true) == 1)   // idempotent
    #expect(f.whiteWindow)
    // Nothing else changes: the sidebar is only looked at, no views added, the list and its scroll view as
    // the app set them.
    #expect(SidebarState(f).wrapperSubviews == snapshot.wrapperSubviews)
    #expect(f.detail.subviews.isEmpty)
    #expect(f.scroll.drawsBackground == snapshot.drawsBackground)
    #expect(f.scroll.appearance?.name == snapshot.scrollAppearance)
    #expect(f.outline.backgroundColor == snapshot.tableBackground)

    // An excluded pane shows: everything goes back to what the app had.
    #expect(W7SettingsApplyWindowBackground(f.window, false) == 1)
    #expect(SidebarState(f) == snapshot)
    #expect(W7SettingsApplyWindowBackground(f.window, false) == 1)   // restoring twice is harmless
    #expect(SidebarState(f) == snapshot)
}

// MARK: - Snapshot and restore

/// Every property of the fixture, read back (the panel may change only the window background).
@MainActor private struct SidebarState: Equatable {
    let wrapperSubviews: [ObjectIdentifier]
    let drawsBackground: Bool
    let scrollAppearance: NSAppearance.Name?
    let tableBackground: NSColor
    let windowBackground: NSColor

    init(_ f: SidebarFixture) {
        wrapperSubviews = f.wrapper.subviews.map(ObjectIdentifier.init)
        drawsBackground = f.scroll.drawsBackground
        scrollAppearance = f.scroll.appearance?.name
        tableBackground = f.outline.backgroundColor
        windowBackground = f.window.backgroundColor
    }
}

/// "name: original → current" lines whose two values are equal.
private func linesAreRestored(_ lines: [String]) -> Bool {
    !lines.isEmpty && lines.allSatisfy { line in
        guard let colon = line.range(of: ": "), let arrow = line.range(of: " → ") else { return false }
        return line[colon.upperBound..<arrow.lowerBound] == line[arrow.upperBound...]
    }
}

@MainActor @Test func excludingRestoresEveryPropertyToTheSnapshot() {
    let f = SidebarFixture(withEffectView: true)
    let snapshot = SidebarState(f)
    W7SettingsApplyWindowBackground(f.window, true)
    #expect(SidebarState(f) != snapshot)
    let styled = W7SettingsLastTransitionLines(f.window)
    #expect(styled.count == 1)                                     // only the window background is recorded
    #expect(styled.first?.hasPrefix("NSWindow.backgroundColor: ") == true)
    #expect(styled.first?.hasSuffix(" → #FFFFFF@1.00") == true)

    W7SettingsApplyWindowBackground(f.window, true)                // re-applied while visible: same snapshot
    W7SettingsApplyWindowBackground(f.window, false)               // an excluded pane
    #expect(SidebarState(f) == snapshot)
    #expect(linesAreRestored(W7SettingsLastTransitionLines(f.window)))
    #expect(W7SettingsLastTransitionLines(f.window).count == 1)

    // Styled again from the native state: a new snapshot, restored to the same values.
    W7SettingsApplyWindowBackground(f.window, true)
    W7SettingsApplyWindowBackground(f.window, false)
    #expect(SidebarState(f) == snapshot)
}

@MainActor @Test func restoreUsesTheRecordedObjectsWhereverTheyAreNow() {
    let f = SidebarFixture()
    let snapshot = SidebarState(f)
    W7SettingsApplyWindowBackground(f.window, true)
    // The sidebar moves out of the content view (AppKit re-parenting it), so a new walk can't find it.
    let elsewhere = NSView(frame: .zero)
    elsewhere.addSubview(f.wrapper)
    #expect(W7SettingsApplyWindowBackground(f.window, false) == 0)
    #expect(SidebarState(f) == snapshot)
}

@MainActor @Test func noSidebarFoundRestoresAStyledWindow() {
    let f = SidebarFixture()
    let snapshot = SidebarState(f)
    W7SettingsApplyWindowBackground(f.window, true)
    f.wrapper.removeFromSuperview()
    #expect(W7SettingsApplyWindowBackground(f.window, true) == 0)   // styling asked, but no sidebar: native
    #expect(SidebarState(f) == snapshot)
}

@MainActor @Test func refreshStylesOnlyForAKnownNonExcludedPane() {
    let f = SidebarFixture()
    let native = f.window.backgroundColor
    let (pane, keep) = hostView(config: "com.apple.Wallpaper-Settings.extension", remote: nil)
    f.detail.addSubview(pane)
    #expect(W7SettingsRefreshWindowWithClasses(f.window, FakeHost.self, FakeRemoteView.self))
    #expect(f.whiteWindow)

    (keep[0] as! FakeHost).configuration = FakeConfiguration("com.apple.settings.PrivacySecurity.extension")
    #expect(!W7SettingsRefreshWindowWithClasses(f.window, FakeHost.self, FakeRemoteView.self))
    #expect(f.window.backgroundColor == native)

    (keep[0] as! FakeHost).configuration = nil                  // transitioning: unknown
    #expect(!W7SettingsRefreshWindowWithClasses(f.window, FakeHost.self, FakeRemoteView.self))
    #expect(f.window.backgroundColor == native)
}

@MainActor @Test func darkAppearanceStaysNative() {
    let f = SidebarFixture()
    f.window.appearance = NSAppearance(named: .darkAqua)
    let native = f.window.backgroundColor
    let (pane, keep) = hostView(config: "com.apple.Wallpaper-Settings.extension", remote: nil)
    f.detail.addSubview(pane)
    #expect(!W7SettingsRefreshWindowWithClasses(f.window, FakeHost.self, FakeRemoteView.self))
    #expect(f.window.backgroundColor == native)
    withExtendedLifetime(keep) {}
}

@MainActor @Test func closingAStyledWindowRestoresIt() {
    let f = SidebarFixture()
    let snapshot = SidebarState(f)
    let (pane, keep) = hostView(config: "com.apple.Wallpaper-Settings.extension", remote: nil)
    f.detail.addSubview(pane)
    // A host change with a window tracks it (title/appearance KVO and the close observer) and styles it.
    W7SettingsHostChangedWithClasses(keep[0] as! NSViewController, FakeHost.self, FakeRemoteView.self, false)
    #expect(f.whiteWindow)
    f.window.close()
    #expect(SidebarState(f) == snapshot)
    #expect(linesAreRestored(W7SettingsLastTransitionLines(f.window)))
}

@MainActor @Test func aStyledWindowIsNotKeptAliveByItsSnapshot() {
    weak var control: NSWindow?
    weak var styled: NSWindow?
    autoreleasepool { control = SidebarFixture().window }   // the same fixture, never styled
    autoreleasepool {
        let f = SidebarFixture()
        W7SettingsApplyWindowBackground(f.window, true)
        styled = f.window
    }
    // The snapshot holds its targets weakly: no window → snapshot → window cycle.
    #expect(control == nil)                                  // precondition: an unstyled fixture is freed
    #expect(styled == nil)
}

// MARK: - Windowless-host test, on its own

/// A pane change without a window restores every styled window, so this never interleaves with others.
@Suite(.serialized) @MainActor struct SettingsPanelSerialTests {
    @Test func hostChangeToAnExcludedPaneRestoresNow() {
        let f = SidebarFixture()
        let snapshot = SidebarState(f)
        let (pane, keep) = hostView(config: "com.apple.Wallpaper-Settings.extension", remote: nil)
        let host = keep[0] as! FakeHost
        f.detail.addSubview(pane)
        W7SettingsHostChangedWithClasses(host, FakeHost.self, FakeRemoteView.self, false)
        #expect(f.whiteWindow)

        host.configuration = FakeConfiguration("com.apple.settings.PrivacySecurity.extension")
        W7SettingsHostChangedWithClasses(host, FakeHost.self, FakeRemoteView.self, false)   // in the same turn
        #expect(SidebarState(f) == snapshot)

        host.configuration = FakeConfiguration("com.apple.Wallpaper-Settings.extension")
        W7SettingsHostChangedWithClasses(host, FakeHost.self, FakeRemoteView.self, false)
        #expect(f.whiteWindow)
        // A new pane's host before it has a window: unknown, so every styled window goes native now.
        let (_, other) = hostView(config: "com.apple.Wallpaper-Settings.extension", remote: nil)
        W7SettingsHostChangedWithClasses(other[0] as! NSViewController, FakeHost.self, FakeRemoteView.self, false)
        #expect(SidebarState(f) == snapshot)
    }
}

// MARK: - Host hooks

@objc(W7TestHostBase) private class FakeHostBase: NSViewController {
    var appearCalls = 0
    override func loadView() { view = NSView(frame: .init(x: 0, y: 0, width: 300, height: 300)) }
    override func viewWillAppear() { appearCalls += 1 }
}

/// Inherits -viewWillAppear, as _EXHostViewController may.
@objc(W7TestHostSub) private final class FakeHostSub: FakeHostBase {}

@objc(W7TestHostOwn) private final class FakeHostOwn: NSViewController {
    var appearCalls = 0
    override func loadView() { view = NSView(frame: .init(x: 0, y: 0, width: 300, height: 300)) }
    override func viewWillAppear() { appearCalls += 1 }
}

@MainActor @Test func hostHookPatchesTheOwnMethodWhenTheHostDefinesIt() {
    #expect(W7SettingsHookHostSelector(FakeHostOwn.self, #selector(NSViewController.viewWillAppear), "v16@0:8") === FakeHostOwn.self)
    #expect(W7SettingsHookHostSelector(FakeHostOwn.self, #selector(NSViewController.viewWillAppear), "v16@0:8") === FakeHostOwn.self)
    let host = FakeHostOwn()
    (host as NSViewController).viewWillAppear()
    #expect(host.appearCalls == 1)                               // wrapped once, original called once
    #expect(W7SettingsHookHostSelector(FakeHostOwn.self, #selector(NSViewController.viewWillAppear), "v24@0:8@16") == nil)
}

@MainActor @Test func hostHookFallsBackToTheSuperclassAndReactsOnlyToHostInstances() {
    #expect(W7SettingsHookHostSelector(FakeHostSub.self, #selector(NSViewController.viewWillAppear), "v16@0:8") === FakeHostBase.self)
    let f = SidebarFixture()
    let base = FakeHostBase(), sub = FakeHostSub()
    f.detail.addSubview(base.view)
    f.detail.addSubview(sub.view)

    W7SettingsApplyWindowBackground(f.window, true)
    (base as NSViewController).viewWillAppear()                  // not a host instance: original only
    #expect(base.appearCalls == 1)
    #expect(f.whiteWindow)

    // A host instance: the original, then a pane change for its window. Its pane can't be identified
    // (no _EXHostViewController here), so the window goes native in the same call.
    (sub as NSViewController).viewWillAppear()
    #expect(sub.appearCalls == 1)
    #expect(!f.whiteWindow)
}

// MARK: - Sidebar view-tree diagnostics

// Behind W7SettingsVerboseLog, once per System Settings main window: the sidebar's view tree only (the split view's
// sidebar pane), names and numbers. Never a row title or any text: a sentinel string is put in every text-bearing
// place. The content pane is never walked: a view there counts every -subviews call and must see none. Synthetic
// windows that are never ordered on screen; System Settings itself is never launched.

private let sidebarSentinel = "W7SENTINEL-Wi-Fi-HomeNetwork-Bob"

/// A view of the content pane that counts how often anything asks for its subviews.
@objc(SettingsTestContentPaneView) private final class ContentPaneView: NSView {
    nonisolated(unsafe) static var subviewReads = 0
    override var subviews: [NSView] {
        get { Self.subviewReads += 1; return super.subviews }
        set { super.subviews = newValue }
    }
}

/// A view-based sidebar list: NSTableCellView rows holding an NSImageView and an NSTextField with the sentinel.
@MainActor private final class SidebarListSource: NSObject, NSTableViewDataSource, NSTableViewDelegate {
    let rows: Int
    init(rows: Int) { self.rows = rows }
    func numberOfRows(in tableView: NSTableView) -> Int { rows }
    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let cell = NSTableCellView(frame: .init(x: 0, y: 0, width: 200, height: 24))
        let image = NSImageView(frame: .init(x: 4, y: 4, width: 16, height: 16))
        image.image = NSImage(systemSymbolName: "wifi", accessibilityDescription: sidebarSentinel)
        image.toolTip = sidebarSentinel
        let text = NSTextField(labelWithString: sidebarSentinel)
        text.frame = .init(x: 24, y: 4, width: 170, height: 16)
        text.toolTip = sidebarSentinel
        text.setAccessibilityLabel(sidebarSentinel)
        text.identifier = .init(sidebarSentinel)
        cell.addSubview(image)
        cell.addSubview(text)
        cell.imageView = image
        cell.textField = text
        cell.identifier = .init(sidebarSentinel)
        return cell
    }
}

@MainActor private final class SidebarDumpFixture {
    let window: NSWindow
    let split = NSSplitViewController()
    let table = NSTableView(frame: .init(x: 0, y: 0, width: 220, height: 500))
    let source = SidebarListSource(rows: 5)
    let contentPane = ContentPaneView(frame: .init(x: 0, y: 0, width: 580, height: 500))

    /// `swiftUI`: the sidebar is a SwiftUI host instead of an AppKit list. `glass`: the list sits in a glass container.
    init(swiftUI: Bool = false, glass: Bool = false) {
        _ = NSApplication.shared
        window = NSWindow(contentRect: .init(x: 0, y: 0, width: 800, height: 500),
                          styleMask: [.titled, .closable, .resizable, .fullSizeContentView], backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        window.title = sidebarSentinel
        let sidebarVC = NSViewController()
        let sidebarView = NSView(frame: .init(x: 0, y: 0, width: 220, height: 500))
        if swiftUI {
            let host = NSHostingView(rootView: Text(sidebarSentinel))
            host.frame = sidebarView.bounds
            sidebarView.addSubview(host)
        } else {
            let column = NSTableColumn(identifier: .init(sidebarSentinel))
            column.title = sidebarSentinel
            table.addTableColumn(column)
            table.dataSource = source
            table.delegate = source
            let scroll = NSScrollView(frame: sidebarView.bounds)
            scroll.documentView = table
            if glass {
                let glassView = Self.makeGlass(frame: sidebarView.bounds)
                glassView.addSubview(scroll)
                sidebarView.addSubview(glassView)
            } else {
                sidebarView.addSubview(scroll)
            }
            table.reloadData()
            // Realise the rows as a displayed list would (the dump itself never makes a view).
            for row in 0..<source.rows { _ = table.view(atColumn: 0, row: row, makeIfNecessary: true) }
        }
        sidebarVC.view = sidebarView
        let contentVC = NSViewController()
        contentPane.addSubview(NSTextField(labelWithString: sidebarSentinel))
        contentVC.view = contentPane
        split.addSplitViewItem(NSSplitViewItem(sidebarWithViewController: sidebarVC))
        split.addSplitViewItem(NSSplitViewItem(viewController: contentVC))
        window.contentViewController = split
        window.layoutIfNeeded()
    }

    deinit { MainActor.assumeIsolated { window.close() } }

    static func makeGlass(frame: NSRect) -> NSView {
        if #available(macOS 26, *) { return NSGlassEffectView(frame: frame) }
        return NSVisualEffectView(frame: frame)
    }
}

@Test func sidebarDumpDecisionNeedsSettingsAMainWindowTheVerboseSwitchAndNoKillSwitch() {
    let settings = "com.apple.systempreferences"
    #expect(W7SettingsSidebarShouldDump(settings, true, false, true, false))
    #expect(!W7SettingsSidebarShouldDump(settings, true, true, true, false), "W7SettingsSidebarDisabled skips even the dump")
    #expect(!W7SettingsSidebarShouldDump(settings, true, false, false, false), "verbose off: nothing")
    #expect(!W7SettingsSidebarShouldDump(settings, true, false, true, true), "once per window")
    #expect(!W7SettingsSidebarShouldDump(settings, false, false, true, false), "a window without a sidebar")
    #expect(!W7SettingsSidebarShouldDump("com.apple.finder", true, false, true, false))
    #expect(!W7SettingsSidebarShouldDump("com.apple.settings.PrivacySecurity.extension", true, false, true, false))
    #expect(!W7SettingsSidebarShouldDump(nil, true, false, true, false))
}

@Suite(.serialized) @MainActor struct SettingsSidebarDumpTests {
    @Test func sidebarIsFoundThroughTheSplitViewControllerSidebarItem() throws {
        let f = SidebarDumpFixture()
        let pane = try #require(W7SettingsSidebarPane(f.window))
        #expect(pane.superview is NSSplitView, "the split view's own pane, so glass containers around the list are in it")
        #expect(f.table.isDescendant(of: pane))
        #expect(!f.contentPane.isDescendant(of: pane))
    }

    @Test func dumpDescribesTheAppKitListRowsAndCellsButNoText() {
        let f = SidebarDumpFixture()
        ContentPaneView.subviewReads = 0
        let lines = W7SettingsSidebarDump(f.window)
        let reads = ContentPaneView.subviewReads
        let dump = lines.joined(separator: "\n")
        #expect(lines.first?.hasPrefix("sidebar source=split-view-controller") == true)
        #expect(dump.contains("behavior=sidebar"))
        #expect(lines.contains { $0.hasPrefix("ancestor ") && $0.contains("NSSplitView") })
        #expect(lines.contains { $0.hasPrefix("list NSTableView") && $0.contains("rows=5") && $0.contains("cols=1")
                                 && $0.contains("rowView=") && $0.contains("inWindow=(") })
        #expect(lines.contains { $0.hasPrefix("row 0 ") && $0.contains("NSTableCellView") && $0.contains("imageView=NSImageView")
                                 && $0.contains("textField=NSTextField") && $0.contains("image=") && $0.contains("pointSize=") })
        #expect(lines.contains { $0.hasPrefix("summary: views ") && $0.contains("lists 1,") && $0.contains("rows 5,")
                                 && $0.contains("table cell views 5,") && $0.contains("SwiftUI hosts 0,") })
        #expect(dump.contains("NSScrollView"), "the tree")
        #expect(!dump.contains(sidebarSentinel), "never a row title, tool tip, label, identifier or the window title")
        #expect(!dump.contains("W7SENTINEL"))
        #expect(!dump.contains("HomeNetwork"))
        #expect(!dump.contains("wifi"), "never an image's name")
        // The content pane is never walked.
        #expect(reads == 0)
        #expect(!dump.contains("SettingsTestContentPaneView"))
        // Control: a walk of the whole window does reach the content pane, so the counter can see a walk.
        _ = W7MessagesViewTreeLines(f.window.contentView, 30, 400)
        #expect(ContentPaneView.subviewReads > 0)
    }

    @Test func dumpFlagsASwiftUIHostedSidebar() {
        let f = SidebarDumpFixture(swiftUI: true)
        let lines = W7SettingsSidebarDump(f.window)
        let dump = lines.joined(separator: "\n")
        #expect(lines.contains { $0.hasPrefix("host ") && $0.contains("inWindow=(") })
        #expect(lines.contains { $0.hasPrefix("summary: ") && $0.contains("SwiftUI hosts 1,") && $0.contains("lists 0,") })
        #expect(dump.contains("SwiftUI-host"))
        #expect(!dump.contains("W7SENTINEL"))
    }

    @Test func dumpListsTheGlassContainer() {
        let f = SidebarDumpFixture(glass: true)
        let lines = W7SettingsSidebarDump(f.window)
        #expect(lines.contains { $0.hasPrefix("glass ") && ($0.contains("Glass") || $0.contains("NSVisualEffectView")) })
        #expect(lines.contains { $0.hasPrefix("summary: ") && !$0.contains("glass containers 0,") })
    }

    @Test func aPlainSplitViewFallsBackToItsFirstPaneAndNeverWalksTheOthers() throws {
        _ = NSApplication.shared
        let w = NSWindow(contentRect: .init(x: 0, y: 0, width: 800, height: 500), styleMask: [.titled, .resizable],
                         backing: .buffered, defer: true)
        w.isReleasedWhenClosed = false
        defer { w.close() }
        let split = NSSplitView(frame: .init(x: 0, y: 0, width: 800, height: 500))
        split.isVertical = true
        let first = NSView(frame: .init(x: 0, y: 0, width: 220, height: 500))
        let outline = NSOutlineView(frame: first.bounds)
        outline.addTableColumn(NSTableColumn(identifier: .init("c")))
        first.addSubview(outline)
        let content = ContentPaneView(frame: .init(x: 221, y: 0, width: 579, height: 500))
        content.addSubview(NSTextField(labelWithString: sidebarSentinel))
        split.addArrangedSubview(first)
        split.addArrangedSubview(content)
        let root = NSView(frame: split.frame)
        root.addSubview(split)
        w.contentView = root
        #expect(try #require(W7SettingsSidebarPane(w)) === first)
        ContentPaneView.subviewReads = 0
        let lines = W7SettingsSidebarDump(w)
        #expect(ContentPaneView.subviewReads == 0)
        #expect(lines.first?.hasPrefix("sidebar source=split-view-first-pane") == true)
        #expect(lines.contains { $0.hasPrefix("list NSOutlineView") && $0.contains("outline") })
        #expect(!lines.joined().contains("W7SENTINEL"))
    }

    @Test func noSidebarMeansNoPaneAndAOneLineDump() {
        _ = NSApplication.shared
        let w = NSWindow(contentRect: .init(x: 0, y: 0, width: 400, height: 300), styleMask: [.titled], backing: .buffered, defer: true)
        w.isReleasedWhenClosed = false
        defer { w.close() }
        #expect(W7SettingsSidebarPane(w) == nil)
        #expect(W7SettingsSidebarPane(nil) == nil)
        #expect(W7SettingsSidebarDump(w) == ["sidebar: none found"])
        #expect(W7SettingsSidebarDump(nil).isEmpty)
    }

    @Test func updateSchedulesOneDumpPerSettingsMainWindowOnlyWhenVerboseAndEnabled() {
        defer { W7SettingsSidebarUseDisabledOverride(-1); W7SettingsUseVerboseLogOverride(-1) }
        let settings = "com.apple.systempreferences"

        W7SettingsSidebarUseDisabledOverride(1)
        W7SettingsUseVerboseLogOverride(1)
        let killed = SidebarDumpFixture()
        #expect(!W7SettingsSidebarDiagnosticsUpdateForBundle(killed.window, settings), "the kill switch skips even the dump")

        W7SettingsSidebarUseDisabledOverride(0)
        W7SettingsUseVerboseLogOverride(0)
        let quiet = SidebarDumpFixture()
        #expect(!W7SettingsSidebarDiagnosticsUpdateForBundle(quiet.window, settings), "no dump without W7SettingsVerboseLog")

        W7SettingsUseVerboseLogOverride(1)
        let other = SidebarDumpFixture()
        #expect(!W7SettingsSidebarDiagnosticsUpdateForBundle(other.window, "com.apple.finder"), "System Settings only")

        let bare = NSWindow(contentRect: .init(x: 0, y: 0, width: 400, height: 300), styleMask: [.titled, .resizable],
                            backing: .buffered, defer: true)
        bare.isReleasedWhenClosed = false
        defer { bare.close() }
        #expect(!W7SettingsSidebarDiagnosticsUpdateForBundle(bare, settings), "windows without a sidebar")

        let main = SidebarDumpFixture()
        #expect(W7SettingsSidebarDiagnosticsUpdateForBundle(main.window, settings))
        #expect(!W7SettingsSidebarDiagnosticsUpdateForBundle(main.window, settings), "one dump per window")
        #expect(!W7SettingsSidebarDiagnosticsUpdateForBundle(nil, settings))
    }
}

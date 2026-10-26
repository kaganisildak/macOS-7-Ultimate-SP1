import AppKit
import ObjectiveC
import Testing
import Win7ChromeCore

// b: the Explorer navigation pane is always shown. Finder collapses its sidebar when the
// toolbar is hidden (or the saved state hides it); Explorer windows expand it again, once at adoption
// and in the throttled maintenance pass, unless the user hid it in that window. Windows here are never
// ordered on screen and no events are posted.

// MARK: - Decision logic

@Test func sidebarExpandsOnlyWhenCollapsedAndNotHiddenByUser() {
    #expect(W7ShouldExpandSidebar(true, false, 0))
    #expect(!W7ShouldExpandSidebar(false, false, 0))   // already visible
    #expect(!W7ShouldExpandSidebar(true, true, 0))     // the user hid it in this window
    #expect(!W7ShouldExpandSidebar(false, true, 0))
}

@Test func sidebarForcingIsRateLimited() {
    #expect(W7SidebarMaxForcedExpands == 3)
    #expect(W7SidebarForcePeriod == 10)
    #expect(W7ShouldExpandSidebar(true, false, W7SidebarMaxForcedExpands - 1))
    #expect(!W7ShouldExpandSidebar(true, false, W7SidebarMaxForcedExpands))   // Finder keeps collapsing it
}

@Test func collapseCountsAsUsersOnlyAfterAUserGesture() {
    #expect(W7SidebarUserActionWindow == 3)
    #expect(!W7SidebarCollapseIsUsers(false, false, -1))   // no sidebar action yet: the toolbar hide did it
    #expect(!W7SidebarCollapseIsUsers(false, false, 3.5))  // an old menu action
    #expect(W7SidebarCollapseIsUsers(false, false, 0.2))   // View ▸ Hide Sidebar just now
    #expect(!W7SidebarCollapseIsUsers(true, false, -1))    // a narrow window auto-collapsed it: not a hide
    #expect(!W7SidebarCollapseIsUsers(true, false, 0.2))
    #expect(W7SidebarCollapseIsUsers(false, true, -1))     // dragging the divider shut
}

@MainActor @Test func sidebarMenuItemsAreListed() {
    let root = NSMenu(title: "Main")
    let view = NSMenu(title: "Görüntü")
    let hide = NSMenuItem(title: "Kenar Çubuğunu Gizle", action: #selector(NSSplitViewController.toggleSidebar(_:)), keyEquivalent: "s")
    view.addItem(NSMenuItem(title: "Araç Çubuğunu Gizle", action: #selector(NSWindow.toggleToolbarShown(_:)), keyEquivalent: "t"))
    view.addItem(hide)
    let top = NSMenuItem(title: "Görüntü", action: nil, keyEquivalent: "")
    top.submenu = view
    root.addItem(top)
    #expect(W7SidebarMenuItems(root) == [hide])
    #expect(W7SidebarMenuItems(nil).isEmpty)
}

@Test func sidebarMenuActionsAreRecognised() {
    #expect(W7IsSidebarMenuAction(#selector(NSSplitViewController.toggleSidebar(_:))))
    #expect(W7IsSidebarMenuAction(NSSelectorFromString("cmdToggleSideBar:")))
    #expect(!W7IsSidebarMenuAction(#selector(NSWindow.toggleToolbarShown(_:))))
    #expect(!W7IsSidebarMenuAction(nil))
}

// MARK: - Finding and expanding the sidebar

/// An NSOutlineView subclass named like Finder's sidebar, made once at run time.
@MainActor private func finderSidebarClass() -> NSOutlineView.Type {
    if let cls = NSClassFromString("TSidebarView") { return cls as! NSOutlineView.Type }
    let cls: AnyClass = objc_allocateClassPair(NSOutlineView.self, "TSidebarView", 0)!
    objc_registerClassPair(cls)
    return cls as! NSOutlineView.Type
}

@MainActor private final class SidebarFixture {
    let window: NSWindow
    let controller = NSSplitViewController()
    let sidebarItem: NSSplitViewItem
    let sidebar: NSOutlineView
    let source = SidebarSource()

    init(collapsed: Bool, windowClass: NSWindow.Type = NSWindow.self) {
        _ = NSApplication.shared
        window = windowClass.init(contentRect: .init(x: 0, y: 0, width: 800, height: 500),
                                  styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                                  backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        window.toolbar = NSToolbar(identifier: "W7ExplorerSidebarTestToolbar")

        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 200, height: 500))
        sidebar = finderSidebarClass().init(frame: scroll.bounds)
        sidebar.style = .sourceList
        sidebar.headerView = nil
        let col = NSTableColumn(identifier: .init("c"))
        sidebar.addTableColumn(col)
        sidebar.outlineTableColumn = col
        sidebar.dataSource = source
        sidebar.delegate = source
        scroll.documentView = sidebar
        let sidebarVC = NSViewController()
        sidebarVC.view = NSView(frame: scroll.bounds)
        scroll.autoresizingMask = [.width, .height]
        sidebarVC.view.addSubview(scroll)
        let browserVC = NSViewController()
        browserVC.view = NSView(frame: NSRect(x: 0, y: 0, width: 600, height: 500))

        sidebarItem = NSSplitViewItem(sidebarWithViewController: sidebarVC)
        controller.addSplitViewItem(sidebarItem)
        controller.addSplitViewItem(NSSplitViewItem(viewController: browserVC))
        window.contentViewController = controller
        window.setContentSize(NSSize(width: 800, height: 500))
        sidebar.reloadData()
        sidebarItem.isCollapsed = collapsed
        window.contentView?.layoutSubtreeIfNeeded()
    }
}

@MainActor @Test func splitItemLookupFindsTheItemHostingTheSidebar() {
    let f = SidebarFixture(collapsed: true)
    #expect(String(cString: object_getClassName(f.sidebar)) == "TSidebarView")
    #expect(W7SidebarSplitItem(f.sidebar) === f.sidebarItem)
    // A view outside any split view controller has no item.
    #expect(W7SidebarSplitItem(NSView()) == nil)
    f.window.close()
}

@MainActor @Test func expandSidebarUncollapsesTheSplitItem() {
    let f = SidebarFixture(collapsed: true)
    #expect(f.sidebarItem.isCollapsed)
    #expect(W7ExpandSidebar(f.window, f.sidebar) == .splitItem)
    #expect(!f.sidebarItem.isCollapsed)
    #expect(W7ExpandSidebar(f.window, f.sidebar) == .alreadyVisible)
    f.window.close()
}

@MainActor @Test func expandSidebarFindsTheSidebarItemByBehaviorWithoutAView() {
    let f = SidebarFixture(collapsed: true)
    #expect(W7ExpandSidebar(f.window, nil) == .splitItem)
    #expect(!f.sidebarItem.isCollapsed)
    f.window.close()
}

@MainActor private final class CollapsingSplitDelegate: NSObject, NSSplitViewDelegate {
    func splitView(_ splitView: NSSplitView, canCollapseSubview subview: NSView) -> Bool { true }
}

@MainActor @Test func expandSidebarFallsBackToTheDivider() {
    _ = NSApplication.shared
    let w = NSWindow(contentRect: .init(x: 0, y: 0, width: 800, height: 500), styleMask: [.titled, .resizable],
                     backing: .buffered, defer: true)
    w.isReleasedWhenClosed = false
    let delegate = CollapsingSplitDelegate()
    let split = NSSplitView(frame: NSRect(x: 0, y: 0, width: 800, height: 500))
    split.isVertical = true
    split.delegate = delegate
    let pane = NSView(frame: NSRect(x: 0, y: 0, width: 200, height: 500))
    let sidebar = NSOutlineView(frame: pane.bounds)
    pane.addSubview(sidebar)
    split.addSubview(pane)
    split.addSubview(NSView(frame: NSRect(x: 201, y: 0, width: 599, height: 500)))
    w.contentView = split
    split.adjustSubviews()
    split.setPosition(0, ofDividerAt: 0)
    #expect(split.isSubviewCollapsed(pane) || pane.frame.width < 1, "fixture: pane \(pane.frame)")

    #expect(W7ExpandSidebar(w, sidebar) == .divider)
    #expect(!split.isSubviewCollapsed(pane))
    #expect(abs(pane.frame.width - 200) < 1)
    #expect(W7ExpandSidebar(w, sidebar) == .alreadyVisible)
    // No split view at all.
    #expect(W7ExpandSidebar(w, NSView()) == .notFound)
    w.close()
    _ = delegate
}

// MARK: - In an Explorer window

@MainActor @Test func explorerAdoptionExpandsACollapsedSidebar() {
    let f = SidebarFixture(collapsed: true)
    W7ExplorerAdopt(f.window)
    #expect(!f.sidebarItem.isCollapsed)
    f.window.close()
}

// The maintenance pass runs from a main-queue dispatch, which a @MainActor test can't drain, so these
// drive the keeper's checks directly: the first is the adoption check, later ones maintenance passes.

@MainActor @Test func keeperReopensTheSidebarAfterALaterCollapse() {
    let f = SidebarFixture(collapsed: false)
    let keeper = W7ExplorerSidebarKeeper(window: f.window)
    keeper.checkSidebar(f.sidebar)
    #expect(!f.sidebarItem.isCollapsed)
    // The toolbar hide collapses it later: the next pass re-opens it.
    f.sidebarItem.isCollapsed = true
    keeper.checkSidebar(f.sidebar)
    #expect(!f.sidebarItem.isCollapsed)
    f.window.close()
}

@MainActor @Test func keeperStopsFightingASidebarThatKeepsCollapsing() {
    let f = SidebarFixture(collapsed: true)
    let keeper = W7ExplorerSidebarKeeper(window: f.window)
    for _ in 0..<Int(W7SidebarMaxForcedExpands) {
        keeper.checkSidebar(f.sidebar)
        #expect(!f.sidebarItem.isCollapsed)
        f.sidebarItem.isCollapsed = true
    }
    keeper.checkSidebar(f.sidebar)
    #expect(f.sidebarItem.isCollapsed)   // the fourth collapse within 10 s is left alone
    f.window.close()
}

@MainActor @Test func keeperRespectsTheUserHidingTheSidebar() {
    let f = SidebarFixture(collapsed: false)
    let keeper = W7ExplorerSidebarKeeper(window: f.window)
    keeper.checkSidebar(f.sidebar)
    // View ▸ Hide Sidebar: the menu announces the action, then the item collapses.
    let item = NSMenuItem(title: "Hide Sidebar", action: #selector(NSSplitViewController.toggleSidebar(_:)), keyEquivalent: "s")
    let menu = NSMenu(title: "View")
    menu.addItem(item)
    NotificationCenter.default.post(name: NSMenu.willSendActionNotification, object: menu, userInfo: ["MenuItem": item])
    f.sidebarItem.isCollapsed = true
    keeper.checkSidebar(f.sidebar)
    #expect(f.sidebarItem.isCollapsed)
    // Still respected later in this window, even when the user shows it and Finder collapses it again.
    f.sidebarItem.isCollapsed = false
    keeper.checkSidebar(f.sidebar)
    f.sidebarItem.isCollapsed = true
    keeper.checkSidebar(f.sidebar)
    #expect(f.sidebarItem.isCollapsed)
    // The next window starts afresh.
    let g = SidebarFixture(collapsed: true)
    W7ExplorerSidebarKeeper(window: g.window).checkSidebar(g.sidebar)
    #expect(!g.sidebarItem.isCollapsed)
    f.window.close()
    g.window.close()
}

@MainActor @Test func keeperDoesNotTakeAnUnrelatedMenuActionForTheUser() {
    let f = SidebarFixture(collapsed: false)
    let keeper = W7ExplorerSidebarKeeper(window: f.window)
    keeper.checkSidebar(f.sidebar)
    let item = NSMenuItem(title: "Hide Toolbar", action: #selector(NSWindow.toggleToolbarShown(_:)), keyEquivalent: "t")
    let menu = NSMenu(title: "View")
    menu.addItem(item)
    NotificationCenter.default.post(name: NSMenu.willSendActionNotification, object: menu, userInfo: ["MenuItem": item])
    f.sidebarItem.isCollapsed = true
    keeper.checkSidebar(f.sidebar)
    #expect(!f.sidebarItem.isCollapsed)
    f.window.close()
}

/// A window whose live-resize state the test sets (NSWindow's is read-only).
private final class LiveResizeWindow: NSWindow {
    var live = false
    override var inLiveResize: Bool { live }
}

@MainActor @Test func keeperReopensASidebarCollapsedByANarrowWindowOnceItIsWider() {
    let f = SidebarFixture(collapsed: false, windowClass: LiveResizeWindow.self)
    let w = f.window as! LiveResizeWindow
    let keeper = W7ExplorerSidebarKeeper(window: w)
    keeper.checkSidebar(f.sidebar)
    // Narrowing the window: NSSplitViewController auto-collapses the sidebar mid-resize.
    w.live = true
    f.sidebarItem.isCollapsed = true
    NotificationCenter.default.post(name: NSSplitView.didResizeSubviewsNotification, object: f.controller.splitView)
    keeper.checkSidebar(f.sidebar)
    #expect(f.sidebarItem.isCollapsed)   // never forced open mid-resize
    w.live = false
    keeper.checkSidebar(f.sidebar)
    #expect(f.sidebarItem.isCollapsed)   // no wider than where it collapsed: still too narrow
    // Widening the window brings the pane back: the resize was not the user hiding it.
    w.setContentSize(NSSize(width: 1000, height: 500))
    w.contentView?.layoutSubtreeIfNeeded()
    keeper.checkSidebar(f.sidebar)
    #expect(!f.sidebarItem.isCollapsed)
    // And that re-open didn't use up the rate limit: three ordinary collapses are still re-opened.
    for _ in 0..<Int(W7SidebarMaxForcedExpands) {
        f.sidebarItem.isCollapsed = true
        keeper.checkSidebar(f.sidebar)
        #expect(!f.sidebarItem.isCollapsed)
    }
    w.close()
}

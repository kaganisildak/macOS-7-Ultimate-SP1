import AppKit
import ObjectiveC
import Testing
import Win7ChromeCore

// "★ Favorites" opens Safari's Bookmarks sidebar, "✚" follows Safari's validation of Add
// Bookmark…, and the command bar is wired to Safari's REAL main-menu selectors (dumped live; the titles here are
// placeholders, Safari's are never read). A fake main menu with those selectors, a target counting the calls and a
// validator standing in for Safari's; no event is posted and no window is shown.

// MARK: - A main menu with Safari's selectors

/// What the fake target records: the selectors Safari's items sent, and Safari's verdict for Add Bookmark… (off on
/// the Start Page).
private final class SafariModel { var calls: [String] = []; var canAddBookmark = true }

/// A target answering every selector of Safari's main menu (built at run time: one block per selector, recording the
/// call) and validating Add Bookmark… as Safari does (`validateMenuItem:`).
@MainActor private func makeSafariTarget(_ model: SafariModel) -> NSObject {
    let name = "W7FakeSafariTarget_\(UUID().uuidString.replacingOccurrences(of: "-", with: ""))"
    let cls: AnyClass = objc_allocateClassPair(NSObject.self, name, 0)!
    for sel in SafariTarget.selectors {
        let block: @convention(block) (AnyObject, AnyObject?) -> Void = { _, _ in model.calls.append(sel) }
        class_addMethod(cls, sel_registerName(sel), imp_implementationWithBlock(block), "v@:@")
    }
    let validate: @convention(block) (AnyObject, NSMenuItem) -> Bool = { _, item in
        item.action == NSSelectorFromString("addBookmark:") ? model.canAddBookmark : true
    }
    class_addMethod(cls, sel_registerName("validateMenuItem:"), imp_implementationWithBlock(validate), "B@:@")
    objc_registerClassPair(cls)
    return (cls as! NSObject.Type).init()
}

private enum SafariTarget {
    static let selectors: Set<String> = Set(SafariTarget.menus.flatMap { $0.1.map(\.1) })
    /// Safari's main menu (selectors only, as dumped live for ); titles are placeholders.
    static let menus: [(String, [(String, String)])] = [
        ("Safari", [("Settings…", "showPreferences:"), ("Privacy Report…", "showPrivacyReport:"), ("Extensions…", "showExtensionsSettings:"),
                    ("Clear History…", "clearHistoryAndWebsiteData:"), ("Clear History (keep data)…", "clearHistoryAndKeepWebsiteData:"),
                    ("Certificate…", "showCertificateInformation:"), ("Per-site…", "togglePerSitePreferencesPopoverFromMenuItem:")]),
        ("File", [("New Window", "_newWindowWithDefaultProfile:"), ("New Private Window", "createPrivateBrowsingWindow:"),
                  ("New Tab", "newTabFromFileMenu:"), ("Open File…", "openDocument:"), ("Open Location…", "openLocation:"),
                  ("Close Window", "performClose:"), ("Close Tab", "closeCurrentTab:"), ("Save As…", "saveDocumentTo:"),
                  ("Export as PDF…", "saveDocumentToPDF:"), ("Add to Dock…", "generateWebAppForCurrentPage:"), ("Print…", "safari_printDocument:")]),
        ("View", [("Show Location Bar", "toggleLocationBar:"), ("Customize Toolbar…", "runToolbarCustomizationPalette:"),
                  ("Always Show Tab Bar", "toggleAlwaysShowTabBar:"), ("Show Favorites Bar", "toggleFavoritesBar:"),
                  ("Show Status Bar", "toggleStatusBar:"), ("Show Sidebar", "safari_toggleSidebar:"),
                  ("Show Bookmarks Sidebar", "toggleBookmarksSidebar:"), ("Show Reading List Sidebar", "toggleReadingListSidebar:"),
                  ("Show Shared with You", "toggleSharedWithYou:"), ("Show Reader", "toggleReader:"),
                  ("Show Tab Overview", "toggleVisualTabPickerFromMenu:"), ("Show Downloads", "showDownloads:"),
                  ("Stop", "stopLoading:"), ("Reload Page", "reloadObeyingUnifiedField:"), ("Reload From Origin", "reloadFromOrigin:"),
                  ("Actual Size", "zoomToStandardSize:"), ("Zoom In", "zoomIn:"), ("Make Text Bigger", "makeTextBigger:"),
                  ("Zoom Out", "zoomOut:"), ("Make Text Smaller", "makeTextSmaller:"), ("Enter Full Screen", "toggleFullScreen:")]),
        ("History", [("Show All History", "toggleHistoryInBookmarksView:"), ("Back", "goBackInWindow:"), ("Forward", "goForwardInWindow:"),
                     ("Home", "goHome:"), ("Search Results SnapBack", "snapBackToSearchResults:"),
                     ("Reopen Last Closed Tab", "reopenLastClosedTabOrWindow:"), ("Reopen All Windows", "reopenLastSession:")]),
        ("Bookmarks", [("Show Start Page", "showStartPage:"), ("Show Bookmarks", "toggleBookmarks:"), ("Edit Bookmarks", "toggleBookmarksEditView:"),
                       ("Add Bookmark…", "addBookmark:"), ("Add Bookmarks for These Tabs…", "addBookmarksForTabs:"),
                       ("Add Bookmark Folder", "addBookmarkFolder:"), ("Add to Reading List", "addReadingListItem:"),
                       ("Add These Tabs to Reading List", "addReadingListItemsForTabs:")]),
        ("Window", [("Mute This Tab", "toggleMuteCurrentTab:"), ("Show Previous Tab", "selectPreviousTab:"), ("Show Next Tab", "selectNextTab:"),
                    ("Duplicate Tab", "duplicateTab:"), ("Pin Tab", "togglePinTabFromMenu:")]),
        ("Help", [("Safari Help", "showHelp:"), ("Acknowledgments", "showAcknowledgments:")]),
    ]
}

/// Safari's main menu with the selectors above (and the View ▸ Text Encoding submenu), every item targeted at `target`;
/// `without` leaves selectors out (an older Safari).
@MainActor private func safariMainMenu(_ target: NSObject, without: Set<String> = []) -> NSMenu {
    let main = NSMenu(title: "Main")
    for (title, items) in SafariTarget.menus {
        let m = NSMenu(title: title)
        for (t, a) in items where !without.contains(a) {
            let item = NSMenuItem(title: t, action: NSSelectorFromString(a), keyEquivalent: "")
            item.target = target
            m.addItem(item)
        }
        if title == "View" {
            let encodings = NSMenu(title: "Text Encoding")
            encodings.addItem(NSMenuItem(title: "Default", action: NSSelectorFromString("changeTextEncoding:"), keyEquivalent: ""))
            let holder = NSMenuItem(title: "Text Encoding", action: nil, keyEquivalent: "")
            holder.submenu = encodings
            m.addItem(holder)
        }
        if title == "Bookmarks" {   // a folder submenu (user data in Safari): never resolved to, never walked for titles
            let folder = NSMenu(title: "Favorites")
            folder.addItem(NSMenuItem(title: "A site", action: NSSelectorFromString("_openBookmark:"), keyEquivalent: ""))
            let holder = NSMenuItem(title: "Favorites", action: NSSelectorFromString("submenuAction:"), keyEquivalent: "")
            holder.submenu = folder
            m.addItem(holder)
        }
        let holder = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        holder.submenu = m
        main.addItem(holder)
    }
    return main
}

private func titles(_ menu: NSMenu?) -> [String] { menu?.items.map { $0.isSeparatorItem ? "-" : $0.title } ?? [] }
private func actions(_ menu: NSMenu?) -> [String] { menu?.items.map { $0.action.map(NSStringFromSelector) ?? ($0.isSeparatorItem ? "-" : "(submenu)") } ?? [] }

// MARK: - Resolution against Safari's selectors (pure)

@MainActor @Test func favoritesResolvesToTheBookmarksSidebarAndFallsBackInOrder() {
    let model = SafariModel(), target = makeSafariTarget(model)
    #expect(W7SafariFavoritesActions() == ["toggleBookmarksSidebar:", "safari_toggleSidebar:", "toggleBookmarks:", "toggleSidebar:"])
    #expect(W7SafariFindMenuItem(safariMainMenu(target), W7SafariFavoritesActions())?.action == NSSelectorFromString("toggleBookmarksSidebar:"))
    let older = safariMainMenu(target, without: ["toggleBookmarksSidebar:"])
    #expect(W7SafariFindMenuItem(older, W7SafariFavoritesActions())?.action == NSSelectorFromString("safari_toggleSidebar:"))
    let oldest = safariMainMenu(target, without: ["toggleBookmarksSidebar:", "safari_toggleSidebar:"])
    #expect(W7SafariFindMenuItem(oldest, W7SafariFavoritesActions())?.action == NSSelectorFromString("toggleBookmarks:"))
    let none = safariMainMenu(target, without: ["toggleBookmarksSidebar:", "safari_toggleSidebar:", "toggleBookmarks:"])
    #expect(W7SafariFindMenuItem(none, W7SafariFavoritesActions()) == nil)
}

@MainActor @Test func printResolvesToSafarisPrintDocument() {
    let model = SafariModel(), target = makeSafariTarget(model)
    #expect(W7SafariPrintActions().first == "safari_printDocument:" && W7SafariPrintActions().contains("printDocument:"))
    #expect(W7SafariFindMenuItem(safariMainMenu(target), W7SafariPrintActions())?.action == NSSelectorFromString("safari_printDocument:"))
}

/// The ▾ menus from Safari's real selectors: Page (zoom, Save As / Export as PDF, Text Encoding, Reader; no page source
/// without a Develop menu), Safety, Tools (Settings… keeps Safari's title), and ★'s right-click menu in order.
@MainActor @Test func commandMenusHoldCopiesOfSafarisRealItemsInOrder() {
    let model = SafariModel(), target = makeSafariTarget(model)
    let main = safariMainMenu(target)
    let page = W7SafariBuildCommandMenu(main, "Page", NSMutableArray())
    #expect(actions(page) == ["zoomIn:", "zoomOut:", "zoomToStandardSize:", "-", "saveDocumentTo:", "saveDocumentToPDF:", "submenuAction:", "toggleReader:"],
            "\(actions(page))")   // submenuAction: is what AppKit gives a submenu holder (Safari's Text Encoding item has it too)
    #expect(page?.items[6].submenu?.items.first?.action == NSSelectorFromString("changeTextEncoding:"))
    #expect(page?.items[0].target === target)   // a copy of Safari's: its target, validated as Safari's
    let safety = W7SafariBuildCommandMenu(main, "Safety", NSMutableArray())
    #expect(actions(safety) == ["createPrivateBrowsingWindow:", "clearHistoryAndWebsiteData:", "showPrivacyReport:", "showCertificateInformation:"],
            "\(actions(safety))")
    let tools = W7SafariBuildCommandMenu(main, "Tools", NSMutableArray())
    #expect(actions(tools) == ["showDownloads:", "showExtensionsSettings:", "showPreferences:", "toggleStatusBar:", "toggleFullScreen:"], "\(actions(tools))")
    #expect(titles(tools)[2] == "Settings…")   // Safari's own title, never renamed
    let favorites = W7SafariBuildCommandMenu(main, "Favorites", NSMutableArray())
    #expect(actions(favorites) == ["toggleBookmarksSidebar:", "toggleReadingListSidebar:", "toggleBookmarks:", "toggleHistoryInBookmarksView:", "toggleFavoritesBar:"],
            "\(actions(favorites))")
    #expect(favorites?.items.allSatisfy { $0.target === target } == true)
    // An older Safari without the reading list sidebar and the favorites bar item: those are skipped, the order kept.
    let older = safariMainMenu(target, without: ["toggleReadingListSidebar:", "toggleFavoritesBar:"])
    #expect(actions(W7SafariBuildCommandMenu(older, "Favorites", NSMutableArray())) == ["toggleBookmarksSidebar:", "toggleBookmarks:", "toggleHistoryInBookmarksView:"])
    #expect(W7SafariBuildCommandMenu(safariMainMenu(target, without: ["toggleBookmarksSidebar:", "toggleReadingListSidebar:", "toggleBookmarks:",
                                                                      "toggleHistoryInBookmarksView:", "toggleFavoritesBar:"]), "Favorites", NSMutableArray()) == nil)
}

/// Performing through the menu: validated first (Safari's verdict), sent to Safari's target only when enabled.
@MainActor @Test func performMenuItemValidatesThenSends() {
    _ = NSApplication.shared
    let model = SafariModel(), target = makeSafariTarget(model)
    let main = safariMainMenu(target)
    let add = W7SafariFindMenuItem(main, ["addBookmark:"])!
    var enabled: ObjCBool = false
    #expect(W7SafariPerformMenuItem(add, &enabled) && enabled.boolValue && model.calls == ["addBookmark:"])
    model.canAddBookmark = false
    #expect(!W7SafariPerformMenuItem(add, &enabled) && !enabled.boolValue && model.calls == ["addBookmark:"])
}

// MARK: - The toolbar item path (the new-tab stub)

@MainActor private final class StubDelegate: NSObject, NSToolbarDelegate {
    let ids = ["CombinedSidebarTabGroupToolbarIdentifier", "NewTabToolbarIdentifier", "DisabledToolbarIdentifier"]
    let model = SafariModel()
    lazy var target: NSObject = makeSafariTarget(model)
    func toolbar(_ toolbar: NSToolbar, itemForItemIdentifier id: NSToolbarItem.Identifier, willBeInsertedIntoToolbar flag: Bool) -> NSToolbarItem? {
        let item = NSToolbarItem(itemIdentifier: id)
        item.label = id.rawValue
        if id.rawValue == "CombinedSidebarTabGroupToolbarIdentifier" {
            item.view = NSView(frame: NSRect(x: 0, y: 0, width: 30, height: 22))   // not a control, no action (live: CombinedSidebarTabGroupToolbarButton)
        } else {
            let button = NSButton(title: "", target: target, action: NSSelectorFromString("newTabFromFileMenu:"))
            button.isEnabled = id.rawValue != "DisabledToolbarIdentifier"
            item.view = button
        }
        return item
    }
    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] { ids.map { NSToolbarItem.Identifier($0) } }
    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] { ids.map { NSToolbarItem.Identifier($0) } }
}

/// A toolbar item whose view is not a control and has no action is NOT handled (NO: the caller falls back to the
/// menu); a control's own action is sent; a disabled control is Safari's state (handled, nothing sent).
@MainActor @Test func performToolbarItemFallsBackToTheMenuForANonControlView() {
    _ = NSApplication.shared
    let delegate = StubDelegate()
    let toolbar = NSToolbar(identifier: "W7Test-Task51-\(UUID().uuidString)")
    toolbar.delegate = delegate
    let w = NSWindow(contentRect: .init(x: 0, y: 0, width: 600, height: 300), styleMask: [.titled], backing: .buffered, defer: true)
    w.isReleasedWhenClosed = false
    w.toolbar = toolbar
    #expect(toolbar.items.count == 3)
    #expect(!W7SafariPerformToolbarItem(w, "CombinedSidebarTabGroupToolbarIdentifier"))
    #expect(W7SafariPerformToolbarItem(w, "NewTabToolbarIdentifier") && delegate.model.calls == ["newTabFromFileMenu:"])
    #expect(W7SafariPerformToolbarItem(w, "DisabledToolbarIdentifier") && delegate.model.calls == ["newTabFromFileMenu:"])
    #expect(!W7SafariPerformToolbarItem(w, "NoSuchToolbarIdentifier"))
    #expect(!W7SafariPerformToolbarItem(nil, "NewTabToolbarIdentifier"))
    w.close()
}

// MARK: - The bar's own controls

@MainActor private func makeWindow() -> NSWindow {
    _ = NSApplication.shared
    let w = NSWindow(contentRect: .init(x: 0, y: 0, width: 800, height: 400),
                     styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: true)
    w.isReleasedWhenClosed = false
    return w
}

/// Draws `view`'s drawRect into a bitmap (sRGB, bottom-left origin).
@MainActor private func render(_ view: NSView) -> (Int, Int) -> (r: Int, g: Int, b: Int, a: Int) {
    let w = Int(view.bounds.width), h = Int(view.bounds.height)
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: w, pixelsHigh: h, bitsPerSample: 8, samplesPerPixel: 4,
                               hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    view.draw(view.bounds)
    NSGraphicsContext.restoreGraphicsState()
    return { x, y in
        guard let c = rep.colorAt(x: x, y: h - 1 - y)?.usingColorSpace(.sRGB) else { return (0, 0, 0, 0) }
        return (Int((c.redComponent * 255).rounded()), Int((c.greenComponent * 255).rounded()),
                Int((c.blueComponent * 255).rounded()), Int((c.alphaComponent * 255).rounded()))
    }
}

/// A themed window with a fake tab bar whose command bar is built against `main`.
@MainActor private func commandBar(_ main: NSMenu) -> (NSWindow, NSView) {
    let w = makeWindow()
    W7SafariSetWindowThemed(w, true)
    let tabBar = NSView(frame: NSRect(x: 0, y: 0, width: 800, height: 30))
    w.contentView!.addSubview(tabBar)
    W7SafariCommandBarSetMainMenu(main)
    W7SafariCommandBarSetEnabled(true)
    var startX: CGFloat = 8, maxX: CGFloat = 792
    W7SafariLayoutCommandBar(tabBar, CGRect(x: 0, y: 2, width: 800, height: 26), &startX, &maxX)
    return (w, tabBar)
}

@MainActor private func tearDown(_ w: NSWindow, _ tabBar: NSView) {
    W7SafariRemoveCommandBar(tabBar)
    W7SafariCommandBarSetMainMenu(nil)
    W7SafariCommandBarSetEnabled(false)
    W7SafariSetWindowThemed(w, false)
    w.close()
}

/// ★ performs Safari's Bookmarks sidebar item through its menu (the toolbar item path is gone: its view is not a
/// control); Print performs safari_printDocument:; Home goHome:. The ★ right-click menu holds the copies in order.
@MainActor @Test func favoritesClickTogglesTheBookmarksSidebarThroughTheMenu() {
    let model = SafariModel(), target = makeSafariTarget(model)
    let (w, tabBar) = commandBar(safariMainMenu(target))
    defer { tearDown(w, tabBar) }
    let favorites = W7SafariCommandBarControl(tabBar, "Favorites")
    #expect(favorites != nil && W7SafariCommandControlAction(favorites!) == "toggleBookmarksSidebar:")
    #expect(W7SafariCommandControlClick(favorites!) && model.calls == ["toggleBookmarksSidebar:"])
    #expect(actions(W7SafariCommandControlMenu(favorites!)) == ["toggleBookmarksSidebar:", "toggleReadingListSidebar:", "toggleBookmarks:",
                                                                 "toggleHistoryInBookmarksView:", "toggleFavoritesBar:"])
    let print = W7SafariCommandBarControl(tabBar, "Print")
    #expect(print != nil && W7SafariCommandControlAction(print!) == "safari_printDocument:")
    #expect(W7SafariCommandControlClick(print!) && model.calls.last == "safari_printDocument:")
    let home = W7SafariCommandBarControl(tabBar, "Home")
    #expect(home != nil && W7SafariCommandControlAction(home!) == "goHome:")
    #expect(W7SafariCommandBarControl(tabBar, "Page") != nil && W7SafariCommandBarControl(tabBar, "Safety") != nil)
    #expect(actions(W7SafariCommandControlMenu(W7SafariCommandBarControl(tabBar, "Tools")!)).first == "showDownloads:")
    #expect(W7SafariCommandControlMenu(favorites!)?.items.first?.target === target)
}

/// An older Safari without the sidebar selectors: ★ falls back to Show Bookmarks; without any, ★ is hidden.
@MainActor @Test func favoritesFallsBackOrHidesWhenSafariLacksTheSelectors() {
    let model = SafariModel(), target = makeSafariTarget(model)
    let (w, tabBar) = commandBar(safariMainMenu(target, without: ["toggleBookmarksSidebar:", "safari_toggleSidebar:"]))
    let favorites = W7SafariCommandBarControl(tabBar, "Favorites")
    #expect(favorites != nil && W7SafariCommandControlAction(favorites!) == "toggleBookmarks:")
    #expect(W7SafariCommandControlClick(favorites!) && model.calls == ["toggleBookmarks:"])
    tearDown(w, tabBar)
    let (w2, tabBar2) = commandBar(safariMainMenu(target, without: ["toggleBookmarksSidebar:", "safari_toggleSidebar:", "toggleBookmarks:"]))
    defer { tearDown(w2, tabBar2) }
    #expect(W7SafariCommandBarControl(tabBar2, "Favorites") == nil)
    #expect(W7SafariCommandBarControl(tabBar2, "AddFavorite") != nil)   // ✚ is still there
}

/// ✚ follows Safari's validation: disabled (greyed at 40 %, no hover frame, "Open a page first") when Safari's menu
/// validation says so; a click then does nothing; enabled again on the next validation, and the click adds a bookmark.
@MainActor @Test func addFavoriteFollowsSafarisValidation() {
    let model = SafariModel(), target = makeSafariTarget(model)
    let (w, tabBar) = commandBar(safariMainMenu(target))
    defer { tearDown(w, tabBar) }
    let add = W7SafariCommandBarControl(tabBar, "AddFavorite")!
    #expect(W7SafariCommandControlAction(add) == "addBookmark:" && !W7SafariCommandControlIsDisabled(add))
    let enabledPx = render(add)
    var enabledPainted = 0, enabledOpaque = 0
    for y in 0..<Int(add.bounds.height) { for x in 0..<Int(add.bounds.width) where enabledPx(x, y).a > 0 { enabledPainted += 1; if enabledPx(x, y).a == 255 { enabledOpaque += 1 } } }
    #expect(enabledPainted > 40 && enabledOpaque > 30)

    model.canAddBookmark = false   // the Start Page: Safari disables Add Bookmark…
    W7SafariCommandBarRevalidate(w, true)
    #expect(W7SafariCommandControlIsDisabled(add) && add.toolTip == "Open a page first")
    let disabledPx = render(add)
    var opaque = 0, faded = 0
    for y in 0..<Int(add.bounds.height) { for x in 0..<Int(add.bounds.width) {
        let a = disabledPx(x, y).a
        if a == 255 { opaque += 1 }
        if a > 60 && a < 130 { faded += 1 }   // 40 % alpha
    } }
    #expect(opaque == 0 && faded > 30, "opaque \(opaque) faded \(faded)")
    add.mouseEntered(with: NSEvent.enterExitEvent(with: .mouseEntered, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: w.windowNumber,
                                                   context: nil, eventNumber: 0, trackingNumber: 0, userData: nil)!)
    let hoverPx = render(add)
    #expect(hoverPx(Int(add.bounds.width / 2), 0).a == 0)   // no hover frame while disabled
    #expect(!W7SafariCommandControlClick(add) && model.calls.isEmpty)   // the click does nothing

    model.canAddBookmark = true
    W7SafariCommandBarRevalidate(w, true)
    #expect(!W7SafariCommandControlIsDisabled(add) && add.toolTip == "Add Bookmark…")
    #expect(W7SafariCommandControlClick(add) && model.calls == ["addBookmark:"])
    // A stale verdict never swallows a click: Safari validates afresh on the click, and the drawing follows.
    model.canAddBookmark = false
    W7SafariCommandBarRevalidate(w, true)
    #expect(W7SafariCommandControlIsDisabled(add))
    model.canAddBookmark = true                                           // a page opened; no validation ran yet
    #expect(W7SafariCommandControlClick(add) && model.calls == ["addBookmark:", "addBookmark:"])
    #expect(!W7SafariCommandControlIsDisabled(add))
    model.canAddBookmark = false                                          // and the other way round
    #expect(!W7SafariCommandControlClick(add) && model.calls.count == 2 && W7SafariCommandControlIsDisabled(add))
}

/// Validation runs at most once per 250 ms per window (two requests within the interval → one validation at its end,
/// a request after it → another), and the last change is never lost.
@MainActor @Test func revalidationIsThrottledButCatchesTheLastChange() {
    let model = SafariModel(), target = makeSafariTarget(model)
    let (w, tabBar) = commandBar(safariMainMenu(target))
    defer { tearDown(w, tabBar) }
    let add = W7SafariCommandBarControl(tabBar, "AddFavorite")!
    RunLoop.main.run(until: Date().addingTimeInterval(0.05))   // the layout-time (zero-wait) validation drained
    W7SafariCommandBarRevalidate(w, true)
    let forcedAt = Date()
    #expect(!W7SafariCommandControlIsDisabled(add))
    model.canAddBookmark = false
    W7SafariCommandBarRevalidate(w, false)              // within 250 ms of the forced one: deferred, not dropped
    W7SafariCommandBarRevalidate(w, false)              // a second request in the interval: the same deferred run
    RunLoop.main.run(until: Date().addingTimeInterval(0.05))
    if Date().timeIntervalSince(forcedAt) < 0.2 {       // a slow machine could have crossed the interval already
        #expect(!W7SafariCommandControlIsDisabled(add))  // not before the interval ends
    }
    RunLoop.main.run(until: Date().addingTimeInterval(0.3))
    #expect(W7SafariCommandControlIsDisabled(add))       // once, at its end
    model.canAddBookmark = true
    W7SafariCommandBarRevalidate(w, false)              // 300 ms later: a second validation
    RunLoop.main.run(until: Date().addingTimeInterval(0.3))
    #expect(!W7SafariCommandControlIsDisabled(add))
    W7SafariCommandBarRevalidate(nil, true)             // no window: nothing
}

// MARK: - (plan "icons everywhere" ): the command buttons draw the user's Windows 7 pictures

/// A plain coloured square PNG (synthetic; nothing from Windows).
private func squarePNG(px: Int, r: CGFloat, g: CGFloat, b: CGFloat) -> Data {
    let ctx = CGContext(data: nil, width: px, height: px, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.setFillColor(red: r, green: g, blue: b, alpha: 1)
    ctx.fill(CGRect(x: 0, y: 0, width: px, height: px))
    return NSBitmapImageRep(cgImage: ctx.makeImage()!).representation(using: .png, properties: [:])!
}

/// Runs `body` with a temp asset root holding `icons` (name → PNG) and no embedded icons; the defaults come back after.
@MainActor private func withIconRoot(_ icons: [String: Data], _ body: (URL) throws -> Void) rethrows {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("w7cmdbar-icons-\(UUID().uuidString)")
    try? FileManager.default.createDirectory(at: root.appendingPathComponent("icons"), withIntermediateDirectories: true)
    for (name, png) in icons { try? png.write(to: root.appendingPathComponent("icons/\(name).png")) }
    W7UserIconsUseEmbedded([:])
    W7FolderIconUseAssetRoot(root.path)
    defer {
        W7UserIconsUseEmbedded(nil)
        W7FolderIconUseAssetRoot(nil)
        try? FileManager.default.removeItem(at: root)
    }
    try body(root)
}

private func isGreen(_ p: (r: Int, g: Int, b: Int, a: Int)) -> Bool { p.g > 200 && p.r < 60 && p.b < 60 && p.a > 230 }

@Test func commandGlyphIconNames() {
    #expect(W7IEGlyphIconName(.favorites) == "favorites")
    #expect(W7IEGlyphIconName(.addFavorite) == "ie-add-favorite")
    #expect(W7IEGlyphIconName(.home) == "ie-home")
    #expect(W7IEGlyphIconName(.print) == "ie-print")
    #expect(W7IEGlyphIconName(.help) == "ie-help")
    for g in [W7IEGlyph.favorites, .addFavorite, .home, .print, .help] {
        #expect(W7UserIconNames().contains(W7IEGlyphIconName(g) ?? ""), "\(g.rawValue) is in the chrome catalogue")
    }
}

/// Home draws ie-home.png (16 pt at x 6, centred) when the user has it, and the drawn house when not; the picture is
/// decoded once and redrawn from the button's cache, and a loader reset is followed.
@MainActor @Test func commandButtonDrawsTheUserIconWhenPresent() throws {
    let model = SafariModel(), target = makeSafariTarget(model)
    try withIconRoot([:]) { root in
        let (w, tabBar) = commandBar(safariMainMenu(target))
        defer { tearDown(w, tabBar) }
        let home = try #require(W7SafariCommandBarControl(tabBar, "Home"))
        let cy = Int(floor((home.bounds.height - 16) / 2)) + 8
        #expect(!isGreen(render(home)(14, cy)), "no ie-home.png: the drawn house")
        try squarePNG(px: 32, r: 0, g: 1, b: 0).write(to: root.appendingPathComponent("icons/ie-home.png"))
        W7FolderIconUseAssetRoot(root.path)   // the loader resets: the button asks again
        let px = render(home)
        #expect(isGreen(px(14, cy)) && isGreen(px(7, cy - 7)) && isGreen(px(21, cy + 7)), "\(px(14, cy))")
        #expect(!isGreen(px(3, cy)) && !isGreen(px(23, cy)), "16 pt wide at x 6")
        let decodes = W7UserIconDecodeCount()
        _ = render(home)
        #expect(W7UserIconDecodeCount() == decodes, "redrawn from the cache")
        try FileManager.default.removeItem(at: root.appendingPathComponent("icons/ie-home.png"))
        W7FolderIconUseAssetRoot(root.path)
        #expect(!isGreen(render(home)(14, cy)), "gone again: the drawn house")
    }
}

/// ✚ disabled by Safari's validation draws ie-add-favorite.png at 40 %; Favorites draws favorites.png; Print (and a
/// Help ▾) keep their drawn glyphs without their PNGs.
@MainActor @Test func disabledCommandButtonFadesTheUserIcon() throws {
    let model = SafariModel(), target = makeSafariTarget(model)
    let green = squarePNG(px: 64, r: 0, g: 1, b: 0)
    try withIconRoot(["ie-add-favorite": green, "favorites": green]) { _ in
        let (w, tabBar) = commandBar(safariMainMenu(target))
        defer { tearDown(w, tabBar) }
        let add = try #require(W7SafariCommandBarControl(tabBar, "AddFavorite"))
        let cy = Int(floor((add.bounds.height - 16) / 2)) + 8
        #expect(isGreen(render(add)(14, cy)))
        model.canAddBookmark = false
        W7SafariCommandBarRevalidate(w, true)
        let faded = render(add)(14, cy)
        #expect(faded.a > 80 && faded.a < 125 && faded.g > faded.r + 40, "40 % green \(faded)")
        let favorites = try #require(W7SafariCommandBarControl(tabBar, "Favorites"))
        #expect(isGreen(render(favorites)(14, cy)))
        let print = try #require(W7SafariCommandBarControl(tabBar, "Print"))
        #expect(!isGreen(render(print)(14, cy)))
        if let help = W7SafariCommandBarControl(tabBar, "Help") {   // only when the fake menu resolves a Help ▾
            #expect(!isGreen(render(help)(14, cy)))
        }
    }
}

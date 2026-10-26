import AppKit
import ObjectiveC
import Testing
import Win7ChromeCore

// Internet Explorer's rows in Safari — the navigation row's item order (pure, and on a real NSToolbar with
// an exact restore), Safari's menu items behind the command bar, and the command bar's layout.

// MARK: - Item order

private let safariDefault = ["NSToolbarFlexibleSpaceItem", "CombinedSidebarTabGroupToolbarIdentifier", "SidebarSeparatorToolbarItemIdentifier",
                             "TabGroupPickerToolbarIdentifier", "BackForwardToolbarIdentifier", "NSToolbarFlexibleSpaceItem",
                             "InputFieldsToolbarIdentifier", "NSToolbarFlexibleSpaceItem", "ShowDownloadsToolbarIdentifier",
                             "ShareToolbarIdentifier", "NewTabToolbarIdentifier", "TabPickerToolbarIdentifier"]
private let ieOrder = ["BackForwardToolbarIdentifier", "InputFieldsToolbarIdentifier", "CombinedSidebarTabGroupToolbarIdentifier",
                       "TabGroupPickerToolbarIdentifier", "ShowDownloadsToolbarIdentifier", "ShareToolbarIdentifier",
                       "NewTabToolbarIdentifier", "TabPickerToolbarIdentifier"]

@Test func ieToolbarOrderPutsOrbsAndAddressFirst() {
    #expect(W7SafariIEToolbarOrder(safariDefault) == ieOrder)
    #expect(W7SafariIEToolbarOrder(ieOrder) == ieOrder)   // idempotent
    // Unknown items (a web extension) join the right group in Safari's relative order.
    let withExtension = ["com.example.ext", "BackForwardToolbarIdentifier", "NSToolbarSpaceItem", "InputFieldsToolbarIdentifier", "ShareToolbarIdentifier"]
    #expect(W7SafariIEToolbarOrder(withExtension) == ["BackForwardToolbarIdentifier", "InputFieldsToolbarIdentifier", "com.example.ext", "ShareToolbarIdentifier"])
    #expect(W7SafariToolbarItemIsSpacer("NSToolbarFlexibleSpaceItem") && W7SafariToolbarItemIsSpacer("SidebarSeparatorToolbarItemIdentifier"))
    #expect(!W7SafariToolbarItemIsSpacer("ShareToolbarIdentifier"))
}

private func run(_ edits: [[AnyHashable: Any]], on list: [String]) -> [String] {
    var l = list
    for e in edits {
        let index = (e["index"] as! NSNumber).intValue, id = e["identifier"] as! String
        if (e["insert"] as! NSNumber).boolValue { l.insert(id, at: min(index, l.count)) } else { l.remove(at: index) }
    }
    return l
}

@Test func toolbarEditsReachTheTargetWithoutMovingTheAddressItem() {
    let protected = "InputFieldsToolbarIdentifier"
    let there = W7SafariToolbarEdits(safariDefault, ieOrder, protected)!
    #expect(run(there, on: safariDefault) == ieOrder)
    #expect(!there.contains { !(($0["insert"] as! NSNumber).boolValue) && ($0["identifier"] as! String) == protected })
    let back = W7SafariToolbarEdits(ieOrder, safariDefault, protected)!   // the restore
    #expect(run(back, on: ieOrder) == safariDefault)
    #expect(!back.contains { !(($0["insert"] as! NSNumber).boolValue) && ($0["identifier"] as! String) == protected })
    #expect(W7SafariToolbarEdits(ieOrder, ieOrder, protected)!.isEmpty)
}

@MainActor private final class OrderDelegate: NSObject, NSToolbarDelegate {
    let ids: [NSToolbarItem.Identifier]
    init(_ ids: [String]) { self.ids = ids.map { NSToolbarItem.Identifier($0) } }
    func toolbar(_ toolbar: NSToolbar, itemForItemIdentifier id: NSToolbarItem.Identifier, willBeInsertedIntoToolbar flag: Bool) -> NSToolbarItem? {
        let item = NSToolbarItem(itemIdentifier: id)
        item.label = id.rawValue
        if id.rawValue == "InputFieldsToolbarIdentifier" { item.view = NSTextField(frame: NSRect(x: 0, y: 0, width: 300, height: 22)) }
        return item
    }
    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] { ids }
    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] { ids + [.flexibleSpace] }
}

@MainActor @Test func toolbarOrderIsAppliedAndRestoredExactly() {
    _ = NSApplication.shared
    let ids = safariDefault.map { $0 == "NSToolbarFlexibleSpaceItem" ? NSToolbarItem.Identifier.flexibleSpace.rawValue : $0 }
    let delegate = OrderDelegate(ids)
    let toolbar = NSToolbar(identifier: "W7Test-\(UUID().uuidString)")
    toolbar.delegate = delegate
    toolbar.autosavesConfiguration = true
    toolbar.centeredItemIdentifiers = [NSToolbarItem.Identifier("InputFieldsToolbarIdentifier")]
    let w = NSWindow(contentRect: .init(x: 0, y: 0, width: 900, height: 300), styleMask: [.titled], backing: .buffered, defer: true)
    w.isReleasedWhenClosed = false
    w.toolbar = toolbar
    let before = toolbar.items.map(\.itemIdentifier.rawValue)
    #expect(before == ids)
    let address = toolbar.items.first { $0.itemIdentifier.rawValue == "InputFieldsToolbarIdentifier" }!
    W7SafariToolbarOrderSetEnabled(true)
    defer { W7SafariToolbarOrderSetEnabled(false) }

    W7SafariApplyToolbarOrder(w)
    #expect(toolbar.items.map(\.itemIdentifier.rawValue) == ieOrder)
    #expect(!toolbar.autosavesConfiguration && toolbar.centeredItemIdentifiers.isEmpty)
    #expect(toolbar.items[1] === address)                      // the address item itself never left the toolbar
    W7SafariApplyToolbarOrder(w)                               // idempotent
    #expect(toolbar.items.map(\.itemIdentifier.rawValue) == ieOrder)

    W7SafariRestoreToolbarOrder(w)
    #expect(toolbar.items.map(\.itemIdentifier.rawValue) == before)
    #expect(toolbar.autosavesConfiguration && toolbar.centeredItemIdentifiers == [NSToolbarItem.Identifier("InputFieldsToolbarIdentifier")])
    w.close()
}

@MainActor private func toolbarWindow(_ identifier: String, _ delegate: OrderDelegate) -> NSWindow {
    let toolbar = NSToolbar(identifier: identifier)
    toolbar.delegate = delegate
    toolbar.autosavesConfiguration = true
    let w = NSWindow(contentRect: .init(x: 0, y: 0, width: 900, height: 300), styleMask: [.titled, .closable], backing: .buffered, defer: true)
    w.isReleasedWhenClosed = false
    w.toolbar = toolbar
    return w
}

/// Two windows sharing one toolbar identifier (AppKit syncs their configuration): autosave is off on both while one is
/// themed; the restore waits for the last themed window; closing a window restores like un-theming; an item Safari or
/// the user adds while themed joins the saved order (in IE's right group meanwhile).
@MainActor @Test func toolbarOrderWithTwoWindowsCloseAndForeignAdd() {
    _ = NSApplication.shared
    let ids = safariDefault.map { $0 == "NSToolbarFlexibleSpaceItem" ? NSToolbarItem.Identifier.flexibleSpace.rawValue : $0 }
    let delegate = OrderDelegate(ids + ["com.example.ext"])
    let identifier = "W7TestShared-\(UUID().uuidString)"
    let w1 = toolbarWindow(identifier, delegate), w2 = toolbarWindow(identifier, delegate)
    for w in [w1, w2] { while w.toolbar!.items.count > ids.count { w.toolbar!.removeItem(at: w.toolbar!.items.count - 1) } }
    let before = w1.toolbar!.items.map(\.itemIdentifier.rawValue)
    W7SafariToolbarOrderSetEnabled(true)
    defer { W7SafariToolbarOrderSetEnabled(false) }

    W7SafariApplyToolbarOrder(w1)
    W7SafariApplyToolbarOrder(w2)
    #expect(w1.toolbar!.items.map(\.itemIdentifier.rawValue) == ieOrder)
    #expect(!w1.toolbar!.autosavesConfiguration && !w2.toolbar!.autosavesConfiguration)

    // A foreign insertion while themed (an extension item at the far left): taken into the saved order, re-applied.
    w1.toolbar!.insertItem(withItemIdentifier: NSToolbarItem.Identifier("com.example.ext"), at: 0)
    RunLoop.main.run(until: Date().addingTimeInterval(0.05))
    #expect(w1.toolbar!.items.map(\.itemIdentifier.rawValue) == ieOrder + ["com.example.ext"], "\(w1.toolbar!.items.map(\.itemIdentifier.rawValue))")

    // Un-theming one window: the other still shows the toolbar, so nothing is restored yet.
    W7SafariRestoreToolbarOrder(w1)
    #expect(w1.toolbar!.items.map(\.itemIdentifier.rawValue) == ieOrder + ["com.example.ext"])
    #expect(!w1.toolbar!.autosavesConfiguration && !w2.toolbar!.autosavesConfiguration)
    // Closing the last themed window restores Safari's order (the new item at the end) and both autosave flags.
    w2.close()
    #expect(w1.toolbar!.items.map(\.itemIdentifier.rawValue) == before + ["com.example.ext"])
    #expect(w1.toolbar!.autosavesConfiguration && w2.toolbar!.autosavesConfiguration)
    w1.close()
}

// MARK: - Safari's menu items behind the command bar

private final class MenuTarget: NSObject {
    @objc func zoomIn(_ s: Any?) {}
    @objc func zoomOut(_ s: Any?) {}
    @objc func resetZoom(_ s: Any?) {}
    @objc func saveDocumentAs(_ s: Any?) {}
    @objc func changeTextEncoding(_ s: Any?) {}
    @objc func showDownloads(_ s: Any?) {}
    @objc func showPreferences(_ s: Any?) {}
    @objc func createPrivateBrowsingWindow(_ s: Any?) {}
    @objc func clearHistoryAndWebsiteData(_ s: Any?) {}
    @objc func addBookmark(_ s: Any?) {}
    @objc func goHome(_ s: Any?) {}
}

@MainActor private func fakeMainMenu(_ target: MenuTarget) -> NSMenu {
    let main = NSMenu(title: "Main")
    func sub(_ title: String, _ items: [(String, String)]) -> NSMenu {
        let m = NSMenu(title: title)
        for (t, a) in items {
            let item = NSMenuItem(title: t, action: NSSelectorFromString(a), keyEquivalent: "")
            item.target = target
            m.addItem(item)
        }
        let holder = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        holder.submenu = m
        main.addItem(holder)
        return m
    }
    _ = sub("File", [("Yeni Gizli Pencere", "createPrivateBrowsingWindow:"), ("Farklı Kaydet…", "saveDocumentAs:")])
    let view = sub("View", [("Yakınlaştır", "zoomIn:"), ("Uzaklaştır", "zoomOut:"), ("Gerçek Boyut", "resetZoom:")])
    let encodings = NSMenu(title: "Metin Kodlaması")
    encodings.addItem(NSMenuItem(title: "UTF-8", action: NSSelectorFromString("changeTextEncoding:"), keyEquivalent: ""))
    let encodingHolder = NSMenuItem(title: "Metin Kodlaması", action: nil, keyEquivalent: "")
    encodingHolder.submenu = encodings
    view.addItem(encodingHolder)
    _ = sub("History", [("Ana Sayfa", "goHome:"), ("Geçmişi Temizle…", "clearHistoryAndWebsiteData:")])
    _ = sub("Bookmarks", [("Yer İmi Ekle…", "addBookmark:")])
    _ = sub("Window", [("İndirilenler", "showDownloads:")])
    _ = sub("Safari", [("Ayarlar…", "showPreferences:")])
    return main
}

@MainActor @Test func commandMenusAreBuiltFromSafarisOwnItems() {
    let target = MenuTarget()
    let main = fakeMainMenu(target)
    #expect(W7SafariFindMenuItem(main, ["nope:", "goHome:"])?.title == "Ana Sayfa")
    #expect(W7SafariFindMenuItem(main, ["zoomToActualSize:", "resetZoom:"])?.title == "Gerçek Boyut")
    #expect(W7SafariFindMenuItem(main, ["printDocument:"]) == nil)
    #expect(W7SafariFindMenuItem(nil, ["goHome:"]) == nil)

    let found = NSMutableArray()
    let page = W7SafariBuildCommandMenu(main, "Page", found)!
    #expect(page.items.map(\.title) == ["Yakınlaştır", "Uzaklaştır", "Gerçek Boyut", "", "Farklı Kaydet…", "Metin Kodlaması"])
    #expect(page.items[0].action == NSSelectorFromString("zoomIn:") && page.items[0].target === target)   // Safari's own target
    #expect(page.items[5].submenu?.items.first?.action == NSSelectorFromString("changeTextEncoding:"))
    #expect((found as! [String]).contains("zoomIn:"))
    let safety = W7SafariBuildCommandMenu(main, "Safety", NSMutableArray())!
    #expect(safety.items.map(\.title) == ["Yeni Gizli Pencere", "Geçmişi Temizle…"])
    let tools = W7SafariBuildCommandMenu(main, "Tools", NSMutableArray())!
    #expect(tools.items.map(\.title) == ["İndirilenler", "Ayarlar…"])
    #expect(W7SafariBuildCommandMenu(NSMenu(title: "Empty"), "Tools", NSMutableArray()) == nil)   // hidden
}

@Test func commandBarIsRightAligned() {
    #expect(W7SafariCommandButtonWidth(0, true, false) == 28)          // icon only
    #expect(W7SafariCommandButtonWidth(30, false, true) == 54)        // "Page ▾"
    #expect(W7SafariCommandButtonWidth(0, false, false) == 26)        // never narrower than 26
    var xs = [CGFloat](repeating: 0, count: 3)
    let left = W7SafariCommandBarLayout([28, 54, 60], 3, 500, 2, &xs)
    #expect(xs == [354, 384, 440] && left == 354)
}

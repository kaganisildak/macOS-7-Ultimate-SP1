import AppKit
import ObjectiveC
import Testing
import Win7ChromeCore
import Win7Theme

// the Explorer glass rect, the details pane and the restyled Finder content (sidebar rows,
// column headers). Windows here are never ordered on screen and no events are posted.

@MainActor private func explorerWindow(content: (NSView) -> Void = { _ in }) -> NSWindow {
    _ = NSApplication.shared
    let w = NSWindow(contentRect: .init(x: 0, y: 0, width: 800, height: 500),
                     styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                     backing: .buffered, defer: true)
    w.isReleasedWhenClosed = false
    w.titlebarAppearsTransparent = true
    w.toolbar = NSToolbar(identifier: "W7ExplorerContentTestToolbar")
    content(w.contentView!)
    return w
}

private func className(_ o: AnyObject) -> String { String(cString: object_getClassName(o)) }

@MainActor private func spin(_ seconds: TimeInterval) {
    RunLoop.main.run(until: Date(timeIntervalSinceNow: seconds))
}

@MainActor @Test func explorerGlassRectSpansTitleBarAndNavBar() {
    let w = explorerWindow()
    W7ExplorerAdopt(w)
    W7ChromeController.decorateWindow(w)
    let nav = w.titlebarAccessoryViewControllers[0].view
    let inNav = W7ExplorerGlassRect(w, nav)
    #expect(inNav.minY == -8)                     // runs 8 pt under the command bar
    #expect(inNav.maxY > nav.bounds.height + 20)  // and up through the title bar
    let titlebar = w.standardWindowButton(.closeButton)!.superview!
    let bar = titlebar.subviews.first { $0 is W7TitlebarView }!
    let inBar = W7ExplorerGlassRect(w, bar)
    #expect(inBar.maxY == bar.bounds.height)
    // The same rect, seen from both views.
    #expect(abs(bar.convert(inBar, to: nil).minY - nav.convert(inNav, to: nil).minY) < 0.5)
    w.close()
}

// MARK: - Details pane

@MainActor private func detailsPane(in view: NSView) -> NSView? {
    view.subviews.first { className($0) == "W7ExplorerDetailsView" }
}

@MainActor @Test func detailsPaneLiftsAutoresizingContent() {
    var child: NSView!
    let w = explorerWindow { content in
        child = NSView(frame: content.bounds)
        child.autoresizingMask = [.width, .height]
        content.addSubview(child)
    }
    W7ExplorerAdopt(w)
    let content = w.contentView!
    #expect(W7ExplorerDetailsPaneHeight == 60)
    #expect(child.frame.minY == W7ExplorerDetailsPaneHeight)
    #expect(child.frame.maxY == content.bounds.height)
    let pane = detailsPane(in: content)
    #expect(pane?.frame == NSRect(x: 0, y: 0, width: content.bounds.width, height: W7ExplorerDetailsPaneHeight))
    #expect(content.subviews.last === pane)
    w.close()
}

@MainActor @Test func detailsPaneLiftsConstrainedContent() {
    var child: NSView!
    let w = explorerWindow { content in
        child = NSView()
        child.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(child)
        NSLayoutConstraint.activate([
            child.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            child.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            child.topAnchor.constraint(equalTo: content.topAnchor),
            child.bottomAnchor.constraint(equalTo: content.bottomAnchor),
        ])
    }
    W7ExplorerAdopt(w)
    let content = w.contentView!
    content.layoutSubtreeIfNeeded()
    #expect(child.frame.minY == W7ExplorerDetailsPaneHeight)
    #expect(detailsPane(in: content) != nil)
    w.close()
}

@MainActor @Test func detailsPaneFloatsInSplitViewBrowserPaneWithInsets() {
    _ = NSApplication.shared
    let w = explorerWindow()
    let split = NSSplitView(frame: w.contentView!.bounds)
    split.isVertical = true
    let sidebar = NSView(frame: NSRect(x: 0, y: 0, width: 200, height: 500))
    let browser = NSView(frame: NSRect(x: 201, y: 0, width: 599, height: 500))
    let scroll = NSScrollView(frame: browser.bounds)
    scroll.autoresizingMask = [.width, .height]
    browser.addSubview(scroll)
    split.addArrangedSubview(sidebar)
    split.addArrangedSubview(browser)
    w.contentView = split
    W7ExplorerAdopt(w)
    #expect(!split.subviews.contains { className($0) == "W7ExplorerDetailsView" })   // never a split pane
    #expect(split.superview.map { detailsPane(in: $0) == nil } == true)              // never in the frame view
    let pane = detailsPane(in: browser)
    #expect(pane?.frame == NSRect(x: 0, y: 0, width: browser.bounds.width, height: W7ExplorerDetailsPaneHeight))
    #expect(scroll.contentInsets.bottom == W7ExplorerDetailsPaneHeight)
    #expect(!scroll.automaticallyAdjustsContentInsets)
    w.close()
}

@MainActor @Test func detailsPaneKeepsBottomStackedSiblingsStacked() {
    var browser: NSView!, status: NSView!
    let w = explorerWindow { content in
        let h = content.bounds.height
        status = NSView(frame: NSRect(x: 0, y: 0, width: content.bounds.width, height: 20))
        status.autoresizingMask = [.width, .maxYMargin]
        browser = NSView(frame: NSRect(x: 0, y: 20, width: content.bounds.width, height: h - 20))
        browser.autoresizingMask = [.width, .height]
        content.addSubview(browser)
        content.addSubview(status)
    }
    W7ExplorerAdopt(w)
    let h = w.contentView!.bounds.height
    #expect(status.frame.minY == W7ExplorerDetailsPaneHeight && status.frame.height == 20)
    #expect(browser.frame.minY == W7ExplorerDetailsPaneHeight + 20 && browser.frame.maxY == h)   // still right above the status bar
    w.close()
}

@MainActor @Test func detailsPaneLiftsStackedConstraintsByItsHeight() {
    var status: NSView!, browser: NSView!
    let w = explorerWindow { content in
        status = NSView(); browser = NSView()
        for v in [status!, browser!] { v.translatesAutoresizingMaskIntoConstraints = false; content.addSubview(v) }
        NSLayoutConstraint.activate([
            status.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            status.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            status.heightAnchor.constraint(equalToConstant: 20),
            status.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -10),
            browser.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            browser.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            browser.topAnchor.constraint(equalTo: content.topAnchor),
            browser.bottomAnchor.constraint(equalTo: status.topAnchor),
        ])
    }
    W7ExplorerAdopt(w)
    let content = w.contentView!
    content.layoutSubtreeIfNeeded()
    #expect(status.frame.minY == 10 + W7ExplorerDetailsPaneHeight)                   // moved BY the pane height from its original 10
    #expect(browser.frame.minY == status.frame.maxY)   // still stacked
    W7ExplorerAdopt(w)                                 // idempotent: no second lift
    content.layoutSubtreeIfNeeded()
    #expect(status.frame.minY == 10 + W7ExplorerDetailsPaneHeight)
    w.close()
}

@MainActor @Test func detailsPaneMovesFixedHeightViewsWithoutShrinking() {
    var fixed: NSView!
    let w = explorerWindow { content in
        // Reaches the top but has a fixed height and a flexible bottom margin: it moves, never shrinks.
        fixed = NSView(frame: content.bounds)
        fixed.autoresizingMask = [.width, .minYMargin]
        content.addSubview(fixed)
    }
    let height = fixed.frame.height
    W7ExplorerAdopt(w)
    let content = w.contentView!
    #expect(fixed.frame.height == height)   // not shrunk
    // Autoresizing keeps its top where it was when the title bar took room; the lift adds exactly the pane height.
    #expect(fixed.frame.minY == content.bounds.height - height + W7ExplorerDetailsPaneHeight)
    w.close()
}

final class FlippedView: NSView { override var isFlipped: Bool { true } }

@MainActor @Test func detailsPaneHandlesFlippedContent() {
    _ = NSApplication.shared
    let w = explorerWindow()
    let content = FlippedView(frame: w.contentView!.frame)
    let h = content.bounds.height
    let browser = NSView(frame: NSRect(x: 0, y: 0, width: content.bounds.width, height: h - 20))
    browser.autoresizingMask = [.width, .height]
    let status = NSView(frame: NSRect(x: 0, y: h - 20, width: content.bounds.width, height: 20))
    status.autoresizingMask = [.width, .minYMargin]
    content.addSubview(browser)
    content.addSubview(status)
    w.contentView = content
    W7ExplorerAdopt(w)
    let ch = content.bounds.height
    let pane = detailsPane(in: content)
    #expect(pane?.frame == NSRect(x: 0, y: ch - W7ExplorerDetailsPaneHeight, width: content.bounds.width, height: W7ExplorerDetailsPaneHeight))
    #expect(pane?.autoresizingMask.contains(.minYMargin) == true)
    #expect(status.frame.maxY == ch - W7ExplorerDetailsPaneHeight)              // the bottom bar sits right above the pane
    #expect(browser.frame.minY == 0 && browser.frame.maxY == status.frame.minY)
    w.close()
}

// MARK: - Navigation pane and column headers

@MainActor final class SidebarSource: NSObject, NSOutlineViewDataSource, NSOutlineViewDelegate {
    let groups = ["Favoriler", "Konumlar"]
    func kids(_ g: String) -> [String] { g == "Favoriler" ? ["Uygulamalar", "Belgeler"] : ["Macintosh HD"] }
    func outlineView(_ ov: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
        (item as? String).map { kids($0).count } ?? groups.count
    }
    func outlineView(_ ov: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
        (item as? String).map { kids($0)[index] } ?? groups[index]
    }
    func outlineView(_ ov: NSOutlineView, isItemExpandable item: Any) -> Bool { groups.contains(item as! String) }
    func outlineView(_ ov: NSOutlineView, isGroupItem item: Any) -> Bool { groups.contains(item as! String) }
    func outlineView(_ ov: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any) -> NSView? {
        let cell = NSTableCellView()
        let label = NSTextField(labelWithString: item as! String)
        if groups.contains(item as! String) {
            label.font = .boldSystemFont(ofSize: 11)
            label.textColor = .secondaryLabelColor
        }
        cell.addSubview(label)
        cell.textField = label
        return cell
    }
}

@MainActor @Test func sidebarIsRestyledAsNavigationPane() {
    let source = SidebarSource()
    var outline: NSOutlineView!
    var scroll: NSScrollView!
    let w = explorerWindow { content in
        scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 200, height: 400))
        outline = NSOutlineView(frame: scroll.bounds)
        outline.style = .sourceList
        outline.headerView = nil
        let col = NSTableColumn(identifier: .init("c"))
        col.width = 190
        outline.addTableColumn(col)
        outline.outlineTableColumn = col
        outline.dataSource = source
        outline.delegate = source
        scroll.documentView = outline
        content.addSubview(scroll)
        outline.reloadData()
        source.groups.forEach { outline.expandItem($0) }
    }
    w.appearance = NSAppearance(named: .aqua)   // the tree look applies in a light appearance
    W7ExplorerAdopt(w)
    outline.layoutSubtreeIfNeeded()
    NotificationCenter.default.post(name: NSWindow.didUpdateNotification, object: w)
    spin(0.25)

    #expect(outline.backgroundColor == .white)
    #expect(scroll.drawsBackground && scroll.backgroundColor == .white)
    var rows: [(Int, NSTableRowView)] = []
    outline.enumerateAvailableRowViews { rv, row in rows.append((row, rv)) }
    #expect(rows.count == 5)
    let font = W7UIFont(12)
    for (row, rv) in rows {
        #expect(rv.selectionHighlightStyle == .none)
        // The decoration sits right under the first cell (above AppKit's own row backgrounds).
        let firstCell = rv.subviews.firstIndex { $0 is NSTableCellView }!
        #expect(firstCell > 0 && className(rv.subviews[firstCell - 1]) == "W7NavPaneRowDecor", "row \(row)")
        let tf = rv.subviews.compactMap { ($0 as? NSTableCellView)?.textField }.first!
        #expect(tf.font == font)
        #expect(tf.textColor == .black, "row \(row)")
        if row == 0 { #expect(tf.attributedStringValue.string.hasPrefix("\u{FFFC} Favoriler")) }
        // Every section gets its tree icon: the star for Favorites, the computer for Locations.
        if row == 3 { #expect(tf.attributedStringValue.string.hasPrefix("\u{FFFC} Konumlar")) }
    }
    w.close()
    source.groups.forEach { _ in }   // keep the data source alive for the whole test
}

@MainActor @Test func columnHeaderGetsWindows7Look() throws {
    var table: NSTableView!
    let w = explorerWindow { content in
        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 400, height: 300))
        table = NSTableView(frame: scroll.bounds)
        for t in ["Ad", "Tür"] {
            let col = NSTableColumn(identifier: .init(t))
            col.title = t
            col.width = 150
            table.addTableColumn(col)
        }
        scroll.documentView = table
        content.addSubview(scroll)
    }
    W7ExplorerAdopt(w)
    let header = try #require(table.headerView)
    #expect(className(header).hasPrefix("W7ColumnHeader_"))
    #expect(header.isOpaque)
    header.frame.size.width = 400
    let rep = try #require(header.bitmapImageRepForCachingDisplay(in: header.bounds))
    header.cacheDisplay(in: header.bounds, to: rep)
    func px(_ x: Int, _ y: Int) -> (Int, Int, Int) {
        let c = rep.colorAt(x: x, y: y)!.usingColorSpace(.sRGB)!
        return (Int(c.redComponent * 255 + 0.5), Int(c.greenComponent * 255 + 0.5), Int(c.blueComponent * 255 + 0.5))
    }
    let h = rep.pixelsHigh, scale = rep.pixelsWide / 400
    let top = px(100 * scale, 1)          // bitmap rows run top-down
    let bottom = px(100 * scale, h - 1)   // the bottom line
    #expect(top.0 >= 250 && top.1 >= 250 && top.2 >= 250, "top \(top)")
    #expect(abs(bottom.0 - 0xD5) <= 12 && bottom.0 < 0xF2 - 12, "bottom \(bottom)")   // the line, not the gradient
    w.close()
}

@MainActor private func sortTable() -> (NSWindow, NSTableView) {
    var table: NSTableView!
    let w = explorerWindow { content in
        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 400, height: 300))
        table = NSTableView(frame: scroll.bounds)
        for t in ["Ad", "Tür"] {
            let col = NSTableColumn(identifier: .init(t))
            col.title = t
            col.width = 150
            col.sortDescriptorPrototype = NSSortDescriptor(key: t, ascending: true)
            table.addTableColumn(col)
        }
        scroll.documentView = table
        content.addSubview(scroll)
    }
    return (w, table)
}

/// The arrow at the top centre of `column`'s header: .up, .down, or nil when there is none.
@MainActor private func headerArrow(_ table: NSTableView, column: Int) -> W7ChevronDirection? {
    let header = table.headerView!
    header.frame.size.width = 400
    guard let rep = header.bitmapImageRepForCachingDisplay(in: header.bounds) else { return nil }
    header.cacheDisplay(in: header.bounds, to: rep)
    let s = CGFloat(rep.pixelsWide) / header.bounds.width
    let mid = header.headerRect(ofColumn: column).midX
    // Top-down rows: the arrow is centred 4 pt below the top and 4 pt tall; sample 2.5 pt right of
    // centre near its upper and lower edges.
    func dark(_ fromTop: CGFloat) -> Bool {
        let c = rep.colorAt(x: Int((mid + 2.5) * s), y: Int(fromTop * s))!.usingColorSpace(.sRGB)!
        return c.redComponent < 0.85
    }
    switch (dark(2.6), dark(5.4)) {
    case (false, true): return .up      // ▴: wide at the bottom
    case (true, false): return .down    // ▾: wide at the top
    default: return nil
    }
}

@MainActor @Test func columnHeaderArrowFollowsSortDescriptors() {
    let (w, table) = sortTable()
    table.sortDescriptors = [NSSortDescriptor(key: "Ad", ascending: true)]
    W7ExplorerAdopt(w)
    #expect(headerArrow(table, column: 0) == .up)
    #expect(headerArrow(table, column: 1) == nil)
    table.sortDescriptors = [NSSortDescriptor(key: "Tür", ascending: false)]
    #expect(headerArrow(table, column: 1) == .down)
    #expect(headerArrow(table, column: 0) == nil)
    w.close()
}

@MainActor @Test func columnHeaderArrowFollowsIndicatorImage() {
    let (w, table) = sortTable()
    table.sortDescriptors = []
    table.setIndicatorImage(NSImage(named: "NSDescendingSortIndicator"), in: table.tableColumns[1])
    W7ExplorerAdopt(w)
    #expect(headerArrow(table, column: 1) == .down)
    #expect(headerArrow(table, column: 0) == nil)
    table.setIndicatorImage(nil, in: table.tableColumns[1])
    table.setIndicatorImage(NSImage(named: "NSAscendingSortIndicator"), in: table.tableColumns[0])
    #expect(headerArrow(table, column: 0) == .up)
    w.close()
}

@MainActor @Test func restyledHeaderStillReportsItsClass() {
    let (w, table) = sortTable()
    W7ExplorerAdopt(w)
    let header = table.headerView!
    #expect(className(header).hasPrefix("W7ColumnHeader_"))
    #expect(type(of: header) == NSTableHeaderView.self)
    #expect(header.isMember(of: NSTableHeaderView.self))
    w.close()
}

@MainActor @Test func observedColumnHeaderIsLeftAlone() {
    final class Watcher: NSObject {}
    let watcher = Watcher()
    var table: NSTableView!
    let w = explorerWindow { content in
        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 400, height: 300))
        table = NSTableView(frame: scroll.bounds)
        table.addTableColumn(NSTableColumn(identifier: .init("a")))
        scroll.documentView = table
        content.addSubview(scroll)
    }
    let header = table.headerView!
    header.addObserver(watcher, forKeyPath: "frame", options: [], context: nil)
    W7ExplorerAdopt(w)
    #expect(className(header).hasPrefix("NSKVONotifying_"))
    header.removeObserver(watcher, forKeyPath: "frame")
    w.close()
}

/// Windows 7's Details view has no zebra stripes: the list under a column header is plain white.
@MainActor @Test func explorerListHasNoAlternatingRows() throws {
    var table: NSTableView!
    let w = explorerWindow { content in
        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 400, height: 300))
        table = NSTableView(frame: scroll.bounds)
        let col = NSTableColumn(identifier: .init("Ad"))
        col.title = "Ad"
        table.addTableColumn(col)
        table.usesAlternatingRowBackgroundColors = true
        scroll.documentView = table
        content.addSubview(scroll)
    }
    W7ExplorerAdopt(w)
    #expect(!table.usesAlternatingRowBackgroundColors)
    w.close()
}

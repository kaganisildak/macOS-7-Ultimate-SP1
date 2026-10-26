import AppKit
import Carbon.HIToolbox
import Win7Core
import Win7Theme

/// Windows 7's Device Manager: a viewer. The menu strip (File, Action, View, Help), the toolbar
/// (only Properties acts), and the tree: the computer's name, its device categories, their devices, filled from one
/// `system_profiler` run each time the window opens (DeviceTree.load). Nothing here changes a driver or a setting.
@MainActor
final class DeviceManagerWindow: ShellWindow, NSOutlineViewDataSource, NSOutlineViewDelegate {
    static let shared = DeviceManagerWindow()
    static let defaultSize = NSSize(width: 520, height: 460)

    private let strip = ShellMenuStripView()
    private let toolBar = DeviceToolbarView()
    private let scroll = NSScrollView()
    private let outline = DeviceOutlineView()
    /// Until the first load: the computer name from the local dynamic store (never a network lookup).
    private var root = DeviceTreeItem(.root(name: DeviceTree.computerName()))
    private var loadGeneration = 0

    private init() {
        super.init(spec: Spec(identifier: ShellWindowTarget.deviceManager.identifier, title: ShellWindowTarget.deviceManager.title,
                              frameName: "Win7DeviceManager", defaultSize: Self.defaultSize,
                              minSize: NSSize(width: 360, height: 260),
                              icon: { DeviceIcons.deviceManagerWindow(side: $0) }, logName: "device manager"))
        buildContent()
        finishSetup()
    }

    private func buildContent() {
        let size = Self.defaultSize
        let content = NSView(frame: NSRect(origin: .zero, size: size))
        let stripH = W7MenuStripHeight, barH = DeviceToolbarView.height
        strip.frame = NSRect(x: 0, y: size.height - stripH, width: size.width, height: stripH)
        strip.autoresizingMask = [.width, .minYMargin]
        strip.entries = [
            .init(title: "File") { [weak self] in self?.fileMenu() ?? NSMenu() },
            .init(title: "Action") { [weak self] in self?.actionMenu() ?? NSMenu() },
            .init(title: "View") { Self.viewMenu() },
            .init(title: "Help") { Self.helpMenu() },
        ]
        toolBar.frame = NSRect(x: 0, y: size.height - stripH - barH, width: size.width, height: barH)
        toolBar.autoresizingMask = [.width, .minYMargin]
        toolBar.onProperties = { [weak self] in self?.showProperties() }

        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("device"))
        column.resizingMask = .autoresizingMask
        outline.addTableColumn(column)
        outline.outlineTableColumn = column
        outline.headerView = nil
        outline.style = .plain
        outline.rowHeight = 20
        outline.intercellSpacing = .zero
        outline.indentationPerLevel = 16
        outline.backgroundColor = .white
        outline.focusRingType = .none
        outline.columnAutoresizingStyle = .uniformColumnAutoresizingStyle
        outline.dataSource = self
        outline.delegate = self
        outline.target = self
        outline.doubleAction = #selector(doubleClicked(_:))
        outline.onActivate = { [weak self] in self?.activateSelection() }
        scroll.frame = NSRect(x: 0, y: 0, width: size.width, height: size.height - stripH - barH)
        scroll.autoresizingMask = [.width, .height]
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.borderType = .noBorder
        scroll.backgroundColor = .white
        scroll.documentView = outline
        for v in [strip, toolBar, scroll] as [NSView] { content.addSubview(v) }
        contentView = content
        reloadTree(select: true)
    }

    // MARK: Showing

    /// Brings the window forward; opening it (it was closed) reads the devices again, once.
    func show() {
        if !isVisible && !isMiniaturized { load() }
        present("devices by type")
        makeFirstResponder(outline)
    }

    private func load() {
        loadGeneration += 1
        let generation = loadGeneration
        let started = Date()
        DeviceTree.load { [weak self] categories, computerName in
            MainActor.assumeIsolated {
                guard let self, generation == self.loadGeneration else { return }
                let devices = categories.reduce(0) { $0 + $1.devices.count }
                ShellWindowButtons.log.info("device manager: \(categories.count) categories, \(devices) devices in \(Date().timeIntervalSince(started), format: .fixed(precision: 1)) s")
                self.apply(categories, computerName: computerName)
            }
        }
    }

    private func apply(_ categories: [DeviceCategory], computerName: String) {
        root = DeviceTreeItem(.root(name: computerName))
        root.children = categories.map { c in
            let item = DeviceTreeItem(.category(c.kind))
            item.children = c.devices.map { DeviceTreeItem(.device($0, c.kind)) }
            return item
        }
        reloadTree(select: true)
    }

    /// The root expanded and selected, the categories collapsed (as Windows 7 opens Device Manager).
    private func reloadTree(select: Bool) {
        outline.reloadData()
        outline.expandItem(root)
        if select { outline.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false) }
        updateToolbar()
    }

    // MARK: Data source and delegate

    func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
        guard let item = item as? DeviceTreeItem else { return 1 }
        return item.children.count
    }

    func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
        guard let item = item as? DeviceTreeItem else { return root }
        return item.children[index]
    }

    func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool {
        !((item as? DeviceTreeItem)?.children.isEmpty ?? true)
    }

    func outlineView(_ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any) -> NSView? {
        guard let item = item as? DeviceTreeItem else { return nil }
        let cell = (outlineView.makeView(withIdentifier: DeviceTreeCellView.identifier, owner: nil) as? DeviceTreeCellView)
            ?? DeviceTreeCellView()
        cell.identifier = DeviceTreeCellView.identifier
        cell.item = item
        cell.expandable = !item.children.isEmpty
        cell.expanded = outlineView.isItemExpanded(item)
        cell.outline = outline
        return cell
    }

    func outlineView(_ outlineView: NSOutlineView, rowViewForItem item: Any) -> NSTableRowView? {
        DeviceTreeRowView()
    }

    func outlineViewSelectionDidChange(_ notification: Notification) { updateToolbar() }

    func outlineViewItemDidExpand(_ notification: Notification) { refreshExpander(notification) }
    func outlineViewItemDidCollapse(_ notification: Notification) { refreshExpander(notification) }

    private func refreshExpander(_ notification: Notification) {
        guard let item = notification.userInfo?["NSObject"] else { return }
        let row = outline.row(forItem: item)
        guard row >= 0, let cell = outline.view(atColumn: 0, row: row, makeIfNecessary: false) as? DeviceTreeCellView else { return }
        cell.expanded = outline.isItemExpanded(item)
    }

    // MARK: Actions

    private var selectedItem: DeviceTreeItem? {
        outline.selectedRow >= 0 ? outline.item(atRow: outline.selectedRow) as? DeviceTreeItem : nil
    }

    /// What Properties shows for the selection: a device, or the root as the computer; nil for a category.
    private var selectedProperties: DeviceProperties? {
        switch selectedItem?.kind {
        case .device(let node, let kind): DeviceProperties(node, kind: kind)
        case .root(let name):
            DeviceProperties(DeviceNode(name: name, manufacturer: computerNode?.manufacturer), kind: .computer)
        default: nil
        }
    }

    private var computerNode: DeviceNode? {
        for c in root.children { if case .category(.computer) = c.kind, case .device(let n, _)? = c.children.first?.kind { return n } }
        return nil
    }

    private func updateToolbar() { toolBar.propertiesEnabled = selectedProperties != nil }

    @objc private func doubleClicked(_ sender: Any?) {
        guard outline.clickedRow >= 0 else { return }
        activateSelection()
    }

    /// Double-click or Return: a category (or the root) opens or closes, a device shows its Properties.
    private func activateSelection() {
        guard let item = selectedItem else { return }
        if case .device = item.kind { showProperties(); return }
        if outline.isItemExpanded(item) { outline.collapseItem(item) } else { outline.expandItem(item) }
    }

    private func showProperties() {
        guard let props = selectedProperties, let item = selectedItem else { return }
        let kind: DeviceKind = if case .device(_, let k) = item.kind { k } else { .computer }
        DevicePropertiesWindow.present(props, icon: DeviceIcons.image(kind, side: 32), over: self)
    }

    // MARK: Menus

    private func fileMenu() -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false
        menu.addItem(MenuAction.item("Options…", enabled: false) {})
        menu.addItem(.separator())
        menu.addItem(MenuAction.item("Exit") { [weak self] in self?.performClose(nil) })
        return menu
    }

    private func actionMenu() -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false
        for title in ["Update Driver Software…", "Disable", "Uninstall"] { menu.addItem(MenuAction.item(title, enabled: false) {}) }
        menu.addItem(.separator())
        menu.addItem(MenuAction.item("Scan for hardware changes", enabled: false) {})
        menu.addItem(.separator())
        menu.addItem(MenuAction.item("Properties", enabled: selectedProperties != nil) { [weak self] in self?.showProperties() })
        return menu
    }

    private static func viewMenu() -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false
        let byType = MenuAction.item("Devices by type") {}
        byType.state = .on
        menu.addItem(byType)
        for title in ["Devices by connection", "Resources by type", "Resources by connection"] {
            menu.addItem(MenuAction.item(title, enabled: false) {})
        }
        menu.addItem(.separator())
        menu.addItem(MenuAction.item("Show hidden devices", enabled: false) {})
        menu.addItem(.separator())
        menu.addItem(MenuAction.item("Customize…", enabled: false) {})
        return menu
    }

    /// Help Topics: Windows Help and Support's topic about these windows.
    private static func helpMenu() -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false
        menu.addItem(MenuAction.item("Help Topics") { HelpWindow.shared.show(topic: "devices") })
        return menu
    }

    // MARK: Keyboard

    /// Alt+F, Alt+A, Alt+V, Alt+H open the menus (Option on a Mac keyboard); Alt+Return shows Properties.
    override func handleKey(_ event: NSEvent) -> Bool {
        let flags = Self.flags(event)
        if flags == .option {
            let menus = [kVK_ANSI_F: 0, kVK_ANSI_A: 1, kVK_ANSI_V: 2, kVK_ANSI_H: 3]
            if let i = menus[Int(event.keyCode)] { strip.popUp(i); return true }
            if Int(event.keyCode) == kVK_Return { showProperties(); return true }
        }
        return super.handleKey(event)
    }
}

// MARK: - Tree

/// One row of the tree; NSOutlineView keeps items by identity, so a class.
final class DeviceTreeItem: NSObject {
    enum Kind {
        case root(name: String)
        case category(DeviceKind)
        case device(DeviceNode, DeviceKind)
    }
    let kind: Kind
    var children: [DeviceTreeItem] = []
    init(_ kind: Kind) { self.kind = kind }

    var title: String {
        switch kind {
        case .root(let name): name
        case .category(let k): k.title
        case .device(let n, _): n.name
        }
    }
}

/// The tree: no native disclosure triangles (each cell draws the Windows 7 expander, and a click on it toggles);
/// Return activates the selection; the row under the mouse is highlighted as in Explorer's navigation pane.
@MainActor
final class DeviceOutlineView: NSOutlineView {
    var onActivate: (() -> Void)?
    private(set) var hoverRow = -1
    static let expanderWidth: CGFloat = 16

    override func frameOfOutlineCell(atRow row: Int) -> NSRect { .zero }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    private var hoverArea: NSTrackingArea?

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        guard hoverArea == nil else { return }   // .inVisibleRect follows the visible rect by itself
        let area = NSTrackingArea(rect: .zero, options: [.mouseMoved, .mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                  owner: self, userInfo: nil)
        addTrackingArea(area)
        hoverArea = area
    }

    override func mouseMoved(with event: NSEvent) {
        setHover(row(at: convert(event.locationInWindow, from: nil)))
    }

    override func mouseExited(with event: NSEvent) { setHover(-1) }

    private func setHover(_ row: Int) {
        guard row != hoverRow else { return }
        for r in [hoverRow, row] where r >= 0 && r < numberOfRows {
            (rowView(atRow: r, makeIfNecessary: false) as? DeviceTreeRowView)?.hovered = (r == row)
            (view(atColumn: 0, row: r, makeIfNecessary: false) as? DeviceTreeCellView)?.needsDisplay = true
        }
        hoverRow = row
    }

    /// The expander's rect in a row (outline coordinates), where the cell starts after its indentation.
    func expanderRect(row: Int) -> NSRect {
        let cell = frameOfCell(atColumn: 0, row: row)
        return NSRect(x: cell.minX, y: cell.minY, width: Self.expanderWidth, height: cell.height)
    }

    override func mouseDown(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        let r = row(at: p)
        if r >= 0, let item = item(atRow: r), isExpandable(item), expanderRect(row: r).contains(p) {
            if isItemExpanded(item) { collapseItem(item) } else { expandItem(item) }
            return
        }
        super.mouseDown(with: event)
    }

    override func keyDown(with event: NSEvent) {
        let k = Int(event.keyCode)
        if (k == kVK_Return || k == kVK_ANSI_KeypadEnter) && ShellWindow.flags(event).isEmpty {
            onActivate?()
            return
        }
        super.keyDown(with: event)
    }
}

/// Explorer's navigation-pane row look: selection `#CCE8FF` / `#99D1FF`, hover `#E5F3FB` / `#70C0E7`.
@MainActor
final class DeviceTreeRowView: NSTableRowView {
    var hovered = false { didSet { if hovered != oldValue { needsDisplay = true } } }

    override func drawBackground(in dirtyRect: NSRect) {
        NSColor.white.setFill()
        bounds.fill()
        guard hovered, !isSelected, let ctx = NSGraphicsContext.current?.cgContext else { return }
        W7DrawNavPaneRow(ctx, rowRect, false, true)
    }

    override func drawSelection(in dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        W7DrawNavPaneRow(ctx, rowRect, true, hovered)
    }

    /// The highlight box, around the cell's icon and text (from the expander's right edge), as Explorer draws it.
    private var rowRect: NSRect {
        let indent = (subviews.first?.frame.minX ?? 0) + DeviceOutlineView.expanderWidth - 1
        return NSRect(x: indent, y: 0.5, width: max(0, bounds.width - indent - 2), height: bounds.height - 1)
    }
}

/// A row's expander, 16 pt icon and 12 pt name, drawn (black text whatever the selection).
@MainActor
final class DeviceTreeCellView: NSView {
    static let identifier = NSUserInterfaceItemIdentifier("deviceCell")
    var item: DeviceTreeItem? { didSet { needsDisplay = true } }
    var expandable = false { didSet { needsDisplay = true } }
    var expanded = false { didSet { needsDisplay = true } }
    weak var outline: DeviceOutlineView?
    private static let font = W7UIFont(12)

    override var isFlipped: Bool { false }

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext, let item else { return }
        let w = DeviceOutlineView.expanderWidth
        if expandable {
            let row = outline?.row(for: self) ?? -1
            let hover = row >= 0 && row == outline?.hoverRow
            W7DrawTreeExpander(ctx, NSRect(x: 0, y: 0, width: w, height: bounds.height), expanded, hover)
        }
        let icon: NSImage
        switch item.kind {
        case .root: icon = DeviceIcons.image(.computer, side: 16)
        case .category(let k), .device(_, let k): icon = DeviceIcons.image(k, side: 16)
        }
        icon.draw(in: NSRect(x: w + 2, y: floor((bounds.height - 16) / 2), width: 16, height: 16))
        let title = item.title as NSString
        let size = title.size(withAttributes: [.font: Self.font])
        let style = NSMutableParagraphStyle()
        style.lineBreakMode = .byTruncatingTail
        title.draw(in: NSRect(x: w + 22, y: floor((bounds.height - size.height) / 2), width: max(0, bounds.width - w - 24),
                              height: size.height),
                   withAttributes: [.font: Self.font, .foregroundColor: NSColor.black, .paragraphStyle: style])
    }
}

// MARK: - Toolbar

/// Device Manager's toolbar: Back, Forward | Properties | Update Driver Software, Uninstall, Scan for hardware
/// changes. Only Properties acts (when the selection has properties); the rest are drawn disabled.
@MainActor
final class DeviceToolbarView: NSView {
    static let height: CGFloat = 26
    var onProperties: (() -> Void)?
    var propertiesEnabled = false { didSet { needsDisplay = true } }
    private var hover = false
    private var pressed = false
    private static let button = NSSize(width: 24, height: 22)
    private static let layout: [ToolbarGlyph?] = [.back, .forward, nil, .properties, nil, .update, .uninstall, .scan]

    override init(frame: NSRect) {
        super.init(frame: frame)
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseMoved, .mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                       owner: self, userInfo: nil))
        for (glyph, rect) in buttonRects() { addToolTip(rect, owner: Self.tip(glyph) as NSString, userData: nil) }
    }
    required init?(coder: NSCoder) { fatalError() }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override var mouseDownCanMoveWindow: Bool { false }

    private static func tip(_ g: ToolbarGlyph) -> String {
        switch g {
        case .back: "Back"
        case .forward: "Forward"
        case .properties: "Properties"
        case .update: "Update Driver Software…"
        case .uninstall: "Uninstall"
        case .scan: "Scan for hardware changes"
        }
    }

    private func buttonRects() -> [(ToolbarGlyph, NSRect)] {
        var x: CGFloat = 4
        var out: [(ToolbarGlyph, NSRect)] = []
        for g in Self.layout {
            guard let g else { x += 7; continue }
            out.append((g, NSRect(x: x, y: floor((Self.height - Self.button.height) / 2), width: Self.button.width,
                                  height: Self.button.height)))
            x += Self.button.width + 1
        }
        return out
    }

    private var propertiesRect: NSRect { buttonRects().first { $0.0 == .properties }!.1 }

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        NSColor(srgbRed: 0xF0 / 255, green: 0xF0 / 255, blue: 0xF0 / 255, alpha: 1).setFill()
        bounds.fill()
        NSColor(srgbRed: 0xD5 / 255, green: 0xDF / 255, blue: 0xE5 / 255, alpha: 1).setFill()
        NSRect(x: 0, y: 0, width: bounds.width, height: 1).fill()
        var x: CGFloat = 4
        for g in Self.layout {
            guard g == nil else { x += Self.button.width + 1; continue }
            // A groove between groups.
            NSColor(white: 0.70, alpha: 1).setFill()
            NSRect(x: x + 3, y: 5, width: 1, height: Self.height - 10).fill()
            NSColor.white.setFill()
            NSRect(x: x + 4, y: 5, width: 1, height: Self.height - 10).fill()
            x += 7
        }
        for (g, r) in buttonRects() {
            let enabled = g == .properties && propertiesEnabled
            if enabled && (hover || pressed) { W7DrawCommandButton(ctx, r, pressed && hover ? .pressed : .hover) }
            ctx.saveGState()
            if !enabled { ctx.setAlpha(0.4) }
            g.draw(ctx, NSRect(x: r.midX - 8, y: r.midY - 8, width: 16, height: 16))
            ctx.restoreGState()
        }
    }

    override func mouseMoved(with event: NSEvent) {
        let h = propertiesRect.contains(convert(event.locationInWindow, from: nil))
        if h != hover { hover = h; needsDisplay = true }
    }

    override func mouseExited(with event: NSEvent) {
        if hover { hover = false; needsDisplay = true }
    }

    override func mouseDown(with event: NSEvent) {
        pressed = propertiesEnabled && propertiesRect.contains(convert(event.locationInWindow, from: nil))
        hover = pressed
        needsDisplay = true
    }

    override func mouseDragged(with event: NSEvent) {
        let h = propertiesRect.contains(convert(event.locationInWindow, from: nil))
        if h != hover { hover = h; needsDisplay = true }
    }

    override func mouseUp(with event: NSEvent) {
        let fire = pressed && propertiesRect.contains(convert(event.locationInWindow, from: nil))
        pressed = false
        needsDisplay = true
        if fire && propertiesEnabled { onProperties?() }
    }
}

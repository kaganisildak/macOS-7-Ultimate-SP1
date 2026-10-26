import AppKit
import Carbon.HIToolbox
import Win7Core
import Win7Theme

/// Windows 7's Devices and Printers: the Control Panel's address row, the command bar ("Add a
/// device" opens the Bluetooth pane, "Add a printer" Printers & Scanners), and the icon view with its "Devices"
/// and "Printers and Faxes" groups (48 pt icons, the name under each), filled from one `system_profiler` run each
/// time the window opens. A device does nothing but show its Properties (double-click, Return, or right-click).
@MainActor
final class DevicesAndPrintersWindow: ShellWindow {
    static let shared = DevicesAndPrintersWindow()
    static let defaultSize = NSSize(width: 760, height: 520)

    private let header = ControlPanelHeaderView()
    private let commandBar = DevicesCommandBar()
    private let scroll = NSScrollView()
    private let tiles = DeviceTilesView()
    private let details = DeviceDetailsPane()
    /// Until the first load: the computer tile under the local store's name (or "Computer").
    private var model = DevicesAndPrinters(categories: [], computerName: DeviceTree.computerName())
    private var query = ""
    private var loadGeneration = 0
    private static let selfCrumb = ControlPanelLocation.info(title: "Devices and Printers", text: "", category: .hardwareAndSound)

    private init() {
        super.init(spec: Spec(identifier: ShellWindowTarget.devicesAndPrinters.identifier,
                              title: ShellWindowTarget.devicesAndPrinters.title, frameName: "Win7DevicesAndPrinters",
                              defaultSize: Self.defaultSize, minSize: NSSize(width: 480, height: 320),
                              icon: { DeviceIcons.devicesAndPrintersWindow(side: $0) }, logName: "devices and printers"))
        buildContent()
        finishSetup()
    }

    private func buildContent() {
        let size = Self.defaultSize
        let content = NSView(frame: NSRect(origin: .zero, size: size))
        let h = ControlPanelLayout.headerHeight, barH = DevicesCommandBar.height, detailsH = DeviceDetailsPane.height
        header.frame = NSRect(x: 0, y: size.height - h, width: size.width, height: h)
        header.autoresizingMask = [.width, .minYMargin]
        header.setPlaceholder("Search Devices and Printers")
        header.addressIcon = { DeviceIcons.devicesAndPrintersWindow(side: $0) }
        header.update(crumbs: [ControlPanelCrumb("Control Panel", .home),
                               ControlPanelCrumb(ControlPanelCategory.hardwareAndSound.title, .category(.hardwareAndSound)),
                               ControlPanelCrumb("Devices and Printers", Self.selfCrumb)],
                      canGoBack: false, canGoForward: false)
        header.onCrumb = { location in
            guard location != Self.selfCrumb else { return }
            ControlPanelWindow.shared.show(location)
        }
        header.onSearch = { [weak self] text in self?.searchChanged(text) }
        commandBar.frame = NSRect(x: 0, y: size.height - h - barH, width: size.width, height: barH)
        commandBar.autoresizingMask = [.width, .minYMargin]
        commandBar.onCommand = { pane in
            if let url = URL(string: "x-apple.systempreferences:" + pane) { NSWorkspace.shared.open(url) }
        }
        details.frame = NSRect(x: 0, y: 0, width: size.width, height: detailsH)
        details.autoresizingMask = [.width, .maxYMargin]
        scroll.frame = NSRect(x: 0, y: detailsH, width: size.width, height: size.height - h - barH - detailsH)
        scroll.autoresizingMask = [.width, .height]
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.borderType = .noBorder
        scroll.drawsBackground = true
        scroll.backgroundColor = .white
        scroll.documentView = tiles
        scroll.contentView.postsFrameChangedNotifications = true
        NotificationCenter.default.addObserver(forName: NSView.frameDidChangeNotification, object: scroll.contentView,
                                               queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.fitTiles() }
        }
        tiles.onSelect = { [weak self] tile in self?.details.show(tile, count: self?.itemCount ?? 0) }
        tiles.onOpen = { [weak self] tile in self?.showProperties(tile) }
        for v in [header, commandBar, scroll, details] as [NSView] { content.addSubview(v) }
        contentView = content
        refresh()
    }

    override func keyStateChanged() { header.needsDisplay = true }

    private var itemCount: Int { model.devices.count + model.printers.count }

    // MARK: Showing

    /// Brings the window forward; opening it (it was closed) reads the devices again, once.
    func show() {
        if !isVisible && !isMiniaturized { load() }
        present("devices and printers")
        makeFirstResponder(tiles)
    }

    private func load() {
        loadGeneration += 1
        let generation = loadGeneration
        let started = Date()
        DeviceTree.load { [weak self] categories, computerName in
            MainActor.assumeIsolated {
                guard let self, generation == self.loadGeneration else { return }
                let view = DevicesAndPrinters(categories: categories, computerName: computerName)
                ShellWindowButtons.log.info("devices and printers: \(view.devices.count) devices, \(view.printers.count) printers in \(Date().timeIntervalSince(started), format: .fixed(precision: 1)) s")
                self.model = view
                self.refresh()
            }
        }
    }

    private func searchChanged(_ text: String) {
        query = text
        refresh()
    }

    private func refresh() {
        let shown = model.filtered(query)
        tiles.show(shown)
        fitTiles()
        details.show(nil, count: shown.devices.count + shown.printers.count)
    }

    private func fitTiles() {
        let size = scroll.contentSize
        tiles.layoutTiles(width: size.width)
        let target = NSSize(width: size.width, height: max(tiles.contentHeight, size.height))
        if tiles.frame.size != target { tiles.setFrameSize(target) }
    }

    private func showProperties(_ tile: DeviceTile) {
        DevicePropertiesWindow.present(DeviceProperties(tile.node, kind: tile.kind),
                                       icon: DeviceIcons.image(tile.kind, side: 32), over: self)
    }

    // MARK: Keyboard

    /// Cmd+F goes to the search box; Esc clears a search.
    override func handleKey(_ event: NSEvent) -> Bool {
        let flags = Self.flags(event)
        switch Int(event.keyCode) {
        case kVK_ANSI_F where flags == .command:
            header.focusSearch()
            return true
        case kVK_Escape where flags.isEmpty && !query.isEmpty:
            header.clearSearch()
            searchChanged("")
            return true
        default:
            return super.handleKey(event)
        }
    }
}

// MARK: - Command bar

/// Explorer's command bar with "Add a device" and "Add a printer". Non-flipped.
@MainActor
final class DevicesCommandBar: NSView {
    static let height: CGFloat = 32
    /// Called with the System Settings pane to open.
    var onCommand: ((String) -> Void)?
    private let commands = [("Add a device", ControlPanelCatalog.Pane.bluetooth), ("Add a printer", ControlPanelCatalog.Pane.printers)]
    private var hover: Int?
    private var pressed: Int?
    private static let font = W7UIFont(12)
    private static let text = NSColor(srgbRed: 0x1E / 255, green: 0x39 / 255, blue: 0x5B / 255, alpha: 1)

    override init(frame: NSRect) {
        super.init(frame: frame)
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseMoved, .mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                       owner: self, userInfo: nil))
    }
    required init?(coder: NSCoder) { fatalError() }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override var mouseDownCanMoveWindow: Bool { false }

    private var rects: [NSRect] {
        var x: CGFloat = 8
        return commands.map { c in
            let w = ceil((c.0 as NSString).size(withAttributes: [.font: Self.font]).width) + 18
            defer { x += w + 2 }
            return NSRect(x: x, y: 4, width: w, height: bounds.height - 8)
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        W7DrawCommandBar(ctx, bounds)
        for (i, r) in rects.enumerated() {
            if hover == i || pressed == i { W7DrawCommandButton(ctx, r, pressed == i && hover == i ? .pressed : .hover) }
            let t = commands[i].0 as NSString
            let size = t.size(withAttributes: [.font: Self.font])
            t.draw(at: NSPoint(x: r.midX - size.width / 2, y: r.midY - size.height / 2),
                   withAttributes: [.font: Self.font, .foregroundColor: Self.text])
        }
    }

    private func index(_ event: NSEvent) -> Int? {
        let p = convert(event.locationInWindow, from: nil)
        return rects.firstIndex { $0.contains(p) }
    }

    override func mouseMoved(with event: NSEvent) {
        let i = index(event)
        if i != hover { hover = i; needsDisplay = true }
    }

    override func mouseExited(with event: NSEvent) {
        if hover != nil { hover = nil; needsDisplay = true }
    }

    override func mouseDown(with event: NSEvent) {
        pressed = index(event)
        hover = pressed
        needsDisplay = true
    }

    override func mouseDragged(with event: NSEvent) {
        let i = index(event)
        if i != hover { hover = i; needsDisplay = true }
    }

    override func mouseUp(with event: NSEvent) {
        let hit = index(event)
        let was = pressed
        pressed = nil
        needsDisplay = true
        if let hit, hit == was { onCommand?(commands[hit].1) }
    }
}

// MARK: - Icon view

/// The two groups of tiles: a blue group title with a line after it, then the tiles row by row (a 48 pt icon, the
/// name under it on up to two lines). Click selects, double-click or Return opens Properties, right-click offers
/// Properties. Flipped (y grows downwards).
@MainActor
final class DeviceTilesView: NSView {
    var onSelect: ((DeviceTile?) -> Void)?
    var onOpen: ((DeviceTile) -> Void)?
    static let tileSize = NSSize(width: 104, height: 92)
    static let margin: CGFloat = 16
    static let groupHeight: CGFloat = 28
    private var model = DevicesAndPrinters(devices: [], printers: [])
    private var groups: [(title: String, top: CGFloat)] = []
    private var columns = 1
    private var frames: [(tile: DeviceTile, rect: NSRect)] = []
    private var selected: Int?
    private var hover: Int?
    private(set) var contentHeight: CGFloat = 0
    private var laidOutWidth: CGFloat = -1
    private static let font = W7UIFont(12)
    private static let groupColor = NSColor(srgbRed: 0x1E / 255, green: 0x32 / 255, blue: 0x87 / 255, alpha: 1)
    private static let groupLine = NSColor(srgbRed: 0xC8 / 255, green: 0xD8 / 255, blue: 0xEC / 255, alpha: 1)

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override init(frame: NSRect) {
        super.init(frame: frame)
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseMoved, .mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                       owner: self, userInfo: nil))
    }
    required init?(coder: NSCoder) { fatalError() }

    func show(_ model: DevicesAndPrinters) {
        self.model = model
        selected = nil
        hover = nil
        laidOutWidth = -1
        onSelect?(nil)
    }

    /// Lays the groups out for `width` (Windows 7 fills each group's rows left to right).
    func layoutTiles(width: CGFloat) {
        guard width != laidOutWidth else { return }
        laidOutWidth = width
        let t = Self.tileSize, m = Self.margin
        columns = max(1, Int((width - 2 * m) / t.width))
        var y: CGFloat = 8
        groups = []
        frames = []
        for (title, list) in [(DevicesAndPrinters.devicesTitle(model.devices.count), model.devices),
                              (DevicesAndPrinters.printersTitle(model.printers.count), model.printers)] {
            groups.append((title, y))
            y += Self.groupHeight
            for (i, tile) in list.enumerated() {
                frames.append((tile, NSRect(x: m + CGFloat(i % columns) * t.width, y: y + CGFloat(i / columns) * t.height,
                                            width: t.width - 4, height: t.height - 4)))
            }
            y += CGFloat((list.count + columns - 1) / columns) * t.height + 8
        }
        contentHeight = y
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        NSColor.white.setFill()
        bounds.fill()
        for g in groups {
            let size = (g.title as NSString).size(withAttributes: [.font: Self.font])
            (g.title as NSString).draw(at: NSPoint(x: Self.margin, y: g.top + 4),
                                       withAttributes: [.font: Self.font, .foregroundColor: Self.groupColor])
            Self.groupLine.setFill()
            let lineX = Self.margin + ceil(size.width) + 8
            NSRect(x: lineX, y: g.top + 4 + floor(size.height / 2), width: max(0, bounds.width - lineX - Self.margin), height: 1).fill()
        }
        let style = NSMutableParagraphStyle()
        style.alignment = .center
        style.lineBreakMode = .byWordWrapping
        for (i, f) in frames.enumerated() where f.rect.intersects(dirtyRect) {
            if i == selected || i == hover {
                // Win7Theme draws in a non-flipped context.
                ctx.saveGState()
                ctx.translateBy(x: 0, y: f.rect.minY + f.rect.maxY)
                ctx.scaleBy(x: 1, y: -1)
                W7DrawNavPaneRow(ctx, f.rect, i == selected, i == hover)
                ctx.restoreGState()
            }
            DeviceIcons.image(f.tile.kind, side: 48)
                .draw(in: NSRect(x: f.rect.midX - 24, y: f.rect.minY + 4, width: 48, height: 48), from: .zero,
                      operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
            let textRect = NSRect(x: f.rect.minX + 3, y: f.rect.minY + 56, width: f.rect.width - 6, height: f.rect.height - 58)
            (f.tile.name as NSString).draw(with: textRect, options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine],
                                           attributes: [.font: Self.font, .foregroundColor: NSColor.black, .paragraphStyle: style])
        }
    }

    private func index(at event: NSEvent) -> Int? {
        let p = convert(event.locationInWindow, from: nil)
        return frames.firstIndex { $0.rect.contains(p) }
    }

    private func select(_ i: Int?) {
        guard i != selected else { return }
        selected = i
        needsDisplay = true
        if let i { scrollToVisible(frames[i].rect.insetBy(dx: 0, dy: -8)) }
        onSelect?(i.map { frames[$0].tile })
    }

    override func mouseMoved(with event: NSEvent) {
        let i = index(at: event)
        if i != hover { hover = i; needsDisplay = true }
    }

    override func mouseExited(with event: NSEvent) {
        if hover != nil { hover = nil; needsDisplay = true }
    }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        let i = index(at: event)
        select(i)
        if event.clickCount == 2, let i { onOpen?(frames[i].tile) }
    }

    override func rightMouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        guard let i = index(at: event) else { select(nil); return }
        select(i)
        let tile = frames[i].tile
        let menu = NSMenu()
        menu.autoenablesItems = false
        menu.addItem(MenuAction.item("Properties") { [weak self] in self?.onOpen?(tile) })
        ShellMenus.show(menu, at: NSEvent.mouseLocation)
    }

    /// Left and Right move the selection one tile, Up and Down one row (DevicesAndPrinters.step), scrolling it
    /// into view; Return opens Properties.
    override func keyDown(with event: NSEvent) {
        let direction: TileStep
        switch Int(event.keyCode) {
        case kVK_Return, kVK_ANSI_KeypadEnter:
            if let s = selected { onOpen?(frames[s].tile) }
            return
        case kVK_RightArrow: direction = .right
        case kVK_LeftArrow: direction = .left
        case kVK_DownArrow: direction = .down
        case kVK_UpArrow: direction = .up
        default:
            super.keyDown(with: event)
            return
        }
        let counts = [model.devices.count, model.printers.count]
        if let i = DevicesAndPrinters.step(from: selected, direction, groupCounts: counts, columns: columns), i < frames.count {
            select(i)
        }
    }
}

/// Explorer's details pane along the bottom: the selected device's icon, name and category, else the item count.
@MainActor
final class DeviceDetailsPane: NSView {
    static let height: CGFloat = 60
    private var tile: DeviceTile?
    private var count = 0
    private static let font = W7UIFont(12)
    private static let grey = NSColor(srgbRed: 0x5A / 255, green: 0x67 / 255, blue: 0x79 / 255, alpha: 1)

    func show(_ tile: DeviceTile?, count: Int) {
        self.tile = tile
        self.count = count
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        W7DrawDetailsPane(ctx, bounds)
        guard let tile else {
            let t = (count == 1 ? "1 item" : "\(count) items") as NSString
            t.draw(at: NSPoint(x: 16, y: bounds.midY - 8), withAttributes: [.font: Self.font, .foregroundColor: Self.grey])
            return
        }
        DeviceIcons.image(tile.kind, side: 48).draw(in: NSRect(x: 12, y: bounds.midY - 24, width: 48, height: 48))
        (tile.name as NSString).draw(at: NSPoint(x: 72, y: bounds.midY + 2),
                                     withAttributes: [.font: Self.font, .foregroundColor: NSColor.black])
        ("Category: " + tile.kind.title as NSString).draw(at: NSPoint(x: 72, y: bounds.midY - 16),
                                                           withAttributes: [.font: Self.font, .foregroundColor: Self.grey])
    }
}

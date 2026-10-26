import AppKit
import Carbon.HIToolbox
import Win7Core
import Win7Theme

/// Windows 7's Desktop Background page: "Choose your desktop background", the Picture location
/// list with Browse..., the picture grid (a check box per picture, Select all / Clear all), Picture position,
/// "Change picture every" with Shuffle, and Save changes / Cancel. A clicked picture shows on the desktop at once
/// (as in Windows 7); Cancel, Back or closing the window puts back what the screens showed before the first preview
/// (per display, WallpaperController.cancelPreview). every control is reachable with Tab, the grid with the
/// arrows and Space; Return, Esc and Cmd+A belong to the search box while it is typed in (Return there searches).
@MainActor
final class DesktopBackgroundWindow: ShellWindow {
    static let shared = DesktopBackgroundWindow()
    static let defaultSize = NSSize(width: 780, height: 600)
    static let personalizationCrumb = ControlPanelLocation.info(title: "Personalization", text: "", category: .appearance)
    private static let selfCrumb = ControlPanelLocation.info(title: "Desktop Background", text: "", category: .appearance)

    private let header = ControlPanelHeaderView()
    private let body = ShellLayoutView()
    private let heading = ShellLabel("Choose your desktop background", font: W7UIFont(15), color: ControlPanelText.navy)
    private let subheading = ShellLabel("Click a picture to make it your desktop background, or select more than one picture to create a slide show.")
    private let locationLabel = ShellLabel("Picture location:")
    private let locationPopUp = ShellPopUpButton()
    private let browse = ShellPushButton("Browse...")
    private let selectAll = ShellLink("Select all")
    private let clearAll = ShellLink("Clear all")
    private let scroll = NSScrollView()
    private let grid = WallpaperGridView()
    private let positionLabel = ShellLabel("Picture position:")
    private let positionPopUp = ShellPopUpButton()
    private let intervalLabel = ShellLabel("Change picture every:")
    private let intervalPopUp = ShellPopUpButton()
    private let shuffle = ShellCheckBox("Shuffle")
    private let save = ShellPushButton("Save changes", isDefault: true)
    private let cancel = ShellPushButton("Cancel")

    private var locations: [WallpaperLocation] = []
    private var locationIndex = 0
    private var selection = WallpaperSelection(items: [], checked: [])
    private var position: WallpaperPosition = .fill
    private var interval: SlideshowInterval = .minutes30
    private var saved = false
    private var closingHandled = false

    private init() {
        super.init(spec: Spec(identifier: ShellWindowTarget.desktopBackground.identifier,
                              title: ShellWindowTarget.desktopBackground.title, frameName: "Win7DesktopBackground",
                              defaultSize: Self.defaultSize, minSize: NSSize(width: 620, height: 480),
                              icon: { PersonalizationIcons.window(side: $0) }, logName: "desktop background"))
        buildContent()
        finishSetup()
        NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: self, queue: .main) { _ in
            MainActor.assumeIsolated { DesktopBackgroundWindow.shared.windowClosing() }
        }
    }

    private func buildContent() {
        let size = Self.defaultSize
        let content = NSView(frame: NSRect(origin: .zero, size: size))
        let h = ControlPanelLayout.headerHeight
        header.frame = NSRect(x: 0, y: size.height - h, width: size.width, height: h)
        header.autoresizingMask = [.width, .minYMargin]
        header.addressIcon = { PersonalizationIcons.window(side: $0) }
        header.update(crumbs: [ControlPanelCrumb("Control Panel", .home),
                               ControlPanelCrumb(ControlPanelCategory.appearance.title, .category(.appearance)),
                               ControlPanelCrumb("Personalization", Self.personalizationCrumb),
                               ControlPanelCrumb("Desktop Background", Self.selfCrumb)],
                      canGoBack: true, canGoForward: false)
        header.onBack = { [weak self] in self?.cancelAndClose(then: { ShellScreens.open(.personalization) }) }
        header.onCrumb = { [weak self] location in
            guard location != Self.selfCrumb else { return }
            if location == Self.personalizationCrumb { self?.cancelAndClose(then: { ShellScreens.open(.personalization) }); return }
            ControlPanelWindow.shared.show(location)
        }
        header.onSubmit = { text in ControlPanelWindow.shared.showSearch(text) }

        body.frame = NSRect(x: 0, y: 0, width: size.width, height: size.height - h)
        body.autoresizingMask = [.width, .height]
        body.wantsLayer = true
        body.layer?.backgroundColor = NSColor.white.cgColor
        body.onLayout = { [weak self] in self?.layoutBody() }

        locationPopUp.onSelect = { [weak self] i in self?.chooseLocation(i) }
        browse.action = { [weak self] in self?.browseForFolder() }
        selectAll.action = { [weak self] in self?.change { $0.selectAll() } }
        clearAll.action = { [weak self] in self?.change { $0.clearAll() } }
        positionPopUp.titles = WallpaperPosition.allCases.map(\.title)
        positionPopUp.onSelect = { [weak self] i in
            guard let self else { return }
            self.position = WallpaperPosition.allCases[i]
            self.previewFirst()
        }
        intervalPopUp.titles = SlideshowInterval.allCases.map(\.title)
        intervalPopUp.onSelect = { [weak self] i in self?.interval = SlideshowInterval.allCases[i] }
        save.action = { [weak self] in self?.saveChanges() }
        cancel.action = { [weak self] in self?.cancelAndClose(then: nil) }
        locationPopUp.accessibilityName = "Picture location"
        positionPopUp.accessibilityName = "Picture position"
        intervalPopUp.accessibilityName = "Change picture every"

        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.borderType = .lineBorder
        scroll.drawsBackground = true
        scroll.backgroundColor = .white
        scroll.documentView = grid
        scroll.contentView.postsFrameChangedNotifications = true
        NotificationCenter.default.addObserver(forName: NSView.frameDidChangeNotification, object: scroll.contentView, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.fitGrid() }
        }
        grid.onClick = { [weak self] item in self?.change { $0.click(item) } }
        grid.onToggle = { [weak self] item in self?.change { $0.toggle(item) } }

        subheading.wraps = true
        for v in [heading, subheading, locationLabel, locationPopUp, browse, selectAll, clearAll, scroll, positionLabel,
                  positionPopUp, intervalLabel, intervalPopUp, shuffle, save, cancel] as [NSView] {
            body.addSubview(v)
        }
        for v in [header, body] as [NSView] { content.addSubview(v) }
        contentView = content
        layoutBody()
    }

    override func keyStateChanged() { header.needsDisplay = true }

    /// Lays the page out top-down (the body view is not flipped: y is measured from its top).
    private func layoutBody() {
        let w = body.bounds.width, H = body.bounds.height, m: CGFloat = 28
        func place(_ v: NSView, x: CGFloat, top: CGFloat, width: CGFloat? = nil, height: CGFloat? = nil) {
            let hh = height ?? v.frame.height
            v.frame = NSRect(x: x, y: H - top - hh, width: width ?? v.frame.width, height: hh)
        }
        place(heading, x: m, top: 14, width: w - 2 * m, height: 24)
        place(subheading, x: m, top: 42, width: w - 2 * m, height: 18)
        place(locationLabel, x: m, top: 74, height: 22)
        place(locationPopUp, x: m + locationLabel.frame.width + 8, top: 74, width: 280, height: 22)
        place(browse, x: locationPopUp.frame.maxX + 10, top: 73)
        place(selectAll, x: m, top: 106)
        place(clearAll, x: m + selectAll.frame.width + 16, top: 106)
        let bottomBlock: CGFloat = 112
        place(scroll, x: m, top: 128, width: w - 2 * m, height: max(80, H - 128 - bottomBlock))
        let rowTop = H - bottomBlock + 14
        place(positionLabel, x: m, top: rowTop, height: 18)
        place(positionPopUp, x: m, top: rowTop + 22, width: 150, height: 22)
        let ix = m + 200
        place(intervalLabel, x: ix, top: rowTop, height: 18)
        place(intervalPopUp, x: ix, top: rowTop + 22, width: 150, height: 22)
        place(shuffle, x: ix + 166, top: rowTop + 24)
        place(cancel, x: w - m - cancel.frame.width, top: H - 16 - 23)
        place(save, x: cancel.frame.minX - 8 - save.frame.width, top: H - 16 - 23)
        fitGrid()
    }

    private func fitGrid() {
        let size = scroll.contentSize
        grid.layoutCells(width: size.width)
        let target = NSSize(width: size.width, height: max(grid.contentHeight, size.height))
        if grid.frame.size != target { grid.setFrameSize(target) }
    }

    // MARK: Showing

    /// Opens the page on the current choice: its location, its checked pictures (or the picture the desktop shows),
    /// its position and timing.
    func show() {
        if !isVisible && !isMiniaturized { reload() }
        present("desktop background")
        makeFirstResponder(grid)
    }

    private func reload() {
        let controller = WallpaperController.shared
        let current = controller.settings
        locations = controller.locations()
        if current?.location == .folder, let folder = current?.folder {
            locations.append(WallpaperCatalog.folderLocation(folder))
        }
        saved = false
        setShowsFocusCues(false)
        closingHandled = false
        position = current?.position ?? .fill
        interval = current?.interval ?? .minutes30
        shuffle.isOn = current?.shuffle ?? false
        var checked = current?.items ?? []
        let kind = current?.location ?? .windowsBackgrounds
        locationIndex = locations.firstIndex { $0.kind == kind } ?? 0
        if checked.isEmpty, let screen = NSScreen.main ?? NSScreen.screens.first,
           let shown = NSWorkspace.shared.desktopImageURL(for: screen) {
            // Nothing chosen here yet: the picture the desktop shows, where a location has it.
            let item = WallpaperItem.picture(shown)
            if let i = locations.firstIndex(where: { $0.items.contains(item) }) { locationIndex = i; checked = [item] }
        }
        positionPopUp.selectedIndex = WallpaperPosition.allCases.firstIndex(of: position) ?? 0
        intervalPopUp.selectedIndex = SlideshowInterval.allCases.firstIndex(of: interval) ?? 0
        showLocation(checked: checked)
        ShellWindowButtons.log.info("desktop background: \(self.locations.map { $0.items.count }, privacy: .public) items per location")
    }

    private func showLocation(checked: [WallpaperItem]) {
        locationPopUp.titles = locations.map(\.title)
        locationPopUp.selectedIndex = locationIndex
        let location = locations.indices.contains(locationIndex) ? locations[locationIndex] : nil
        selection = WallpaperSelection(items: location?.items ?? [], checked: checked)
        grid.show(location, emptyText: emptyText(location?.kind))
        fitGrid()
        updateControls()
    }

    private func emptyText(_ kind: WallpaperLocationKind?) -> String {
        switch kind {
        case .windowsBackgrounds?:
            "No Windows 7 desktop backgrounds have been imported. Run make import-assets SRC=/path/to/Win7.iso in the win7mac folder."
        case .picturesLibrary?: "There are no pictures in your Pictures folder."
        default: "There are no pictures in this folder."
        }
    }

    private func chooseLocation(_ i: Int) {
        guard locations.indices.contains(i) else { return }
        locationIndex = i
        showLocation(checked: [])
    }

    /// Browse...: a folder of pictures becomes the location (listed after the others while the window is open).
    private func browseForFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.directoryURL = WallpaperController.picturesFolder
        panel.prompt = "OK"
        panel.message = "Browse for a folder of pictures"
        NSApp.activate()
        panel.beginSheetModal(for: self) { [weak self] response in
            MainActor.assumeIsolated {
                guard let self, response == .OK, let url = panel.url else { return }
                self.locations.removeAll { $0.kind == .folder }
                self.locations.append(WallpaperCatalog.folderLocation(url))
                self.locationIndex = self.locations.count - 1
                self.showLocation(checked: [])
            }
        }
    }

    // MARK: Selection

    private func change(_ body: (inout WallpaperSelection) -> Void) {
        body(&selection)
        grid.checked = Set(selection.checked)
        updateControls()
        previewFirst()
    }

    private func updateControls() {
        grid.checked = Set(selection.checked)
        grid.allowsMultiple = selection.allowsMultiple
        selectAll.isEnabled = selection.allowsMultiple
        clearAll.isEnabled = selection.allowsMultiple
        save.isEnabled = selection.canSave
        let slideshow = selection.isSlideshow
        intervalLabel.color = slideshow ? .black : ControlPanelText.grey
        intervalLabel.needsDisplay = true
        intervalPopUp.isEnabled = slideshow
        shuffle.isEnabled = slideshow
        let pictures = selection.allowsMultiple
        positionLabel.color = pictures ? .black : ControlPanelText.grey
        positionLabel.needsDisplay = true
        positionPopUp.isEnabled = pictures
    }

    /// The first checked picture on the desktop at once.
    private func previewFirst() {
        guard let first = selection.checked.first else { return }
        WallpaperController.shared.preview(first, position: position)
    }

    // MARK: Save, Cancel

    private func saveChanges() {
        guard selection.canSave, locations.indices.contains(locationIndex) else { return }
        let location = locations[locationIndex]
        WallpaperController.shared.apply(WallpaperSettings(location: location.kind, items: selection.checked, position: position,
                                                           interval: interval, shuffle: shuffle.isOn, themeName: nil,
                                                           folder: location.folder))
        saved = true
        closingHandled = true
        close()
    }

    private func cancelAndClose(then next: (() -> Void)?) {
        revertIfNeeded()
        close()
        next?()
    }

    private func revertIfNeeded() {
        guard !saved, !closingHandled else { return }
        closingHandled = true
        WallpaperController.shared.cancelPreview()
    }

    /// The close button and Alt+F4 are Cancel.
    private func windowClosing() { revertIfNeeded() }

    // MARK: Keyboard

    /// The Tab stops, in DesktopBackgroundModel.focusOrder.
    private var focusStops: [NSView] {
        DesktopBackgroundModel.focusOrder.map { control -> NSView in
            switch control {
            case .location: locationPopUp
            case .browse: browse
            case .selectAll: selectAll
            case .clearAll: clearAll
            case .pictures: grid
            case .position: positionPopUp
            case .interval: intervalPopUp
            case .shuffle: shuffle
            case .save: save
            case .cancel: cancel
            case .search: header.searchField
            }
        }
    }

    /// Return saves, Esc cancels, Cmd+A selects every picture, Tab moves the focus (DesktopBackgroundModel); the
    /// search box keeps its own Return, Esc and Cmd+A, and a focused control its Return.
    override func handleKey(_ event: NSEvent) -> Bool {
        guard let key = Self.shellKey(event) else { return super.handleKey(event) }
        let editing = firstResponder is NSTextView
        if [.space, .up, .down, .left, .right].contains(key), !editing { setShowsFocusCues(true) }
        switch DesktopBackgroundModel.windowAction(key, editingText: editing, controlHasFocus: firstResponder is ShellControl) {
        case .save?: saveChanges()
        case .cancel?: cancelAndClose(then: nil)
        case .selectAllPictures?: change { $0.selectAll() }
        case .focusNext?: cycleFocus(focusStops, backward: false)
        case .focusPrevious?: cycleFocus(focusStops, backward: true)
        case nil: return super.handleKey(event)
        }
        return true
    }
}

/// The picture grid: a group header ("Landscapes (6)") per theme, then its pictures (thumbnails only, the name as
/// a tooltip, as Windows 7 shows them), each with a check box that shows while the cell is hovered or checked;
/// checked cells carry Explorer's selection box. Flipped.
@MainActor
final class WallpaperGridView: NSView {
    var onClick: ((WallpaperItem) -> Void)?
    var onToggle: ((WallpaperItem) -> Void)?
    var checked: Set<WallpaperItem> = [] { didSet { needsDisplay = true } }
    var allowsMultiple = true { didSet { needsDisplay = true } }
    private(set) var contentHeight: CGFloat = 0

    private var groups: [WallpaperGroup] = []
    private var emptyText = ""
    private var headers: [(title: String, rect: NSRect)] = []
    private var cells: [(item: WallpaperItem, rect: NSRect)] = []
    private var hover: Int?
    /// The cell with the keyboard focus (arrows move it, Space checks it).
    private var focused: Int?

    static let cell = NSSize(width: 144, height: 94)
    static let thumb = NSSize(width: 128, height: 80)
    private static let headerHeight: CGFloat = 28
    private static let font = W7UIFont(12)

    override var isFlipped: Bool { true }

    override init(frame: NSRect) {
        super.init(frame: frame)
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseMoved, .mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                       owner: self, userInfo: nil))
    }
    required init?(coder: NSCoder) { fatalError() }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override var acceptsFirstResponder: Bool { true }
    override var canBecomeKeyView: Bool { true }

    func show(_ location: WallpaperLocation?, emptyText: String) {
        groups = location?.groups.filter { !$0.items.isEmpty } ?? []
        self.emptyText = emptyText
        hover = nil
        focused = nil
        layoutCells(width: bounds.width)
        scroll(.zero)
    }

    func layoutCells(width: CGFloat) {
        headers = []
        cells = []
        let pad: CGFloat = 10
        let columns = max(1, Int((width - 2 * pad) / Self.cell.width))
        var y: CGFloat = 6
        for g in groups {
            if !g.title.isEmpty {
                headers.append(("\(g.title) (\(g.items.count))", NSRect(x: pad, y: y, width: width - 2 * pad, height: Self.headerHeight)))
                y += Self.headerHeight
            }
            for (i, item) in g.items.enumerated() {
                let col = i % columns, row = i / columns
                cells.append((item, NSRect(x: pad + CGFloat(col) * Self.cell.width, y: y + CGFloat(row) * Self.cell.height,
                                           width: Self.cell.width, height: Self.cell.height)))
            }
            y += CGFloat((g.items.count + columns - 1) / columns) * Self.cell.height + 6
        }
        contentHeight = y + 6
        removeAllToolTips()
        for c in cells { if case .picture = c.item { addToolTip(thumbRect(c.rect), owner: c.item.name as NSString, userData: nil) } }
        needsDisplay = true
    }

    private func thumbRect(_ cell: NSRect) -> NSRect {
        NSRect(x: cell.midX - Self.thumb.width / 2, y: cell.minY + 8, width: Self.thumb.width, height: Self.thumb.height)
    }

    private func checkRect(_ cell: NSRect) -> NSRect {
        let t = thumbRect(cell)
        return NSRect(x: t.minX + 4, y: t.minY + 4, width: W7CheckBoxSize, height: W7CheckBoxSize)
    }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.white.setFill()
        dirtyRect.fill()
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        if cells.isEmpty {
            let attrs = ControlPanelText.attributes(Self.font, ControlPanelText.grey, wrap: true)
            (emptyText as NSString).draw(with: NSRect(x: 16, y: 16, width: max(100, bounds.width - 32), height: 60),
                                         options: [.usesLineFragmentOrigin], attributes: attrs)
            return
        }
        for h in headers where h.rect.intersects(dirtyRect) {
            // Windows 7's group header: navy text and a fading line to its right.
            let attrs: [NSAttributedString.Key: Any] = [.font: Self.font, .foregroundColor: ControlPanelText.navy]
            let size = (h.title as NSString).size(withAttributes: attrs)
            (h.title as NSString).draw(at: NSPoint(x: h.rect.minX + 4, y: h.rect.midY - size.height / 2), withAttributes: attrs)
            let lineX = h.rect.minX + 12 + size.width
            NSGradient(starting: NSColor(srgbRed: 0xC5 / 255, green: 0xD3 / 255, blue: 0xE6 / 255, alpha: 1),
                       ending: NSColor(white: 1, alpha: 0))?.draw(in: NSRect(x: lineX, y: floor(h.rect.midY), width: max(0, h.rect.maxX - lineX), height: 1), angle: 0)
        }
        for (i, c) in cells.enumerated() where c.rect.intersects(dirtyRect) {
            let isChecked = checked.contains(c.item), isHover = i == hover
            if isChecked || isHover { W7DrawNavPaneRow(ctx, c.rect.insetBy(dx: 2, dy: 2), isChecked, isHover) }
            WallpaperTileDrawing.draw(c.item, in: thumbRect(c.rect)) { [weak self] in self?.setNeedsDisplay(c.rect) }
            if i == focused, ShellFocusRing.shows(in: self) { ShellFocusRing.draw(c.rect.insetBy(dx: 2, dy: 2)) }
            if allowsMultiple && (isChecked || isHover) {
                let box = checkRect(c.rect)
                NSColor.white.setFill()
                box.insetBy(dx: -1, dy: -1).fill()
                ctx.saveGState()
                // W7DrawCheckBox draws non-flipped: flip around the box.
                ctx.translateBy(x: 0, y: box.minY * 2 + box.height)
                ctx.scaleBy(x: 1, y: -1)
                W7DrawCheckBox(ctx, box, .normal, isChecked ? .on : .off)
                ctx.restoreGState()
            }
        }
    }

    private func index(at event: NSEvent) -> Int? {
        let p = convert(event.locationInWindow, from: nil)
        return cells.indices.first { cells[$0].rect.contains(p) }
    }

    override func mouseMoved(with event: NSEvent) {
        let h = index(at: event)
        guard h != hover else { return }
        for r in [hover, h].compactMap({ $0 }) where cells.indices.contains(r) { setNeedsDisplay(cells[r].rect) }
        hover = h
    }

    override func mouseExited(with event: NSEvent) {
        if let h = hover, cells.indices.contains(h) { setNeedsDisplay(cells[h].rect) }
        hover = nil
    }

    // MARK: Keyboard and accessibility

    override func becomeFirstResponder() -> Bool {
        if focused == nil, !cells.isEmpty { focused = cells.firstIndex { checked.contains($0.item) } ?? 0 }
        if let f = focused, cells.indices.contains(f) { setNeedsDisplay(cells[f].rect) }
        return true
    }

    override func resignFirstResponder() -> Bool {
        if let f = focused, cells.indices.contains(f) { setNeedsDisplay(cells[f].rect) }
        return true
    }

    private func moveFocus(to i: Int) {
        guard cells.indices.contains(i) else { return }
        for r in [focused, i].compactMap({ $0 }) where cells.indices.contains(r) { setNeedsDisplay(cells[r].rect) }
        focused = i
        scrollToVisible(cells[i].rect)
    }

    /// The arrows move the focus (ShellKeyboard.moveInGrid); Space checks or unchecks the focused picture (a colour:
    /// chooses it). Return and Esc are the window's (save, cancel).
    override func keyDown(with event: NSEvent) {
        guard let key = ShellWindow.shellKey(event) else { super.keyDown(with: event); return }
        if let next = ShellKeyboard.moveInGrid(key, from: focused, centers: cells.map { NSPoint(x: $0.rect.midX, y: $0.rect.midY) }) {
            moveFocus(to: next)
        } else if key == .space, let f = focused, cells.indices.contains(f) {
            onToggle?(cells[f].item)
        } else {
            super.keyDown(with: event)
        }
    }

    override func isAccessibilityElement() -> Bool { true }
    override func accessibilityRole() -> NSAccessibility.Role? { .list }
    override func accessibilityLabel() -> String? { "Pictures" }
    override func accessibilityChildren() -> [Any]? {
        cells.map { c in
            let item = c.item
            let isOn = checked.contains(item)
            let label: String
            if case .color(let color) = item { label = "Solid color " + color.hexString } else { label = item.name }
            return ShellAccessibilityItem(parent: self, role: allowsMultiple ? .checkBox : .radioButton, label: label,
                                          value: NSNumber(value: isOn ? 1 : 0), frame: c.rect, selected: isOn) { [weak self] in
                self?.onToggle?(item)
            }
        }
    }

    /// A click on the check box (or a Command-click) adds or removes the picture; a click elsewhere chooses only it.
    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        guard let i = index(at: event) else { return }
        moveFocus(to: i)
        let p = convert(event.locationInWindow, from: nil)
        let item = cells[i].item
        if allowsMultiple && (checkRect(cells[i].rect).insetBy(dx: -3, dy: -3).contains(p) || event.modifierFlags.contains(.command)) {
            onToggle?(item)
        } else {
            onClick?(item)
        }
    }
}

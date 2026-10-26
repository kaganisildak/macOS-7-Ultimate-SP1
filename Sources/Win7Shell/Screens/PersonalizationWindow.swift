import AppKit
import Carbon.HIToolbox
import Win7Core
import Win7Theme

/// Windows 7's Personalization page: the task pane (Control Panel Home, Change desktop icons, Change
/// mouse pointers, Change your account picture; See also), "Change the visuals and sounds on your computer", the theme
/// list (My Themes, Aero Themes, Installed Themes: one tile per imported Windows 7 theme with its first picture;
/// clicking one sets its pictures as a slideshow) and the bottom row: Desktop Background, Window Color, Sounds,
/// Screen Saver. Tab moves between the task pane, the theme list, the bottom row and the search box
/// (PersonalizationModel.focusOrder); arrows move inside each, Space or Return acts; the search box searches on
/// Return, passing the text on to the Control Panel.
@MainActor
final class PersonalizationWindow: ShellWindow {
    static let shared = PersonalizationWindow()
    static let defaultSize = NSSize(width: 800, height: 580)

    private let header = ControlPanelHeaderView()
    private let taskPane = ShellTaskPane()
    private let right = ShellLayoutView()
    private let heading = ShellLabel(PersonalizationModel.heading, font: W7UIFont(15), color: ControlPanelText.navy)
    private let subheading = ShellLabel(PersonalizationModel.subheading)
    private let scroll = NSScrollView()
    private let list = PersonalizationThemeListView()
    private let bottomRow = PersonalizationBottomRowView()

    private init() {
        super.init(spec: Spec(identifier: ShellWindowTarget.personalization.identifier,
                              title: ShellWindowTarget.personalization.title, frameName: "Win7Personalization",
                              defaultSize: Self.defaultSize, minSize: NSSize(width: 620, height: 440),
                              icon: { PersonalizationIcons.window(side: $0) }, logName: "personalization"))
        buildContent()
        finishSetup()
        WallpaperController.shared.onChange.append { [weak self] in self?.refresh() }
    }

    private func buildContent() {
        let size = Self.defaultSize
        let content = NSView(frame: NSRect(origin: .zero, size: size))
        let h = ControlPanelLayout.headerHeight, pane = ControlPanelLayout.taskPaneWidth
        header.frame = NSRect(x: 0, y: size.height - h, width: size.width, height: h)
        header.autoresizingMask = [.width, .minYMargin]
        header.addressIcon = { PersonalizationIcons.window(side: $0) }
        header.update(crumbs: [ControlPanelCrumb("Control Panel", .home),
                               ControlPanelCrumb(ControlPanelCategory.appearance.title, .category(.appearance)),
                               ControlPanelCrumb("Personalization", DesktopBackgroundWindow.personalizationCrumb)],
                      canGoBack: true, canGoForward: false)
        header.onBack = { ControlPanelWindow.shared.show(.category(.appearance)) }
        header.onCrumb = { location in
            guard location != DesktopBackgroundWindow.personalizationCrumb else { return }
            ControlPanelWindow.shared.show(location)
        }
        header.onSubmit = { text in ControlPanelWindow.shared.showSearch(text) }
        taskPane.frame = NSRect(x: 0, y: 0, width: pane, height: size.height - h)
        taskPane.autoresizingMask = [.height]
        taskPane.home = .init(title: "Control Panel Home") { ControlPanelWindow.shared.show(.home) }
        taskPane.tasks = PersonalizationModel.tasks.map { link in .init(title: link.title) { Self.perform(link) } }
        taskPane.seeAlso = PersonalizationModel.seeAlso.map { link in .init(title: link.title) { Self.perform(link) } }

        right.frame = NSRect(x: pane, y: 0, width: size.width - pane, height: size.height - h)
        right.autoresizingMask = [.width, .height]
        right.wantsLayer = true
        right.layer?.backgroundColor = NSColor.white.cgColor
        right.onLayout = { [weak self] in self?.layoutRight() }
        subheading.wraps = true
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.borderType = .lineBorder
        scroll.drawsBackground = true
        scroll.backgroundColor = .white
        scroll.documentView = list
        scroll.contentView.postsFrameChangedNotifications = true
        NotificationCenter.default.addObserver(forName: NSView.frameDidChangeNotification, object: scroll.contentView, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.fitList() }
        }
        list.onTheme = { theme in WallpaperController.shared.applyTheme(theme) }
        bottomRow.onItem = { i in Self.bottomAction(i) }
        for v in [heading, subheading, scroll, bottomRow] as [NSView] { right.addSubview(v) }
        for v in [header, taskPane, right] as [NSView] { content.addSubview(v) }
        contentView = content
        layoutRight()
    }

    /// The page from the top: the heading, the line under it, the theme list (taking the height left) and the bottom
    /// row, which always shows.
    private func layoutRight() {
        let w = right.bounds.width, H = right.bounds.height, m: CGFloat = 26
        heading.frame = NSRect(x: m, y: H - 14 - 24, width: w - 2 * m, height: 24)
        let subH = ControlPanelText.height(PersonalizationModel.subheading, W7UIFont(12), width: w - 2 * m) + 2
        subheading.frame = NSRect(x: m, y: H - 42 - subH, width: w - 2 * m, height: subH)
        let rowH = PersonalizationBottomRowView.height
        bottomRow.frame = NSRect(x: m, y: 12, width: w - 2 * m, height: rowH)
        let listTop = 42 + subH + 10
        scroll.frame = NSRect(x: m, y: 12 + rowH + 12, width: w - 2 * m, height: max(120, H - listTop - rowH - 24))
        fitList()
    }

    override func keyStateChanged() { header.needsDisplay = true }

    /// Brings the page forward with the themes on disk now.
    func show() {
        if !isVisible { setShowsFocusCues(false) }
        refresh()
        present("personalization")
    }

    func refresh() {
        let c = WallpaperController.shared
        list.update(themes: c.themes(), settings: c.settings, current: c.currentItem)
        bottomRow.update(settings: c.settings, current: c.currentItem)
        fitList()
    }

    private func fitList() {
        let size = scroll.contentSize
        list.layoutTiles(width: size.width)
        let target = NSSize(width: size.width, height: max(list.contentHeight, size.height))
        if list.frame.size != target { list.setFrameSize(target) }
    }

    // MARK: Actions

    /// A task pane link: an info page in the Control Panel, or a System Settings pane.
    static func perform(_ link: ControlPanelLink) {
        switch link.action {
        case .win7mac(let text): ControlPanelWindow.shared.show(.info(title: link.title, text: text, category: .appearance))
        case .settingsPane(let id): if let url = URL(string: "x-apple.systempreferences:" + id) { NSWorkspace.shared.open(url) }
        case .shellWindow(let target): ShellScreens.open(target)
        case .url(let s): if let url = URL(string: s) { NSWorkspace.shared.open(url) }
        case .app(let path): LaunchFeedback.openApplication(at: URL(fileURLWithPath: path))
        case .finder(let path): NSWorkspace.shared.open(URL(fileURLWithPath: (path as NSString).expandingTildeInPath))
        }
    }

    /// Desktop Background, Window Color, Sounds, Screen Saver.
    static func bottomAction(_ i: Int) {
        typealias P = ControlPanelCatalog.Pane
        switch i {
        case 0: ShellScreens.open(.desktopBackground)
        case 1: perform(ControlPanelLink("Window Color", .win7mac(ControlPanelCatalog.windowColorInfo)))
        case 2: perform(ControlPanelLink("Sounds", .settingsPane(P.sound)))
        default: perform(ControlPanelLink("Screen Saver", .settingsPane(P.wallpaper)))
        }
    }

    // MARK: Keyboard

    /// The Tab stops, in PersonalizationModel.focusOrder.
    private var focusStops: [NSView] {
        PersonalizationModel.focusOrder.map { control -> NSView in
            switch control {
            case .tasks: taskPane
            case .themes: list
            case .bottomRow: bottomRow
            case .search: header.searchField
            }
        }
    }

    /// Cmd+F goes to the search box; Tab and Shift-Tab move the focus.
    override func handleKey(_ event: NSEvent) -> Bool {
        if Int(event.keyCode) == kVK_ANSI_F && Self.flags(event) == .command { header.focusSearch(); return true }
        switch Self.shellKey(event) {
        case .tab?: cycleFocus(focusStops, backward: false); return true
        case .backTab?: cycleFocus(focusStops, backward: true); return true
        case .space?, .enter?, .up?, .down?, .left?, .right?:
            if !(firstResponder is NSTextView) { setShowsFocusCues(true) }
        default: break
        }
        return super.handleKey(event)
    }
}

/// The window and address-bar icon: the Control Panel item's (`cp-personalization.png`), else a drawn picture folder.
@MainActor
enum PersonalizationIcons {
    static func window(side: CGFloat) -> NSImage {
        ControlPanelIcons.image(names: ["cp-personalization", "cp-appearance"], glyph: .folder(.pictures), side: side)
    }
}

/// The theme list: My Themes, Aero Themes and Installed Themes, a tile per theme (its first picture with a small
/// Aero window on it, the name under it); the chosen theme carries Explorer's selection box. Flipped.
@MainActor
final class PersonalizationThemeListView: NSView {
    var onTheme: ((WallpaperTheme) -> Void)?
    private(set) var contentHeight: CGFloat = 0

    private var themes: [WallpaperTheme] = []
    private var settings: WallpaperSettings?
    private var current: WallpaperItem?
    private struct Tile { var title: String; var preview: WallpaperItem?; var theme: WallpaperTheme?; var selected: Bool; var rect: NSRect }
    private var sections: [(title: String, rect: NSRect)] = []
    private var tiles: [Tile] = []
    private var emptyNote: (String, NSRect)?
    private var hover: Int?
    /// The tile with the keyboard focus (arrows move it, Space or Return applies its theme).
    private var focused: Int?

    private static let font = W7UIFont(12)
    private static let tileSize = NSSize(width: 150, height: 118)
    private static let preview = NSSize(width: 128, height: 80)

    override var isFlipped: Bool { true }

    override init(frame: NSRect) {
        super.init(frame: frame)
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseMoved, .mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                       owner: self, userInfo: nil))
    }
    required init?(coder: NSCoder) { fatalError() }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    func update(themes: [WallpaperTheme], settings: WallpaperSettings?, current: WallpaperItem?) {
        self.themes = themes
        self.settings = settings
        self.current = current
        layoutTiles(width: bounds.width)
    }

    func layoutTiles(width: CGFloat) {
        sections = []
        tiles = []
        emptyNote = nil
        hover = nil
        let columns = max(1, Int((width - 16) / Self.tileSize.width))
        var y: CGFloat = 4
        func section(_ title: String, _ entries: [Tile]) {
            sections.append(("\(title) (\(entries.count))", NSRect(x: 10, y: y + 6, width: width - 20, height: 22)))
            y += 32
            for (i, var t) in entries.enumerated() {
                t.rect = NSRect(x: 8 + CGFloat(i % columns) * Self.tileSize.width, y: y + CGFloat(i / columns) * Self.tileSize.height,
                                width: Self.tileSize.width, height: Self.tileSize.height)
                tiles.append(t)
            }
            y += CGFloat((entries.count + columns - 1) / columns) * Self.tileSize.height + 4
        }
        func tile(_ t: WallpaperTheme) -> Tile {
            Tile(title: t.themeName, preview: t.pictures.first.map(WallpaperItem.picture), theme: t,
                 selected: settings?.themeName == t.themeName, rect: .zero)
        }
        if let mine = PersonalizationModel.myThemeName(settings) {
            section("My Themes", [Tile(title: mine, preview: current, theme: nil, selected: true, rect: .zero)])
        }
        let aero = PersonalizationModel.aeroThemes(themes)
        section("Aero Themes", aero.map(tile))
        if aero.isEmpty {
            let text = "No Windows 7 themes have been imported yet. In Terminal, in the win7mac folder, run make import-assets "
                + "SRC=/path/to/Win7.iso; the desktop backgrounds of your Windows 7 disc then appear here."
            let h = ControlPanelText.height(text, Self.font, width: max(100, width - 40))
            emptyNote = (text, NSRect(x: 20, y: y, width: max(100, width - 40), height: h))
            y += h + 12
        }
        let installed = PersonalizationModel.installedThemes(themes)
        if !installed.isEmpty { section("Installed Themes", installed.map(tile)) }
        contentHeight = y + 6
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.white.setFill()
        dirtyRect.fill()
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        for s in sections where s.rect.intersects(dirtyRect) {
            let attrs: [NSAttributedString.Key: Any] = [.font: Self.font, .foregroundColor: ControlPanelText.navy]
            let size = (s.title as NSString).size(withAttributes: attrs)
            (s.title as NSString).draw(at: NSPoint(x: s.rect.minX, y: s.rect.midY - size.height / 2), withAttributes: attrs)
            let lineX = s.rect.minX + size.width + 8
            NSGradient(starting: NSColor(srgbRed: 0xC5 / 255, green: 0xD3 / 255, blue: 0xE6 / 255, alpha: 1),
                       ending: NSColor(white: 1, alpha: 0))?.draw(in: NSRect(x: lineX, y: floor(s.rect.midY), width: max(0, s.rect.maxX - lineX), height: 1), angle: 0)
        }
        if let (text, rect) = emptyNote {
            (text as NSString).draw(with: rect, options: [.usesLineFragmentOrigin],
                                    attributes: ControlPanelText.attributes(Self.font, ControlPanelText.grey, wrap: true))
        }
        for (i, t) in tiles.enumerated() where t.rect.intersects(dirtyRect) {
            if t.selected || i == hover { W7DrawNavPaneRow(ctx, t.rect.insetBy(dx: 3, dy: 2), t.selected, i == hover) }
            let p = NSRect(x: t.rect.midX - Self.preview.width / 2, y: t.rect.minY + 8, width: Self.preview.width, height: Self.preview.height)
            WallpaperTileDrawing.draw(t.preview, in: p) { [weak self] in self?.setNeedsDisplay(t.rect) }
            Self.drawWindowMock(in: p)
            let style = NSMutableParagraphStyle()
            style.alignment = .center
            style.lineBreakMode = .byTruncatingTail
            (t.title as NSString).draw(in: NSRect(x: t.rect.minX + 4, y: p.maxY + 6, width: t.rect.width - 8, height: 16),
                                       withAttributes: [.font: Self.font, .foregroundColor: NSColor.black, .paragraphStyle: style])
            if i == focused, ShellFocusRing.shows(in: self) { ShellFocusRing.draw(t.rect.insetBy(dx: 3, dy: 2)) }
        }
    }

    /// A small Aero window in the preview's lower right, as Windows 7's theme tiles show the window colour.
    private static func drawWindowMock(in p: NSRect) {
        let w = NSRect(x: p.maxX - 54, y: p.maxY - 36, width: 46, height: 30)
        let frame = NSBezierPath(roundedRect: w, xRadius: 2, yRadius: 2)
        NSColor(srgbRed: 0x6C / 255, green: 0x91 / 255, blue: 0xC7 / 255, alpha: 0.92).setFill()
        frame.fill()
        NSColor.white.setFill()
        NSRect(x: w.minX + 3, y: w.minY + 7, width: w.width - 6, height: w.height - 10).fill()
        NSColor(srgbRed: 0x15 / 255, green: 0x1C / 255, blue: 0x27 / 255, alpha: 0.8).setStroke()
        frame.lineWidth = 1
        frame.stroke()
    }

    private func index(at event: NSEvent) -> Int? {
        let p = convert(event.locationInWindow, from: nil)
        return tiles.indices.first { tiles[$0].rect.contains(p) }
    }

    override func mouseMoved(with event: NSEvent) {
        let h = index(at: event)
        guard h != hover else { return }
        for r in [hover, h].compactMap({ $0 }) where tiles.indices.contains(r) { setNeedsDisplay(tiles[r].rect) }
        hover = h
    }

    override func mouseExited(with event: NSEvent) {
        if let h = hover, tiles.indices.contains(h) { setNeedsDisplay(tiles[h].rect) }
        hover = nil
    }

    /// A click on a theme sets its pictures (a slideshow, as Windows 7's theme does).
    override func mouseUp(with event: NSEvent) {
        guard let i = index(at: event), let theme = tiles[i].theme else { return }
        focused = i
        onTheme?(theme)
    }

    // MARK: Keyboard and accessibility

    override var acceptsFirstResponder: Bool { true }
    override var canBecomeKeyView: Bool { true }

    override func becomeFirstResponder() -> Bool {
        if focused == nil || !tiles.indices.contains(focused!) { focused = tiles.firstIndex(where: \.selected) ?? (tiles.isEmpty ? nil : 0) }
        needsDisplay = true
        return true
    }

    override func resignFirstResponder() -> Bool { needsDisplay = true; return true }

    /// The arrows move between the tiles (across the sections); Space or Return applies the focused theme.
    override func keyDown(with event: NSEvent) {
        guard let key = ShellWindow.shellKey(event) else { super.keyDown(with: event); return }
        let current = focused.flatMap { tiles.indices.contains($0) ? $0 : nil }
        if let next = ShellKeyboard.moveInGrid(key, from: current, centers: tiles.map { NSPoint(x: $0.rect.midX, y: $0.rect.midY) }) {
            focused = next
            scrollToVisible(tiles[next].rect)
            needsDisplay = true
        } else if key == .space || key == .enter, let i = current, let theme = tiles[i].theme {
            onTheme?(theme)
        } else {
            super.keyDown(with: event)
        }
    }

    override func isAccessibilityElement() -> Bool { true }
    override func accessibilityRole() -> NSAccessibility.Role? { .list }
    override func accessibilityLabel() -> String? { "Themes" }
    override func accessibilityChildren() -> [Any]? {
        tiles.map { t in
            let theme = t.theme
            return ShellAccessibilityItem(parent: self, role: .button, label: t.title, frame: t.rect, selected: t.selected) { [weak self] in
                if let theme { self?.onTheme?(theme) }
            }
        }
    }
}

/// The row under the theme list: Desktop Background (the current picture; "Harmony", "Slide Show" or its name),
/// Window Color ("Sky"), Sounds ("Windows Default"), Screen Saver ("None"). Flipped.
@MainActor
final class PersonalizationBottomRowView: NSView {
    static let height: CGFloat = 88
    var onItem: ((Int) -> Void)?
    private var captions = ["Harmony", "Sky", "Windows Default", "None"]
    private var current: WallpaperItem?
    private var hover: Int?
    /// The link with the keyboard focus (←/→ move it, Space or Return follows it).
    private var focused = 0
    private static let font = W7UIFont(12)

    override var isFlipped: Bool { true }

    override init(frame: NSRect) {
        super.init(frame: frame)
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseMoved, .mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                       owner: self, userInfo: nil))
    }
    required init?(coder: NSCoder) { fatalError() }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    func update(settings: WallpaperSettings?, current: WallpaperItem?) {
        captions[0] = PersonalizationModel.backgroundCaption(settings)
        self.current = current
        needsDisplay = true
    }

    private var cellWidth: CGFloat { min(150, bounds.width / 4) }
    private func cell(_ i: Int) -> NSRect { NSRect(x: CGFloat(i) * cellWidth, y: 0, width: cellWidth, height: bounds.height) }
    private func hot(_ i: Int) -> NSRect { cell(i).insetBy(dx: 10, dy: 0) }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        window?.invalidateCursorRects(for: self)
    }

    override func draw(_ dirtyRect: NSRect) {
        for (i, title) in PersonalizationModel.bottomTitles.enumerated() {
            let r = cell(i)
            let pic = NSRect(x: r.midX - 32, y: 4, width: 64, height: 42)
            switch i {
            case 0:
                WallpaperTileDrawing.draw(current, in: pic, maxPixels: 160) { [weak self] in self?.needsDisplay = true }
            case 1:
                let swatch = NSRect(x: pic.midX - 20, y: pic.minY + 1, width: 40, height: 40)
                let path = NSBezierPath(roundedRect: swatch, xRadius: 4, yRadius: 4)
                NSGradient(starting: NSColor(srgbRed: 0x9F / 255, green: 0xC0 / 255, blue: 0xE6 / 255, alpha: 1),
                           ending: NSColor(srgbRed: 0x6C / 255, green: 0x91 / 255, blue: 0xC7 / 255, alpha: 1))?.draw(in: path, angle: -90)
                NSColor(srgbRed: 0x2B / 255, green: 0x4E / 255, blue: 0x78 / 255, alpha: 1).setStroke()
                path.stroke()
            default:
                let icon = i == 2 ? ControlPanelIcons.image(names: ["cp-sound"], glyph: .tray(.volume, 4), side: 48)
                    : ControlPanelIcons.image(names: ["cp-display", "computer"], glyph: .nav(.computer), side: 48)
                icon.draw(in: NSRect(x: pic.midX - 21, y: pic.minY, width: 42, height: 42), from: .zero, operation: .sourceOver,
                          fraction: 1, respectFlipped: true, hints: nil)
            }
            let style = NSMutableParagraphStyle()
            style.alignment = .center
            style.lineBreakMode = .byTruncatingTail
            var link = ControlPanelText.attributes(Self.font, ControlPanelText.linkBlue, underline: i == hover)
            link[.paragraphStyle] = style
            (title as NSString).draw(in: NSRect(x: r.minX, y: pic.maxY + 6, width: r.width, height: 17), withAttributes: link)
            (captions[i] as NSString).draw(in: NSRect(x: r.minX, y: pic.maxY + 23, width: r.width, height: 17),
                                           withAttributes: [.font: Self.font, .foregroundColor: NSColor.black, .paragraphStyle: style])
            if i == focused, ShellFocusRing.shows(in: self) {
                let w = min(r.width, ControlPanelText.width(title, Self.font) + 6)
                ShellFocusRing.draw(NSRect(x: r.midX - w / 2, y: pic.maxY + 5, width: w, height: 19))
            }
        }
    }

    override func resetCursorRects() {
        for i in 0..<4 { addCursorRect(hot(i), cursor: .pointingHand) }
    }

    private func index(at event: NSEvent) -> Int? {
        let p = convert(event.locationInWindow, from: nil)
        return (0..<4).first { hot($0).contains(p) }
    }

    override func mouseMoved(with event: NSEvent) {
        let h = index(at: event)
        if h != hover { hover = h; needsDisplay = true }
    }

    override func mouseExited(with event: NSEvent) {
        if hover != nil { hover = nil; needsDisplay = true }
    }

    override func mouseUp(with event: NSEvent) {
        if let i = index(at: event) { focused = i; onItem?(i) }
    }

    // MARK: Keyboard and accessibility

    override var acceptsFirstResponder: Bool { true }
    override var canBecomeKeyView: Bool { true }
    override func becomeFirstResponder() -> Bool { needsDisplay = true; return true }
    override func resignFirstResponder() -> Bool { needsDisplay = true; return true }

    override func keyDown(with event: NSEvent) {
        guard let key = ShellWindow.shellKey(event) else { super.keyDown(with: event); return }
        let count = PersonalizationModel.bottomTitles.count
        if let next = ShellKeyboard.moveInList(key, from: focused, count: count, vertical: false) {
            focused = next
            needsDisplay = true
        } else if ShellKeyboard.action(key, for: .link) == .activate {
            onItem?(focused)
        } else {
            super.keyDown(with: event)
        }
    }

    override func isAccessibilityElement() -> Bool { true }
    override func accessibilityRole() -> NSAccessibility.Role? { .group }
    override func accessibilityLabel() -> String? { "Desktop Background, Window Color, Sounds and Screen Saver" }
    override func accessibilityChildren() -> [Any]? {
        PersonalizationModel.bottomTitles.enumerated().map { i, title in
            ShellAccessibilityItem(parent: self, role: .link, label: title, value: captions[i], frame: hot(i)) { [weak self] in
                self?.onItem?(i)
            }
        }
    }
}

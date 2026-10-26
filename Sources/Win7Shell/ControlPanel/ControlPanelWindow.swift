import AppKit
import Carbon.HIToolbox
import Win7ChromeCore
import Win7Core
import Win7Theme

/// A scroll view that reports when it re-tiles, so the body is laid out again for a new width.
private final class ControlPanelScrollView: NSScrollView {
    var onTile: (() -> Void)?
    override func tile() {
        super.tile()
        onTile?()
    }
}

/// The Windows 7 Control Panel: the shell's own window, drawn entirely here. Every item only opens
/// something: the real System Settings pane (untouched), a macOS app, a Finder folder, or the shell's own info
/// page (ControlPanelCatalog), or one of the shell's windows (Device Manager, Devices and Printers). Framed as a
/// ShellWindow (the Aero caption from Win7ChromeCore) and shown as a taskbar button (ShellWindowButtons,
/// identifier `win7.controlpanel`).
@MainActor
final class ControlPanelWindow: ShellWindow {
    static let shared = ControlPanelWindow()
    static let identifierString = "win7.controlpanel"
    static let viewModeKey = "controlPanelViewMode"
    static let frameName = "Win7ControlPanel"

    private let header = ControlPanelHeaderView()
    private let taskPane = ControlPanelTaskPane()
    private let scroll = ControlPanelScrollView()
    private let body = ControlPanelBodyView()
    private var history = ControlPanelHistory()
    private var viewMode: ControlPanelViewMode
    private var query = ""
    /// Checked once, the first time the window opens: what exists on this Mac.
    private var availability: [ControlPanelAction: Bool] = [:]
    private var items: [ControlPanelItem] = []
    private var itemsLoaded = false
    private var bodyWidth: CGFloat = -1
    private var fitting = false

    private init() {
        viewMode = ControlPanelViewMode(rawValue: UserDefaults.standard.string(forKey: Self.viewModeKey) ?? "") ?? .category
        let size = NSSize(width: 780, height: 560)
        super.init(spec: Spec(identifier: Self.identifierString, title: "Control Panel", frameName: Self.frameName,
                              defaultSize: size, minSize: NSSize(width: 560, height: 360),
                              icon: { ControlPanelIcons.window(side: $0) }, logName: "control panel"))
        buildContent(size)
        finishSetup()
    }

    private func buildContent(_ size: NSSize) {
        let root = NSView(frame: NSRect(origin: .zero, size: size))
        let h = ControlPanelLayout.headerHeight, pane = ControlPanelLayout.taskPaneWidth
        header.frame = NSRect(x: 0, y: size.height - h, width: size.width, height: h)
        header.autoresizingMask = [.width, .minYMargin]
        taskPane.frame = NSRect(x: 0, y: 0, width: pane, height: size.height - h)
        taskPane.autoresizingMask = [.height]
        scroll.frame = NSRect(x: pane, y: 0, width: size.width - pane, height: size.height - h)
        scroll.autoresizingMask = [.width, .height]
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.borderType = .noBorder
        scroll.drawsBackground = true
        scroll.backgroundColor = .white
        scroll.documentView = body
        for v in [header, taskPane, scroll] as [NSView] { root.addSubview(v) }
        contentView = root

        header.onBack = { [weak self] in self?.goBack() }
        header.onForward = { [weak self] in self?.goForward() }
        header.onCrumb = { [weak self] location in self?.handle(.navigate(location)) }
        header.onSearch = { [weak self] text in self?.searchChanged(text) }
        taskPane.onTarget = { [weak self] target in self?.handle(target) }
        body.onTarget = { [weak self] target in self?.handle(target) }
        body.onViewMode = { [weak self] mode in self?.setViewMode(mode) }
        scroll.onTile = { [weak self] in self?.fitBody() }
    }

    /// Key changes redraw the address row's glass too (ShellWindow redraws the caption).
    override func keyStateChanged() { header.needsDisplay = true }

    // MARK: Showing

    /// Finder's Computer view asks for the Control Panel with a distributed notification
    /// (W7ControlPanelShowNotificationName, no userInfo): it opens at home, as from the Start menu. Called once at launch.
    static func listenForShowRequests() {
        DistributedNotificationCenter.default().addObserver(
            forName: Notification.Name(W7ControlPanelShowNotificationName), object: nil, queue: .main) { _ in
            MainActor.assumeIsolated {
                ShellWindowButtons.log.info("control panel: requested by Explorer's Computer view")
                NSApp.activate()
                ControlPanelWindow.shared.show()
            }
        }
    }

    /// Opens the window at `location` (the Start menu: home; a Personalization or Device Manager crumb: its
    /// category) and brings it forward.
    func show(_ location: ControlPanelLocation = .home) {
        loadItemsIfNeeded()
        if !query.isEmpty { clearSearch() }
        history.navigate(to: location)
        refresh()
        present(String(describing: location))
    }

    /// Opens the window showing the search results for `text` (a search typed in Personalization or Desktop
    /// Background), with the text in its own search box.
    func showSearch(_ text: String) {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { show(); return }
        loadItemsIfNeeded()
        header.setSearchText(text)
        searchChanged(text)
        present("search")
        header.focusSearch()
    }

    /// Does what the catalogue item `id` does when its title is clicked (the Start menu's Default Programs, Help
    /// links): its info page opens this window, anything else opens its pane, app, folder or shell window. False when
    /// no item has that id or it can't open on this Mac.
    @discardableResult func openItem(_ id: String) -> Bool {
        loadItemsIfNeeded()
        guard let item = items.first(where: { $0.id == id }) else {
            ShellWindowButtons.log.error("control panel: no item \(id, privacy: .public) to open")
            return false
        }
        if case .win7mac(let text) = item.action {
            show(.info(title: item.title, text: text, category: item.categories.first))
        } else {
            perform(ControlPanelLink(item.title, item.action))
        }
        return true
    }

    private func loadItemsIfNeeded() {
        guard !itemsLoaded else { return }
        itemsLoaded = true
        items = ControlPanelAvailability.filter(ControlPanelCatalog.items) { self.isAvailable($0) }
    }

    /// Whether `action`'s target exists, checked once per target (Bundle for panes, FileManager otherwise).
    private func isAvailable(_ action: ControlPanelAction) -> Bool {
        if let known = availability[action] { return known }
        let ok = ControlPanelAvailability.isAvailable(action, fileExists: { FileManager.default.fileExists(atPath: $0) },
                                                      bundleID: { Bundle(path: $0)?.bundleIdentifier })
        availability[action] = ok
        return ok
    }

    // MARK: Navigation

    private func navigate(to location: ControlPanelLocation) {
        if !query.isEmpty { clearSearch() }
        guard history.navigate(to: location) else { refresh(); return }
        SoundPlayer.play(.navigation)
        refresh()
    }

    private func goBack() {
        if !query.isEmpty { clearSearch(); refresh(); return }
        if history.goBack() { SoundPlayer.play(.navigation); refresh() }
    }

    private func goForward() {
        if history.goForward() { SoundPlayer.play(.navigation); refresh() }
    }

    private func handle(_ target: ControlPanelTarget) {
        switch target {
        case .navigate(let location): navigate(to: location)
        case .perform(let link): perform(link)
        }
    }

    private var currentCategory: ControlPanelCategory? {
        switch history.current {
        case .category(let c): c
        case .info(_, _, let c): c
        case .home: nil
        }
    }

    /// Opens the link's target. Nothing here changes a setting: panes, apps and folders are only opened.
    private func perform(_ link: ControlPanelLink) {
        let ws = NSWorkspace.shared
        switch link.action {
        case .settingsPane(let id):
            if let url = URL(string: "x-apple.systempreferences:" + id) { ws.open(url) }
        case .app(let path):
            LaunchFeedback.openApplication(at: URL(fileURLWithPath: path))
        case .finder(let path):
            ws.open(URL(fileURLWithPath: (path as NSString).expandingTildeInPath))
        case .url(let string):
            if let url = URL(string: string) { ws.open(url) }
        case .win7mac(let text):
            navigate(to: .info(title: link.title, text: text, category: query.isEmpty ? currentCategory : nil))
        case .shellWindow(let target):
            ShellScreens.open(target)
        }
    }

    private func setViewMode(_ mode: ControlPanelViewMode) {
        viewMode = mode
        UserDefaults.standard.set(mode.rawValue, forKey: Self.viewModeKey)
        if history.current != .home { navigate(to: .home) } else { refresh() }
    }

    private func searchChanged(_ text: String) {
        query = text.trimmingCharacters(in: .whitespacesAndNewlines)
        refresh()
    }

    private func clearSearch() {
        header.clearSearch()
        query = ""
    }

    // MARK: Content

    private func refresh() {
        let searching = !query.isEmpty
        header.update(crumbs: ControlPanelHistory.breadcrumbs(history.current, viewMode: viewMode, searching: searching),
                      canGoBack: history.canGoBack || searching, canGoForward: history.canGoForward)
        taskPane.update(current: history.current, categories: ControlPanelCategory.allCases)
        body.show(page(), viewMode: viewMode, width: scroll.contentSize.width)
        bodyWidth = scroll.contentSize.width
        fitBody()
        body.scroll(.zero)
    }

    private func page() -> ControlPanelBodyPage {
        if !query.isEmpty {
            let results = ControlPanelSearch.search(query, in: items)
            return results.isEmpty ? .message("No items match your search.") : .items(results)
        }
        switch history.current {
        case .home:
            if viewMode != .category { return .icons(ControlPanelCatalog.allItemsSorted(items), viewMode) }
            return .categories(ControlPanelCategory.allCases.map { c in
                (c, ControlPanelCatalog.homeLinks(c).filter { isAvailable($0.action) })
            })
        case .category(let c):
            return .items(ControlPanelCatalog.items(in: c, from: items))
        case .info(let title, let text, _):
            return .info(title: title, text: text)
        }
    }

    /// Sizes the body to the clip view (at least its height); a new width lays it out again.
    private func fitBody() {
        guard !fitting else { return }   // resizing the body can re-tile the scroll view
        fitting = true
        defer { fitting = false }
        let size = scroll.contentSize
        if size.width != bodyWidth {
            bodyWidth = size.width
            body.rebuild(width: size.width)
        }
        let target = NSSize(width: size.width, height: max(body.contentHeight, size.height))
        if body.frame.size != target { body.setFrameSize(target) }
    }

    // MARK: Keyboard

    /// Esc (clears a search first) closes the window, as Alt+F4 and Cmd+W do (ShellWindow); Alt+←/→ go back and
    /// forward; Cmd+F goes to the search box.
    override func handleKey(_ event: NSEvent) -> Bool {
        let flags = Self.flags(event)
        let editing = firstResponder is NSTextView
        switch Int(event.keyCode) {
        case kVK_Escape where flags.isEmpty:
            if !query.isEmpty { clearSearch(); refresh() } else { performClose(nil) }
            return true
        case kVK_ANSI_F where flags == .command:
            header.focusSearch()
            return true
        case kVK_LeftArrow where flags == .option && !editing:
            goBack()
            return true
        case kVK_RightArrow where flags == .option && !editing:
            goForward()
            return true
        default:
            return super.handleKey(event)
        }
    }
}

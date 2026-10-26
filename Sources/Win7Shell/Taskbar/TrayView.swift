import AppKit
import Win7ChromeCore
import Win7Core
import Win7Theme

/// The Windows 7 notification area, left to right: chevron, language, Action Center flag, network,
/// volume, battery (only with an internal battery) and the two-line clock. Each item opens its
/// flyout; the language item opens a menu of the enabled input sources. A right-click on the flag,
/// network, volume, battery or clock opens its Windows 7 context menu. The Show Desktop strip to its
/// right belongs to TaskbarView.
@MainActor
final class TrayView: NSView {
    enum Item: String, CaseIterable {
        case chevron, language, actionCenter, network, volume, battery, clock

        /// The item's right-click menu, if it has one.
        var menuIcon: TrayMenuIcon? {
            switch self {
            case .chevron, .language: nil
            case .actionCenter: .actionCenter
            case .network: .network
            case .volume: .volume
            case .battery: .battery
            case .clock: .clock
            }
        }
    }

    private static let font = W7UIFont(12)  // W7UIFont scans the disk, so cache it
    private static let languageFont = W7UIFont(11)
    private static let iconSize: CGFloat = 16

    /// Called when `preferredWidth` changes (battery appears, the clock or language text widens).
    var onWidthChange: (() -> Void)?
    private(set) var preferredWidth: CGFloat = 0

    private let network = NetworkStatus()
    private let volume = VolumeControl()
    private let battery: BatteryStatus
    private let actionCenter: ActionCenterStatus
    private let input = InputSourceStatus()

    private var lines = (time: "", date: "")
    private var timer: Timer?
    private var rects: [(item: Item, rect: NSRect)] = []
    private var hover: Item?
    private var pressed: Item?
    /// The item whose flyout is open; drawn pressed.
    private var openItem: Item?
    private var lastClosed: (item: Item, time: TimeInterval)?
    private weak var volumeFlyout: VolumeFlyout?
    private weak var networkFlyout: NetworkFlyout?
    private weak var batteryFlyout: BatteryFlyout?
    private weak var actionCenterFlyout: ActionCenterFlyout?
    private var menuEntries: [TrayMenuEntry] = []
    private var scrollAccumulator: CGFloat = 0
    /// Observer tokens for the clock's time zone, locale and clock notifications. Only touched on the
    /// main thread and in deinit.
    nonisolated(unsafe) private var clockObservers: [NSObjectProtocol] = []
    private var menuSources: [InputSourceStatus.Source] = []

    override init(frame: NSRect) {
        let battery = BatteryStatus()
        self.battery = battery
        actionCenter = ActionCenterStatus(battery: battery)
        super.init(frame: frame)
        network.onChange = { [weak self] in self?.networkFlyout?.sync(); self?.statusChanged() }
        volume.onChange = { [weak self] in self?.volumeFlyout?.sync(); self?.statusChanged() }
        battery.onChange = { [weak self] in
            self?.batteryFlyout?.sync()
            self?.actionCenter.refresh()
            self?.statusChanged()
        }
        actionCenter.onChange = { [weak self] in self?.actionCenterFlyout?.sync(); self?.statusChanged() }
        input.onChange = { [weak self] in self?.statusChanged() }
        // The clock follows time zone, locale and clock changes at once, not only at the next minute.
        // The handlers run on the main queue (whatever thread posts), so they are on the main actor.
        let center = NotificationCenter.default
        for name in [Notification.Name.NSSystemTimeZoneDidChange, NSLocale.currentLocaleDidChangeNotification,
                     .NSSystemClockDidChange] {
            clockObservers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.clockSettingsChanged() }
            })
        }
        updateClock()
    }
    required init?(coder: NSCoder) { fatalError() }

    deinit {
        for token in clockObservers { NotificationCenter.default.removeObserver(token) }
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        timer?.invalidate()
        if window != nil { updateClock() }
    }

    // MARK: Layout

    private static func width(of item: Item, clockWidth: CGFloat) -> CGFloat {
        switch item {
        case .chevron: 18
        case .language: 28
        case .actionCenter, .network, .volume, .battery: 24
        case .clock: clockWidth
        }
    }

    private var visibleItems: [Item] {
        Item.allCases.filter { $0 != .battery || battery.isPresent }
    }

    private var clockWidth: CGFloat {
        let attrs: [NSAttributedString.Key: Any] = [.font: TrayView.font]
        let w = max((lines.time as NSString).size(withAttributes: attrs).width,
                    (lines.date as NSString).size(withAttributes: attrs).width)
        return max(ceil(w) + 12, 70)
    }

    private func relayout() {
        let clock = clockWidth
        var x: CGFloat = 0
        rects = visibleItems.map { item in
            let w = TrayView.width(of: item, clockWidth: clock)
            defer { x += w }
            return (item, NSRect(x: x, y: 0, width: w, height: W7TaskbarHeight))
        }
        removeAllToolTips()
        for (_, r) in rects { addToolTip(r, owner: self, userData: nil) }
        if x != preferredWidth {
            preferredWidth = x
            onWidthChange?()
        }
        needsDisplay = true
    }

    private func statusChanged() { relayout() }

    private func item(at p: NSPoint) -> Item? { rects.first { $0.rect.contains(p) }?.item }
    private func rect(of item: Item) -> NSRect? { rects.first { $0.item == item }?.rect }

    private func screenRect(of item: Item) -> NSRect {
        let r = convert(rect(of: item) ?? bounds, to: nil)
        return window?.convertToScreen(r) ?? r
    }

    // MARK: Clock

    private func updateClock() {
        lines = ClockFormatter.lines(for: Date(), locale: .autoupdatingCurrent, timeZone: .autoupdatingCurrent)
        relayout()
        scheduleNext()
    }

    private func clockSettingsChanged() {
        NSTimeZone.resetSystemTimeZone()
        updateClock()
    }

    private func scheduleNext() {
        timer?.invalidate()
        let next = Calendar.autoupdatingCurrent.nextDate(after: Date(), matching: DateComponents(second: 0), matchingPolicy: .nextTime)
            ?? Date().addingTimeInterval(60)
        let t = Timer(fire: next, interval: 0, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.updateClock() }
        }
        // Fires once a minute, on the minute (not every second). Its tolerance is kept to half a second
        // rather than 10 % of the minute, so the clock never shows the old minute for seconds.
        t.tolerance = 0.5
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    // MARK: Drawing

    private static let textShadow: NSShadow = {
        let s = NSShadow()
        s.shadowColor = NSColor.black.withAlphaComponent(0.6)
        s.shadowOffset = NSSize(width: 0, height: -1)
        s.shadowBlurRadius = 2
        return s
    }()

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        for (item, r) in rects where needsToDraw(r) {
            drawBackground(ctx, r, item: item)
            switch item {
            case .chevron: TrayIcons.draw(ctx, in: iconRect(r), kind: .chevron, level: 0, flag: false)
            case .language: drawLanguage(r)
            case .actionCenter: TrayIcons.drawActionCenter(ctx, in: iconRect(r), alert: !actionCenter.messages.isEmpty)
            case .network:
                let (kind, level) = network.icon
                TrayIcons.draw(ctx, in: iconRect(r), kind: kind, level: level, flag: false)
            case .volume: TrayIcons.draw(ctx, in: iconRect(r), kind: .volume, level: volume.level.iconLevel, flag: false)
            case .battery:
                TrayIcons.draw(ctx, in: iconRect(r), kind: .battery, level: battery.iconLevel, flag: battery.pluggedIn)
            case .clock: drawClock(r)
            }
        }
    }

    /// Hover: white 0.22 fill with a white 0.35 border at radius 2. Pressed (or flyout open): white 0.12.
    private func drawBackground(_ ctx: CGContext, _ r: NSRect, item: Item) {
        let isPressed = pressed == item && hover == item || openItem == item
        guard isPressed || hover == item else { return }
        let path = CGPath(roundedRect: r.insetBy(dx: 1.5, dy: 3.5), cornerWidth: 2, cornerHeight: 2, transform: nil)
        ctx.addPath(path)
        ctx.setFillColor(NSColor.white.withAlphaComponent(isPressed ? 0.12 : 0.22).cgColor)
        ctx.fillPath()
        ctx.addPath(path)
        ctx.setStrokeColor(NSColor.white.withAlphaComponent(0.35).cgColor)
        ctx.setLineWidth(1)
        ctx.strokePath()
    }

    /// The 16 pt icon square centred in the item `r` (TrayIcons draws `tray-<name>.png` or the drawn icon in it).
    private func iconRect(_ r: NSRect) -> NSRect {
        let s = TrayView.iconSize
        return NSRect(x: (r.midX - s / 2).rounded(), y: ((bounds.height - s) / 2).rounded(), width: s, height: s)
    }

    private func drawLanguage(_ r: NSRect) {
        let para = NSMutableParagraphStyle()
        para.alignment = .center
        let font = TrayView.languageFont
        let h = ceil(font.ascender - font.descender)
        (input.abbreviation as NSString).draw(
            in: NSRect(x: r.minX, y: (bounds.height - h) / 2, width: r.width, height: h),
            withAttributes: [.font: font, .foregroundColor: NSColor.white, .paragraphStyle: para,
                             .shadow: TrayView.textShadow])
    }

    private func drawClock(_ r: NSRect) {
        let para = NSMutableParagraphStyle()
        para.alignment = .center
        let attrs: [NSAttributedString.Key: Any] = [
            .font: TrayView.font, .foregroundColor: NSColor.white, .paragraphStyle: para, .shadow: TrayView.textShadow,
        ]
        let font = TrayView.font
        let lineH = ceil(font.ascender - font.descender + font.leading)
        let top = (bounds.height + lineH * 2) / 2
        NSAttributedString(string: lines.time, attributes: attrs)
            .draw(in: NSRect(x: r.minX, y: top - lineH, width: r.width, height: lineH))
        NSAttributedString(string: lines.date, attributes: attrs)
            .draw(in: NSRect(x: r.minX, y: top - lineH * 2, width: r.width, height: lineH))
    }

    // MARK: Tooltips

    func view(_ view: NSView, stringForToolTip tag: NSView.ToolTipTag, point: NSPoint,
                       userData data: UnsafeMutableRawPointer?) -> String {
        switch item(at: point) {
        case .chevron: "Show hidden icons"
        case .language: input.currentName
        case .actionCenter: actionCenter.tooltip
        case .network: network.tooltip
        case .volume: volume.tooltip
        case .battery: battery.tooltip
        case .clock: ClockFlyout.longDate(Date())
        case nil: ""
        }
    }

    // MARK: Mouse

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        for a in trackingAreas { removeTrackingArea(a) }
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseMoved, .mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                       owner: self, userInfo: nil))
    }

    /// A hover change redraws the item it left and the one it entered, not the whole tray.
    private func setHover(_ i: Item?) {
        guard i != hover else { return }
        for old in [hover, i].compactMap({ $0 }) { if let r = rect(of: old) { setNeedsDisplay(r) } }
        hover = i
    }

    override func mouseMoved(with event: NSEvent) {
        setHover(item(at: convert(event.locationInWindow, from: nil)))
    }

    override func mouseExited(with event: NSEvent) {
        setHover(nil)
    }

    override func mouseDown(with event: NSEvent) {
        pressed = item(at: convert(event.locationInWindow, from: nil))
        hover = pressed
        needsDisplay = true
    }

    override func mouseDragged(with event: NSEvent) {
        setHover(item(at: convert(event.locationInWindow, from: nil)))
    }

    override func mouseUp(with event: NSEvent) {
        let target = pressed
        pressed = nil
        needsDisplay = true
        guard let target, item(at: convert(event.locationInWindow, from: nil)) == target else { return }
        activate(target)
    }

    override func scrollWheel(with event: NSEvent) {
        guard item(at: convert(event.locationInWindow, from: nil)) == .volume else { return }
        let n = TrayScroll.notches(event, accumulator: &scrollAccumulator)
        if n != 0 { volume.step(notches: n) }
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    // MARK: Right-click menus

    override func rightMouseDown(with event: NSEvent) {
        guard let item = item(at: convert(event.locationInWindow, from: nil)), let icon = item.menuIcon else { return }
        TrayFlyout.closeCurrent()
        let diagnostics = NSWorkspace.shared.urlForApplication(withBundleIdentifier: TrayMenus.wirelessDiagnosticsBundleID) != nil
        menuEntries = TrayMenus.items(for: icon, wirelessDiagnosticsAvailable: diagnostics)
        let menu = NSMenu()
        menu.autoenablesItems = false
        for (i, entry) in menuEntries.enumerated() {
            let mi = NSMenuItem(title: entry.title, action: #selector(menuChosen(_:)), keyEquivalent: "")
            mi.target = self
            mi.tag = i
            mi.isEnabled = entry.enabled
            menu.addItem(mi)
        }
        pendingMenuAction = nil
        popUpMenu(menu, titles: menuEntries.map(\.title), for: item)
        menuEntries = []
        // Run the choice only after the menu's pressed state is cleared, so a flyout it opens keeps its own.
        if let action = pendingMenuAction {
            pendingMenuAction = nil
            perform(action)
        }
    }

    private var pendingMenuAction: TrayMenuAction?

    @objc private func menuChosen(_ sender: NSMenuItem) {
        guard menuEntries.indices.contains(sender.tag) else { return }
        pendingMenuAction = menuEntries[sender.tag].action
    }

    /// Runs a tray menu item's or an Action Center button's action.
    private func perform(_ action: TrayMenuAction) {
        switch action {
        case .open(let pane):
            openSettings(pane)
        case .wirelessDiagnostics:
            TrayFlyout.closeCurrent()
            if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: TrayMenus.wirelessDiagnosticsBundleID) {
                NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration())
            }
        case .showOverflow:
            TrayFlyout.closeCurrent()
            lastClosed = nil
            activate(.chevron)
        }
    }

    // MARK: Flyouts

    private func activate(_ item: Item) {
        // A second click on the item whose flyout is open closes it. If the flyout already closed
        // itself during this click (it lost key), don't reopen it.
        if TrayFlyout.current?.owner == item.rawValue {
            TrayFlyout.closeCurrent()
            return
        }
        if let last = lastClosed, last.item == item, ProcessInfo.processInfo.systemUptime - last.time < 0.3 { return }
        let content: NSView
        switch item {
        case .language:
            TrayFlyout.closeCurrent()
            showLanguageMenu()
            return
        case .clock:
            content = ClockFlyout()
        case .actionCenter:
            actionCenter.refresh()
            let f = ActionCenterFlyout(status: actionCenter) { [weak self] in self?.perform($0) }
            actionCenterFlyout = f
            content = f
        case .volume:
            let f = VolumeFlyout(control: volume)
            volumeFlyout = f
            content = f
        case .network:
            let f = NetworkFlyout(status: network)
            networkFlyout = f
            content = f
        case .battery:
            let f = BatteryFlyout(status: battery)
            batteryFlyout = f
            content = f
        case .chevron:
            content = OverflowFlyout()
        }
        let flyout = TrayFlyout.show(content, owner: item.rawValue, above: screenRect(of: item))
        openItem = item
        flyout.onClose = { [weak self] in
            guard let self else { return }
            if self.openItem == item { self.openItem = nil }
            self.lastClosed = (item, ProcessInfo.processInfo.systemUptime)
            self.needsDisplay = true
        }
        needsDisplay = true
    }

    private func showLanguageMenu() {
        menuSources = input.enabledSources()
        guard !menuSources.isEmpty else { return }
        let menu = NSMenu()
        var titles: [String] = []
        for (i, s) in menuSources.enumerated() {
            let title = "\(s.abbreviation)   \(s.name)"
            let mi = NSMenuItem(title: title, action: #selector(selectSource(_:)), keyEquivalent: "")
            mi.target = self
            mi.tag = i
            mi.state = s.id == input.currentID ? .on : .off
            menu.addItem(mi)
            titles.append(title)
        }
        popUpMenu(menu, titles: titles, for: .language)
        menuSources = []
    }

    /// Shows `menu` (one row per entry of `titles`, which size it) as a Windows 7 menu above `item`,
    /// kept on screen, with `item` drawn pressed until the menu closes. Returns after the chosen
    /// item's action has run.
    private func popUpMenu(_ menu: NSMenu, titles: [String], for item: Item) {
        let widest = titles.map { ($0 as NSString).size(withAttributes: [.font: TrayView.font]).width }.max() ?? 0
        let height = CGFloat(titles.count) * W7MenuItemHeight + 4
        let width = max(W7MenuMinWidth, ceil(widest) + W7MenuGutterWidth + 40)
        let anchor = screenRect(of: item)
        let screenMaxX = window?.screen?.frame.maxX ?? anchor.maxX + width
        openItem = item
        needsDisplay = true
        // the shell is an accessory app, so it must be active for keyboard navigation to work.
        NSApp.activate()
        ShellMenus.show(menu, at: NSPoint(x: min(anchor.minX, screenMaxX - width - 4), y: anchor.maxY + height), above: anchor)
        openItem = nil
        needsDisplay = true
    }

    @objc private func selectSource(_ sender: NSMenuItem) {
        guard menuSources.indices.contains(sender.tag) else { return }
        input.select(menuSources[sender.tag])
    }
}

extension TrayView: NSViewToolTipOwner {}

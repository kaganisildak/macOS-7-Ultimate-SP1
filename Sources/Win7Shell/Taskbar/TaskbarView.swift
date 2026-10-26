import AppKit
import Win7Core
import Win7ChromeCore
import Win7Theme

@MainActor
final class TaskbarView: NSView {
    static let orbWidth: CGFloat = 54
    static let buttonWidth: CGFloat = 60
    static let iconSize: CGFloat = 32
    static let showDesktopWidth: CGFloat = 15
    /// How often the grouped (stacked) look re-counts each app's on-screen windows.
    private static let stackRefreshInterval: TimeInterval = 1.5

    var onShowDesktop: (() -> Void)? { didSet { menus.onShowDesktop = onShowDesktop } }
    var onStartClick: (() -> Void)?
    /// Hover-intent hooks. The rect is the hovered button in screen coordinates.
    var onPeekBegin: (() -> Void)?
    var onPeekEnd: (() -> Void)?
    var onThumbnailHover: ((TaskbarItem, NSRect) -> Void)?
    var onThumbnailHoverEnd: (() -> Void)?
    /// A running item's windows; they decide between the window list, un-minimize, reopen and
    /// the app-level activate/hide.
    var windowCounts: ((TaskbarItem) -> WindowCounts)?
    /// Un-minimize the item's only (minimized) window, then raise and activate it (Accessibility).
    var onUnminimize: ((TaskbarItem) -> Void)?
    /// A click on a button with several windows. The rect is the button in screen coordinates.
    var onWindowList: ((TaskbarItem, NSRect) -> Void)?
    /// Any other click on a taskbar button (launch, activate, hide, reopen, un-minimize), and a jump
    /// list opening: closes the window popup.
    var onButtonClick: (() -> Void)?
    /// The app a pinned window popup took focus from, for menus and jump lists opened while the
    /// shell is frontmost because of it.
    var rememberedFocus: (() -> NSRunningApplication?)?
    /// The pointer entered a running button: its windows are fetched ahead of a click.
    var onButtonHover: ((TaskbarItem) -> Void)?
    /// A click, or a jump list's Close window / Close all windows, acted on the item's windows: their
    /// cached snapshot is stale.
    var onWindowsActedOn: ((TaskbarItem) -> Void)?
    /// The running item whose button is under the pointer (or has keyboard focus).
    var hoveredRunningItem: TaskbarItem? {
        guard let i = hoverIndex, i < items.count, items[i].isRunning else { return nil }
        return items[i]
    }
    /// Asks for a background snapshot of every app's on-screen windows; `applyStacks` receives it.
    var requestStacks: (() -> Void)?
    var startMenuOpen = false { didSet { if startMenuOpen != oldValue { setNeedsDisplay(orbRect) } } }

    let observer: RunningAppsObserver
    private let tray: TrayView
    private let jumpList = JumpListController()
    private let menus = TaskbarMenus()
    var pins: [PinnedApp]
    var items: [TaskbarItem] = []
    private var iconCache: [String: NSImage] = [:]
    /// The hot-track glow colour per bundle ID, also as the RGBA of its cached button image (nil
    /// inside: the icon has no opaque pixel).
    private var glowCache: [String: (color: CGColor, rgba: TaskbarButtonLook.RGBA)?] = [:]
    /// Button backgrounds pre-rendered per look.
    private let buttonImages = TaskbarButtonImages()
    /// On-screen windows per bundle ID (CGWindowList), for the stacked look.
    private var stackCounts: [String: Int] = [:]
    private var stackTimer: Timer?
    private var pinToken: NSObjectProtocol?
    /// The current page when the buttons overflow.
    var page = 0 { didSet { if page != oldValue { refreshToolTips() } } }
    var hoverIndex: Int?
    private var hoverOrb = false
    private var hoverShowDesktop = false
    /// The hovered paging arrow: 0 up, 1 down.
    var hoverArrow: Int?
    private var peekState = PeekHoverState(delay: 0.5)
    private var thumbIntent = HoverIntent(delay: 0.4)
    private var peekTimer: Timer?
    private var thumbTimer: Timer?

    /// A left press on a button: it acts on release unless it turns into a drag.
    struct Press {
        var bundleID: String
        var start: NSPoint
        /// Pointer x minus the button's left edge.
        var grab: CGFloat
        var gesture: TaskbarDragGesture?
        /// For a reorder: the app a popup the press closed would have given focus back to.
        var remembered: NSRunningApplication?
    }
    var press: Press?
    /// While reordering, the dragged button's left edge (view coordinates).
    var dragX: CGFloat?

    init(observer: RunningAppsObserver) {
        self.observer = observer
        tray = TrayView(frame: .zero)
        pins = TaskbarPinList.load(.standard)
        super.init(frame: .zero)
        addSubview(tray)
        tray.onWidthChange = { [weak self] in
            self?.needsLayout = true
            self?.needsDisplay = true
        }
        observer.onChange = { [weak self] in self?.reload() }
        // The Start menu's "Pin to Taskbar" edits the same list (one source of truth).
        pinToken = NotificationCenter.default.addObserver(forName: TaskbarPinList.didChange, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.pins = TaskbarPinList.load(.standard)
                self.reload()
            }
        }
        jumpList.taskbarHit = { [weak self] p in self?.hit(atScreen: p) ?? .button }
        jumpList.onChoose = { [weak self] action, id, previous in self?.perform(action, bundleID: id, previous: previous) }
        // The snapshot itself runs on the window store's background queue.
        stackTimer = Timer.w7Scheduled(Self.stackRefreshInterval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.requestStacks?() }
        }
        reload()
    }
    required init?(coder: NSCoder) { fatalError() }

    func reload() {
        // Windows names: tooltips, jump list headers and close prompts show them.
        items = currentItems()
        page = paging.clamped(page)
        refreshToolTips()
        requestStacks?()
        needsDisplay = true
    }

    /// The buttons for the current pins and running apps, with Windows names (ProgramNames); a drag reorder rebuilds
    /// them with this too, so tooltips keep the Windows names while dragging.
    func currentItems() -> [TaskbarItem] {
        ProgramNames.renamed(TaskbarModel.items(pinned: pins, running: observer.apps))
    }

    /// Counts each running app's listed on-screen windows (no permission needed; minimized windows
    /// are not counted, as CGWindowList cannot tell them from other-Space ones), from a snapshot taken
    /// off the main thread. Only buttons whose count changed are redrawn.
    func applyStacks(_ onScreenByPID: [Int32: [CGWindowInfo]]) {
        ShellPerf.measure("applyStacks") {
            var counts: [String: Int] = [:]
            for app in observer.apps {
                counts[app.bundleID, default: 0] += WindowList.counts(ax: nil, cg: onScreenByPID[app.pid] ?? []).total
            }
            guard counts != stackCounts else { return }
            let changed = Set(counts.keys).union(stackCounts.keys).filter { counts[$0] != stackCounts[$0] }
            stackCounts = counts
            for i in visibleRange where changed.contains(items[i].bundleID) { setNeedsDisplay(buttonRect(i)) }
        }
    }

    private func togglePin(_ item: TaskbarItem) {
        pins = TaskbarPinList.toggled(pins, bundleID: item.bundleID, name: item.name)
        TaskbarPinList.save(pins, .standard)
        reload()
    }

    // MARK: Layout

    private var showDesktopRect: NSRect {
        NSRect(x: bounds.width - TaskbarView.showDesktopWidth, y: 0, width: TaskbarView.showDesktopWidth, height: bounds.height)
    }
    private var orbRect: NSRect { NSRect(x: 0, y: 0, width: TaskbarView.orbWidth, height: bounds.height) }

    /// The left edge of the notification area; taskbar buttons stop here.
    var trayMinX: CGFloat { bounds.width - TaskbarView.showDesktopWidth - tray.preferredWidth }

    /// Item `i` (in `visibleRange`) at its slot on the current page (paging: TaskbarView+Drag.swift).
    func buttonRect(_ i: Int) -> NSRect {
        NSRect(x: TaskbarView.orbWidth + CGFloat(i - visibleRange.lowerBound) * TaskbarView.buttonWidth, y: 0,
               width: TaskbarView.buttonWidth, height: bounds.height)
    }

    override func layout() {
        super.layout()
        tray.frame = NSRect(x: trayMinX, y: 0, width: tray.preferredWidth, height: bounds.height)
        page = paging.clamped(page)
        refreshToolTips()
    }

    // MARK: Tooltips

    /// Windows 7 names an idle (pinned, not running) button in a tooltip; a running button shows its thumbnails.
    private func refreshToolTips() {
        removeAllToolTips()
        for i in visibleRange where !items[i].isRunning { addToolTip(buttonRect(i), owner: self, userData: nil) }
    }

    func view(_ view: NSView, stringForToolTip tag: NSView.ToolTipTag, point: NSPoint,
              userData data: UnsafeMutableRawPointer?) -> String {
        guard let i = buttonIndex(at: point), items.indices.contains(i), !items[i].isRunning else { return "" }
        return items[i].name
    }

    // MARK: Drawing

    private func icon(for item: TaskbarItem) -> NSImage {
        if let i = iconCache[item.bundleID] { return i }
        let img: NSImage
        // The user's app-<bundle id> override (Assets/icons) first; the jump list shows the same icon. A shell
        // window's button (the Control Panel) draws that window's icon.
        if let shell = ShellWindowButtons.entry(item.bundleID) {
            img = shell.icon(TaskbarView.iconSize)
        } else if let override = IconOverrides.app(item.bundleID, side: TaskbarView.iconSize) {
            img = override
        } else if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: item.bundleID) {
            img = NSWorkspace.shared.icon(forFile: url.path)
        } else {
            img = NSImage(named: NSImage.applicationIconName) ?? NSImage()
        }
        iconCache[item.bundleID] = img
        return img
    }

    /// The icon at the size it is drawn, rendered once per bundle ID and scale.
    private func drawnIcon(for item: TaskbarItem) -> NSImage {
        ScaledIconCache.shared.icon("app:" + item.bundleID, side: TaskbarView.iconSize, scale: backingScale) { icon(for: item) }
    }

    private var backingScale: CGFloat { window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2 }

    /// The icon's dominant colour, computed once per icon from a 32 pt rendering.
    private func glow(for item: TaskbarItem) -> (color: CGColor, rgba: TaskbarButtonLook.RGBA)? {
        if let cached = glowCache[item.bundleID] { return cached }
        let side = 32
        var data = [UInt8](repeating: 0, count: side * side * 4)
        let cs = CGColorSpace(name: CGColorSpace.sRGB)!
        var proposed = NSRect(x: 0, y: 0, width: side, height: side)
        if let cg = icon(for: item).cgImage(forProposedRect: &proposed, context: nil, hints: nil) {
            data.withUnsafeMutableBytes { buf in
                CGContext(data: buf.baseAddress, width: side, height: side, bitsPerComponent: 8, bytesPerRow: side * 4,
                          space: cs, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)?
                    .draw(cg, in: CGRect(x: 0, y: 0, width: side, height: side))
            }
        }
        let glow = IconTint.dominantColor(premultipliedRGBA: data).map { c in
            func byte(_ v: Double) -> UInt8 { UInt8(max(0, min(255, (v * 255).rounded()))) }
            return (color: CGColor(srgbRed: CGFloat(c.r), green: CGFloat(c.g), blue: CGFloat(c.b), alpha: 1),
                    rgba: TaskbarButtonLook.RGBA(r: byte(Double(c.r)), g: byte(Double(c.g)), b: byte(Double(c.b))))
        }
        glowCache[item.bundleID] = .some(glow)
        return glow
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        buttonImages.removeAll()   // keyed by scale too; the old scale's images are dead weight
        needsDisplay = true
    }

    /// Hover changes redraw only the parts that went hot or cold (`setNeedsDisplay(_:)` with their
    /// rects), so each part is drawn only when it is in the dirty region.
    override func draw(_ dirtyRect: NSRect) {
        ShellPerf.measure("taskbarDraw") { drawTaskbar(dirtyRect) }
    }

    private func drawTaskbar(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        W7DrawTaskbarBackground(ctx, bounds)
        if needsToDraw(orbRect) {
            let orbName = startMenuOpen ? "start-orb-pressed.png" : (hoverOrb ? "start-orb-hover.png" : "start-orb.png")
            let orb = AssetStore.shared.cgImage(orbName) ?? AssetStore.shared.cgImage("start-orb.png")
            W7DrawStartOrb(ctx, orbRect, startMenuOpen ? .pressed : (hoverOrb ? .hover : .normal), orb)
        }
        let limit = pagerRect?.minX ?? trayMinX
        let dragged = press?.gesture == .reorder ? press?.bundleID : nil
        for i in visibleRange where items[i].bundleID != dragged {
            let r = buttonRect(i)
            if r.maxX > limit { break }
            if needsToDraw(r) { drawButton(ctx, items[i], in: r, hover: hoverIndex == i) }
        }
        // The dragged button follows the pointer, over the others.
        if let dragged, let x = dragX, let item = items.first(where: { $0.bundleID == dragged }) {
            drawButton(ctx, item, in: NSRect(x: x, y: 0, width: TaskbarView.buttonWidth, height: bounds.height), hover: true)
        }
        drawPager(ctx)
        let sd = showDesktopRect
        ctx.setFillColor(NSColor.white.withAlphaComponent(hoverShowDesktop ? 0.35 : 0.12).cgColor)
        ctx.fill(sd)
        ctx.setFillColor(NSColor.white.withAlphaComponent(0.4).cgColor)
        ctx.fill(NSRect(x: sd.minX, y: 0, width: 1, height: sd.height))
    }

    private func drawButton(_ ctx: CGContext, _ item: TaskbarItem, in r: NSRect, hover: Bool) {
        // The stacked edges count CGWindowList's on-screen windows only (`applyStacks`): no AX IPC
        // on a timer, so minimized and other-Space windows add no edge.
        let windows = item.isRunning ? stackCounts[item.bundleID] ?? 1 : 0
        // Pinned, idle buttons draw no background.
        if item.isRunning || item.isActive || hover {
            let g = hover ? glow(for: item) : nil
            let look = TaskbarButtonLook(running: item.isRunning, active: item.isActive, hover: hover, windows: windows,
                                         glow: g?.rgba, size: r.size, scale: backingScale)
            if let image = buttonImages.image(for: look, size: r.size, scale: backingScale, glow: g?.color) {
                ctx.draw(image, in: r)
            } else {
                W7DrawTaskbarGroupButton(ctx, r, item.isRunning, item.isActive, hover, windows, g?.color)
            }
        }
        // Stacked buttons are narrower: the icon stays centred on the front button.
        let front = r.width - 3 * CGFloat(item.isRunning ? min(2, max(0, windows - 1)) : 0)
        let side = TaskbarView.iconSize
        drawnIcon(for: item).draw(in: NSRect(x: r.minX + front / 2 - side / 2, y: r.midY - side / 2, width: side, height: side))
    }

    // MARK: Hit testing and hover

    func buttonIndex(at p: NSPoint) -> Int? {
        guard p.x >= TaskbarView.orbWidth, p.y >= 0, p.y < bounds.height else { return nil }
        let limit = pagerRect?.minX ?? trayMinX
        let slot = Int((p.x - TaskbarView.orbWidth) / TaskbarView.buttonWidth)
        let i = visibleRange.lowerBound + slot
        guard visibleRange.contains(i), buttonRect(i).maxX <= limit else { return nil }
        return i
    }

    private func hit(at p: NSPoint) -> TaskbarHit {
        if buttonIndex(at: p) != nil { return .button }
        if orbRect.contains(p) { return .orb }
        if showDesktopRect.contains(p) { return .showDesktop }
        if tray.frame.contains(p) { return .tray }
        if pagerRect?.contains(p) == true { return .pager }
        return .bare
    }

    /// What part of the taskbar a screen point is on.
    func hit(atScreen screenPoint: NSPoint) -> TaskbarHit {
        guard let window else { return .button }
        return hit(at: convert(window.convertPoint(fromScreen: screenPoint), from: nil))
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        for a in trackingAreas { removeTrackingArea(a) }
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseMoved, .mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                       owner: self, userInfo: nil))
    }

    private var hover: TaskbarHover {
        TaskbarHover(button: hoverIndex, orb: hoverOrb, showDesktop: hoverShowDesktop, arrow: hoverArrow)
    }

    private func hoverRect(_ target: TaskbarHoverTarget) -> CGRect? {
        switch target {
        case .orb: orbRect
        case .button(let i): visibleRange.contains(i) ? buttonRect(i) : nil
        case .showDesktop: showDesktopRect
        case .pageArrow(let a): arrowRect(a)
        }
    }

    /// Redraws what went hot or cold since `old`.
    private func invalidateHover(from old: TaskbarHover) {
        for r in TaskbarInvalidation.dirtyRects(from: old, to: hover, rect: hoverRect) { setNeedsDisplay(r) }
    }

    override func mouseMoved(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        let idx = buttonIndex(at: p), orb = orbRect.contains(p), sd = showDesktopRect.contains(p)
        let arrow = [0, 1].first { arrowRect($0)?.contains(p) == true }
        let old = hover
        hoverIndex = idx; hoverOrb = orb; hoverShowDesktop = sd; hoverArrow = arrow
        guard hover != old else { return }
        invalidateHover(from: old)
        if idx != old.button { buttonHoverChanged(to: idx, hadButton: old.button != nil) }
        if sd != old.showDesktop { showDesktopHoverChanged(sd) }
    }

    override func mouseExited(with event: NSEvent) {
        let hadButton = hoverIndex != nil, hadSD = hoverShowDesktop
        let old = hover
        hoverIndex = nil; hoverOrb = false; hoverShowDesktop = false; hoverArrow = nil
        invalidateHover(from: old)
        if hadButton { buttonHoverChanged(to: nil, hadButton: true) }
        if hadSD { showDesktopHoverChanged(false) }
    }

    func cancelThumbnailHover() {
        thumbIntent.exit()
        thumbTimer?.invalidate(); thumbTimer = nil
    }

    private func buttonHoverChanged(to idx: Int?, hadButton: Bool) {
        cancelThumbnailHover()
        if hadButton { onThumbnailHoverEnd?() }
        // No previews while a jump list is open or a button is being dragged.
        guard let idx, items[idx].isRunning, !jumpList.isOpen, press?.gesture == nil else { return }
        let bundleID = items[idx].bundleID
        onButtonHover?(items[idx])
        thumbIntent.enter(at: ProcessInfo.processInfo.systemUptime)
        thumbTimer = Timer.w7Scheduled(thumbIntent.delay, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, let cur = self.hoverIndex, cur < self.items.count,
                      self.items[cur].bundleID == bundleID, !self.jumpList.isOpen, self.press?.gesture == nil,
                      self.thumbIntent.shouldFire(now: ProcessInfo.processInfo.systemUptime) else { return }
                self.onThumbnailHover?(self.items[cur], self.screenRect(ofButton: cur))
            }
        }
    }

    private func showDesktopHoverChanged(_ inside: Bool) {
        peekTimer?.invalidate(); peekTimer = nil
        apply(peekState.exit())
        guard inside else { return }
        peekState.enter(at: ProcessInfo.processInfo.systemUptime)
        peekTimer = Timer.w7Scheduled(peekState.delay, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.hoverShowDesktop else { return }
                self.apply(self.peekState.tick(now: ProcessInfo.processInfo.systemUptime))
            }
        }
    }

    private func apply(_ action: PeekAction?) {
        switch action {
        case .begin: onPeekBegin?()
        case .end: onPeekEnd?()
        case nil: break
        }
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    // MARK: Left clicks and drags

    override func mouseDown(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        if showDesktopRect.contains(p) {
            peekTimer?.invalidate(); peekTimer = nil
            apply(peekState.click())
            onShowDesktop?(); return
        }
        if orbRect.contains(p) {
            TaskbarActivation.cancel()   // the Start menu takes focus: a pending restore check must not steal it
            onStartClick?(); return
        }
        if pagerClick(at: p) { return }
        // A button acts when released (as on Windows), so the press can still become a drag
        // (TaskbarView+Drag.swift).
        guard let i = buttonIndex(at: p) else { return }
        press = Press(bundleID: items[i].bundleID, start: p, grab: p.x - buttonRect(i).minX, gesture: nil, remembered: nil)
    }

    // MARK: Keyboard (Win+1…9, Win+T)

    /// Taskbar buttons that can be shown (paging brings any of them on screen).
    var visibleButtonCount: Int { items.count }

    /// Does what a left click on button `i` does; the mouse (on release) and Win+1…9 share it.
    func click(buttonAt i: Int) {
        guard i < items.count else { return }
        show(index: i)
        let item = items[i]
        // A shell window: minimize or restore it.
        if ShellWindowButtons.click(item.bundleID) { TaskbarActivation.cancel(); onButtonClick?(); return }
        let counts = item.isRunning ? ShellPerf.measure("taskbarClickCounts") { windowCounts?(item) ?? WindowCounts(total: 1) }
                                    : WindowCounts(total: 0)
        let action = TaskbarModel.clickAction(for: item, windows: counts)
        TaskbarActivation.cancel()   // this click decides afresh (it may hide the app)
        if action == .showWindowList {
            onWindowList?(item, screenRect(ofButton: i))
            return
        }
        onButtonClick?()
        perform(action, on: item)
        onWindowsActedOn?(item)
    }

    /// Highlights button `i` as the pointer would, opening a running app's preview popup; nil clears it.
    func setKeyboardFocus(_ i: Int?) {
        let index = i.flatMap { $0 < items.count ? $0 : nil }
        if let index { show(index: index) }
        guard index != hoverIndex else { return }
        let hadButton = hoverIndex != nil
        let old = hover
        hoverIndex = index
        invalidateHover(from: old)
        buttonHoverChanged(to: index, hadButton: hadButton)
    }

    private func screenRect(ofButton i: Int) -> NSRect {
        let r = convert(buttonRect(i), to: nil)
        return window?.convertToScreen(r) ?? r
    }

    private func screenPoint(_ event: NSEvent) -> NSPoint {
        window?.convertPoint(toScreen: event.locationInWindow) ?? event.locationInWindow
    }

    private func perform(_ action: TaskbarClickAction, on item: TaskbarItem) {
        let apps = NSRunningApplication.runningApplications(withBundleIdentifier: item.bundleID)
        switch action {
        case .launch:
            TaskbarLaunch.launch(bundleID: item.bundleID)
        case .activate:
            for a in apps { a.unhide() }
            TaskbarActivation.bringForward(bundleID: item.bundleID)
        case .hide:
            for a in apps { a.hide() }
        case .reopen:
            TaskbarView.reopen(bundleID: item.bundleID)
        case .unminimize:
            // AppDelegate un-minimizes and raises the window, then brings its app forward with the
            // check and retry (`TaskbarActivation`), or reopens the app when the window went away.
            onUnminimize?(item)
        case .showWindowList:
            break   // needs the button's rect: mouseUp hands it to onWindowList
        }
    }

    /// What a Dock click does: unhide, then kAEReopenApplication, so AppKit deminiaturizes a window
    /// or opens a new one. No Accessibility needed. LaunchServices' own activation can be refused
    /// while another app is active, so once the reopen is handled (or the open failed, or the app's
    /// URL is unknown) the app is brought forward and checked.
    static func reopen(bundleID: String) {
        let apps = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
        for a in apps { a.unhide() }
        guard let url = apps.first?.bundleURL ?? NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID)
        else { TaskbarActivation.bringForward(bundleID: bundleID); return }
        let config = NSWorkspace.OpenConfiguration()
        config.activates = true
        NSWorkspace.shared.openApplication(at: url, configuration: config) { _, _ in
            DispatchQueue.main.async {
                MainActor.assumeIsolated { TaskbarActivation.bringForward(bundleID: bundleID) }
            }
        }
    }

    // MARK: Middle clicks

    /// A middle click on a running button opens a new window; on a pinned one it launches the app.
    override func otherMouseDown(with event: NSEvent) {
        guard TaskbarMouseButton(event) == .middle,
              let i = buttonIndex(at: convert(event.locationInWindow, from: nil)) else { return }
        let item = items[i]
        onButtonClick?()
        if ShellWindowButtons.click(item.bundleID) { return }
        if item.isRunning { TaskbarLaunch.newWindow(bundleID: item.bundleID) } else { TaskbarLaunch.launch(bundleID: item.bundleID) }
    }

    // MARK: Right clicks: jump lists and menus

    /// The app a jump list just closed by this click would have given focus back to.
    var jumpListRememberedApp: NSRunningApplication? { jumpList.rememberedApp }

    /// The app focus goes back to when a menu or jump list opened now closes without a choice,
    /// if the shell is frontmost because a jump list or pinned window popup activated it.
    func rememberedApp() -> NSRunningApplication? { jumpList.rememberedApp ?? rememberedFocus?() }

    override func rightMouseDown(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        TaskbarActivation.cancel()   // a jump list or menu takes focus next
        if let i = buttonIndex(at: p) { openJumpList(i); return }
        switch hit(at: p) {
        case .orb:
            let remembered = rememberedApp()
            onButtonClick?()
            menus.showOrbMenu(at: screenPoint(event), remembered: remembered)
        case .bare, .pager:
            let remembered = rememberedApp()
            onButtonClick?()
            menus.showTaskbarMenu(at: screenPoint(event), remembered: remembered)
        case .button, .showDesktop, .tray:
            break
        }
    }

    func openJumpList(_ i: Int) {
        let item = items[i]
        let remembered = rememberedApp()
        cancelThumbnailHover()
        onButtonClick?()   // closes the window popup
        // A shell window has no jump list of its own, only its window commands.
        if let menu = ShellWindowButtons.menu(item.bundleID) {   // above the bar, as a jump list opens
            let rect = window?.convertToScreen(convert(NSRect(x: buttonRect(i).minX, y: bounds.minY, width: 1, height: bounds.height),
                                                       to: nil)) ?? .zero
            ShellMenus.show(menu, at: ShellMenus.pointAbove(rect, for: menu), above: rect)
            return
        }
        let count = item.isRunning ? (windowCounts?(item).total ?? 0) : 0
        let recent = RecentDocuments.load(bundleID: item.bundleID,
                                          directory: RecentDocuments.defaultDirectory(home: FileManager.default.homeDirectoryForCurrentUser),
                                          home: NSHomeDirectory())
        // Finder's "Frequent": its recent folders, from its own preferences (a plain plist read).
        let frequent = item.bundleID == TaskbarLaunch.finderID
            ? FrequentFolders.load(preference: CFPreferencesCopyAppValue(FrequentFolders.key as CFString,
                                                                         FrequentFolders.domain as CFString),
                                   home: NSHomeDirectory())
            : nil
        let input = JumpListInput(appName: item.name, isPinned: item.isPinned, isRunning: item.isRunning,
                                  windowCount: count, accessibility: TaskbarWindowActions.isTrusted, recent: recent,
                                  frequent: frequent)
        jumpList.show(bundleID: item.bundleID, sections: JumpList.sections(input), appIcon: icon(for: item),
                      above: screenRect(ofButton: i), remembered: remembered)
    }

    private func perform(_ action: JumpListAction, bundleID: String, previous: NSRunningApplication?) {
        guard let item = items.first(where: { $0.bundleID == bundleID }) else { return }
        switch action {
        case .openRecent(let path):
            TaskbarLaunch.open(path: path, bundleID: bundleID)
        case .openFolder(let path):
            TaskbarLaunch.openFolder(path: path)
        case .launch:
            if item.isRunning { TaskbarLaunch.newWindow(bundleID: bundleID) } else { TaskbarLaunch.launch(bundleID: bundleID) }
        case .pin, .unpin:
            togglePin(item)
        case .closeWindow, .closeAllWindows:
            // Offered with or without Accessibility, as in Windows 7: through the app when the
            // dylib is in it, else Accessibility, else the balloon or the confirmation; the app exits
            // when its last window closed.
            TaskbarCloseRequest.start(action, item: item, previous: previous) { [weak self] in
                self?.onWindowsActedOn?(item)
            }
        }
    }
}

extension TaskbarView: NSViewToolTipOwner {}

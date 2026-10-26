import AppKit
import Win7Core
import Win7Theme

/// Option+Tab window switcher. The tap callback only flips `isOpen` and enqueues work; AX and
/// UI happen on later main-queue turns, in the order the keys arrived.
@MainActor
final class SwitcherController {
    private static let maxCells = 12

    private let service: WindowService
    private let provider: ThumbnailProvider
    private let tap = EventTap()
    private var keys = SwitcherKeyState()
    private var model = SwitcherModel(windows: [])
    private var panel: NSPanel?
    private var view: SwitcherView?
    private var thumbTask: Task<Void, Never>?

    init(service: WindowService, provider: ThumbnailProvider) {
        self.service = service
        self.provider = provider
        tap.handler = { [weak self] in self?.handle($0) ?? false }
    }

    /// Driven by the 5 s permission tick: the tap exists only while `.switcher` is enabled.
    var isEnabled = false {
        didSet {
            guard isEnabled != oldValue || (isEnabled && !tap.isRunning) else { return }
            if isEnabled { _ = tap.start() } else { tap.stop(); _ = handle(.tapDisabled) }
        }
    }

    private func later(_ work: @escaping @MainActor (SwitcherController) -> Void) {
        DispatchQueue.main.async { [weak self] in
            MainActor.assumeIsolated { if let self { work(self) } }
        }
    }

    /// Runs inside the tap callback: pure state-machine step, then ordered deferred work.
    private func handle(_ e: SwitcherKeyEvent) -> Bool {
        let r = keys.handle(e)
        switch r.action {
        case .open(let reverse):
            let gen = keys.generation
            later { $0.open(reverse: reverse, generation: gen) }
        case .next: later { $0.model.next(); $0.refresh() }
        case .previous: later { $0.model.previous(); $0.refresh() }
        case .commit: later { $0.commit() }
        case .cancel: later { $0.close() }
        case nil: break
        }
        return r.consume
    }

    // MARK: Main-actor work

    private func open(reverse: Bool, generation: Int) {
        let windows = ShellPerf.measure("switcherWindows") { currentWindows() }
        guard !windows.isEmpty else { keys.abortOpen(generation: generation); return }
        model = SwitcherModel(windows: windows, reverse: reverse)
        showPanel()
        loadThumbnails()
    }

    private func currentWindows() -> [SwitcherWindow] {
        let opts: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
        guard let info = CGWindowListCopyWindowInfo(opts, kCGNullWindowID) as? [[String: Any]] else { return [] }
        let me = ProcessInfo.processInfo.processIdentifier
        // The dylib's Aero frame overlays are separate windows of each app: not switcher entries.
        let overlays = CGWindowInfo.frameBorderOverlayIDs(in: info)
        var result: [SwitcherWindow] = []
        for w in info {
            guard (w[kCGWindowLayer as String] as? Int) == 0,
                  let pid = w[kCGWindowOwnerPID as String] as? Int32, pid != me,
                  let id = w[kCGWindowNumber as String] as? UInt32, !overlays.contains(id),
                  (w[kCGWindowAlpha as String] as? Double ?? 1) > 0,
                  let b = w[kCGWindowBounds as String] as? [String: Double],
                  (b["Width"] ?? 0) > 50, (b["Height"] ?? 0) > 50 else { continue }
            // The program's Windows name for an untitled window and the app name.
            let owner = ProgramNames.displayName(bundleID: NSRunningApplication(processIdentifier: pid)?.bundleIdentifier,
                                                 macName: w[kCGWindowOwnerName as String] as? String ?? "")
            let title = w[kCGWindowName as String] as? String ?? ""
            result.append(SwitcherWindow(windowID: id, pid: pid, title: title.isEmpty ? owner : title, appName: owner))
            if result.count == Self.maxCells { break }
        }
        return result
    }

    private func showPanel() {
        let icons = model.windows.map { IconOverrides.app(pid: $0.pid, side: SwitcherView.iconSize) }
        let v = SwitcherView(windows: model.windows, icons: icons)
        v.selectedIndex = model.index
        let screen = NSScreen.main ?? NSScreen.screens.first
        let area = screen?.frame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let size = v.fittingSize
        let frame = NSRect(x: area.midX - size.width / 2, y: area.midY - size.height / 2, width: size.width, height: size.height)
        let p = NSPanel(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        p.level = NSWindow.Level(rawValue: ShellWindowLevels.switcher)
        p.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = true
        p.isReleasedWhenClosed = false
        p.hidesOnDeactivate = false
        p.contentView = v
        p.orderFrontRegardless()
        panel = p
        view = v
    }

    /// Icons show immediately; thumbnails swap in when capture finishes.
    private func loadThumbnails() {
        thumbTask?.cancel()
        let pids = Array(Set(model.windows.map(\.pid)))
        thumbTask = Task { [weak self] in
            for pid in pids {
                guard let self, !Task.isCancelled else { return }
                let entries = await provider.thumbnails(pid: pid, maxWidth: SwitcherView.thumbSize.width * 2)
                guard !Task.isCancelled else { return }
                for e in entries {
                    if let image = e.image { view?.setThumbnail(image, windowID: e.id) }
                }
            }
        }
    }

    private func refresh() {
        guard panel != nil else { return }
        view?.selectedIndex = model.index
    }

    private func close() {
        thumbTask?.cancel(); thumbTask = nil
        panel?.orderOut(nil)
        panel = nil
        view = nil
    }

    private func commit() {
        let target = panel == nil ? nil : model.selected
        close()
        guard let target else { return }
        for ax in service.windows(pid: target.pid) where service.windowID(ax) == target.windowID {
            service.raise(ax)
        }
        NSRunningApplication(processIdentifier: target.pid)?.activate()
    }
}

@MainActor
final class SwitcherView: NSView {
    static let thumbSize = CGSize(width: 88, height: 60)
    private static let cell = CGSize(width: 104, height: 84)
    private static let pad: CGFloat = 14
    private static let titleHeight: CGFloat = 28
    static let iconSize: CGFloat = 48
    private static let font = W7UIFont(12)

    private let windows: [SwitcherWindow]
    private let icons: [NSImage?]
    private var thumbs: [UInt32: CGImage] = [:]
    var selectedIndex = 0 { didSet { needsDisplay = true } }

    init(windows: [SwitcherWindow], icons: [NSImage?]) {
        self.windows = windows
        self.icons = icons
        super.init(frame: .zero)
        frame.size = fittingSize
    }
    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { false }
    override var fittingSize: NSSize {
        NSSize(width: Self.pad * 2 + Self.cell.width * CGFloat(windows.count),
               height: Self.pad * 2 + Self.cell.height + Self.titleHeight)
    }

    func setThumbnail(_ image: CGImage, windowID: UInt32) {
        thumbs[windowID] = image
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        W7DrawGlassFrame(ctx, bounds, true)
        let cellsTop = bounds.height - Self.pad
        for (i, w) in windows.enumerated() {
            let cell = NSRect(x: Self.pad + CGFloat(i) * Self.cell.width, y: cellsTop - Self.cell.height,
                              width: Self.cell.width, height: Self.cell.height)
            if i == selectedIndex {
                NSColor(white: 1, alpha: 0.3).setFill()
                NSBezierPath(roundedRect: cell.insetBy(dx: 2, dy: 2), xRadius: 4, yRadius: 4).fill()
            }
            if let thumb = thumbs[w.windowID] {
                let s = min(Self.thumbSize.width / CGFloat(thumb.width), Self.thumbSize.height / CGFloat(thumb.height))
                let size = NSSize(width: CGFloat(thumb.width) * s, height: CGFloat(thumb.height) * s)
                let r = NSRect(x: cell.midX - size.width / 2, y: cell.midY - size.height / 2, width: size.width, height: size.height)
                NSImage(cgImage: thumb, size: size).draw(in: r)
            } else if let icon = icons[i] {
                let r = NSRect(x: cell.midX - Self.iconSize / 2, y: cell.midY - Self.iconSize / 2,
                               width: Self.iconSize, height: Self.iconSize)
                icon.draw(in: r)
            }
        }
        if let sel = windows.indices.contains(selectedIndex) ? windows[selectedIndex] : nil {
            // Black with the white glow, as title bars draw text on the (now near-opaque, light blue) glass.
            let r = NSRect(x: Self.pad, y: Self.pad - 4, width: bounds.width - Self.pad * 2, height: 18)
            W7DrawGlassText(sel.title, r, Self.font, .center)
        }
    }
}

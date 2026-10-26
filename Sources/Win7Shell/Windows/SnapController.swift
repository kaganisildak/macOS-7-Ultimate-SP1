import AppKit
import ApplicationServices
import Carbon.HIToolbox
import Win7Core
import Win7Theme

/// Aero Snap: drag-to-edge with a preview, plus Ctrl+Option+arrows; Aero Shake detection and the
/// Win+Shift+arrow moves. Inert unless `isEnabled`.
@MainActor
final class SnapController {
    private struct Drag {
        let window: AXUIElement
        let id: UInt32?
        var startFrame: CGRect
        var moving = false
        var lastReadTime = Date.distantPast
        var lastReadCursor = CGPoint(x: -.infinity, y: -.infinity)
        var shake: ShakeDetector
    }

    private static let hotKeyTag = "snap"
    private static let readInterval: TimeInterval = 0.05
    private static let minCursorTravel: CGFloat = 3
    private static let matchTolerance: CGFloat = 2

    private let service: WindowService
    /// The taskbar window's AppKit frame, nil while it is not on screen (the keeper's).
    private let barFrame: () -> NSRect?
    private let preview = SnapPreviewWindow()
    private var memory = SnapMemory()
    /// The frame actually applied after a snap (apps may clamp), used for restore and staleness checks.
    private var applied: [UInt32: CGRect] = [:]
    private var monitor: Any?
    private var screenToken: NSObjectProtocol?
    private weak var hotKeys: HotKeyCenter?
    private var drag: Drag?
    private var pendingTarget: (target: SnapTarget, screenIndex: Int)?
    /// A title-bar drag shook the window: the window and its screen (AX).
    var onShake: ((AXUIElement, CGRect) -> Void)?

    private var primaryHeight: CGFloat = 0
    private var axScreens: [CGRect] = []

    var isEnabled = false {
        didSet {
            guard isEnabled != oldValue else { return }
            if isEnabled { registerHotKeys() } else { endDrag(); hotKeys?.unregisterAll(tag: Self.hotKeyTag) }
        }
    }

    init(service: WindowService, barFrame: @escaping () -> NSRect? = { nil }) {
        self.service = service
        self.barFrame = barFrame
        refreshScreens()
        screenToken = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.refreshScreens() }
        }
    }

    func start(hotKeys: HotKeyCenter) {
        self.hotKeys = hotKeys
        monitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDragged, .leftMouseUp]) { [weak self] event in
            let type = event.type, time = event.timestamp
            MainActor.assumeIsolated { self?.handle(type, time: time) }
        }
        if isEnabled { registerHotKeys() }
    }

    private func registerHotKeys() {
        guard let hotKeys else { return }
        let mods = UInt32(controlKey | optionKey)
        let keys: [(Int, Arrow)] = [(kVK_LeftArrow, .left), (kVK_RightArrow, .right), (kVK_DownArrow, .down), (kVK_UpArrow, .up)]
        for (code, arrow) in keys {
            hotKeys.register(keyCode: UInt32(code), modifiers: mods, tag: Self.hotKeyTag) { [weak self] in self?.keyboard(arrow) }
        }
    }

    // MARK: Geometry helpers

    private func refreshScreens() {
        primaryHeight = NSScreen.screens.first?.frame.height ?? 0
        axScreens = NSScreen.screens.map { Coordinates.ax(fromAppKit: $0.frame, primaryHeight: primaryHeight) }
    }

    private var axCursor: CGPoint {
        let p = NSEvent.mouseLocation
        return CGPoint(x: p.x, y: primaryHeight - p.y)
    }

    /// Exactly the work area the WorkAreaKeeper keeps windows in: on the taskbar's screen
    /// `WorkArea.visible` of the screen's visible frame and the bar, elsewhere the visible frame. So a
    /// snapped or maximized window is never nudged by the keeper. Read now (the menu bar may come and go).
    private func usable(screenIndex: Int) -> CGRect {
        let screens = NSScreen.screens
        guard screens.indices.contains(screenIndex) else { return axScreens[screenIndex] }
        return WorkAreaKeeper.usableArea(of: screens[screenIndex], barAppKit: barFrame()).usable
    }

    private func screenIndex(containing frame: CGRect) -> Int {
        let mid = CGPoint(x: frame.midX, y: frame.midY)
        return axScreens.firstIndex { $0.contains(mid) } ?? 0
    }

    private func matches(_ a: CGRect, _ b: CGRect) -> Bool {
        abs(a.minX - b.minX) <= Self.matchTolerance && abs(a.minY - b.minY) <= Self.matchTolerance
            && abs(a.width - b.width) <= Self.matchTolerance && abs(a.height - b.height) <= Self.matchTolerance
    }

    private func forget(_ id: UInt32) {
        memory.forget(id)
        applied[id] = nil
    }

    // MARK: Dragging

    private func handle(_ type: NSEvent.EventType, time: TimeInterval) {
        guard isEnabled, !axScreens.isEmpty else { return }
        if type == .leftMouseUp { finishDrag() } else { continueDrag(time: time) }
    }

    private func continueDrag(time: TimeInterval) {
        let cursor = axCursor
        if drag == nil {
            guard let window = service.focusedWindow(), let frame = service.frame(window) else { return }
            let id = service.windowID(window)
            // Drop memory the window no longer matches in size (resized by other means).
            if let id, let snapped = applied[id], frame.size != snapped.size { forget(id) }
            drag = Drag(window: window, id: id, startFrame: frame, lastReadTime: Date(), lastReadCursor: cursor,
                        shake: ShakeDetector(startX: cursor.x))
        } else {
            detectShake(cursor: cursor, time: time)
            guard let d = drag,
                  Date().timeIntervalSince(d.lastReadTime) >= Self.readInterval,
                  hypot(cursor.x - d.lastReadCursor.x, cursor.y - d.lastReadCursor.y) > Self.minCursorTravel else { return }
        }
        guard var d = drag, let frame = service.frame(d.window) else { return }
        d.lastReadTime = Date()
        d.lastReadCursor = cursor

        if let id = d.id, memory.current(id) != nil, let original = memory.original(id), let snapped = applied[id],
           SnapGeometry.shouldRestore(snapped: snapped, current: frame) {
            let relX = frame.width > 0 ? (cursor.x - frame.minX) / frame.width : 0.5
            service.setSize(d.window, original.size)
            service.setPosition(d.window, CGPoint(x: cursor.x - relX * original.width, y: frame.minY))
            forget(id)
            d.startFrame = service.frame(d.window) ?? original
            d.moving = true
        } else if !d.moving {
            d.moving = frame.origin != d.startFrame.origin && frame.size == d.startFrame.size
        }
        drag = d
        if d.moving { updatePreview(cursor: cursor) }
    }

    /// Every drag event feeds the detector (no AX call), so the throttled reads don't thin it out.
    private func detectShake(cursor: CGPoint, time: TimeInterval) {
        guard drag?.shake.add(x: cursor.x, time: time) == true, let d = drag, d.moving,
              let frame = service.frame(d.window) else { return }
        onShake?(d.window, axScreens[screenIndex(containing: frame)])
    }

    private func updatePreview(cursor: CGPoint) {
        pendingTarget = SnapGeometry.target(cursor: cursor, screens: axScreens)
        if let t = pendingTarget {
            let ax = SnapGeometry.frame(for: t.target, usable: usable(screenIndex: t.screenIndex))
            preview.show(appKitFrame: Coordinates.appKit(fromAX: ax, primaryHeight: primaryHeight))
        } else {
            preview.hide()
        }
    }

    private func finishDrag() {
        defer { endDrag() }
        guard var d = drag, let frame = service.frame(d.window) else { return }
        // Throttling may have skipped the detection read; decide from a fresh one.
        if !d.moving { d.moving = frame.origin != d.startFrame.origin && frame.size == d.startFrame.size }
        guard d.moving else { return }
        pendingTarget = SnapGeometry.target(cursor: axCursor, screens: axScreens)
        guard let t = pendingTarget else { return }
        apply(t.target, to: d.window, id: d.id, frame: frame, screenIndex: t.screenIndex)
    }

    private func apply(_ target: SnapTarget, to window: AXUIElement, id: UInt32?, frame: CGRect, screenIndex: Int) {
        let snapFrame = SnapGeometry.frame(for: target, usable: usable(screenIndex: screenIndex))
        service.setFrame(window, snapFrame)
        if let id {
            memory.remember(id, frame: frame, snapped: target)
            applied[id] = service.frame(window) ?? snapFrame
        }
    }

    private func endDrag() {
        drag = nil
        pendingTarget = nil
        preview.hide()
    }

    // MARK: Keyboard

    private func keyboard(_ arrow: Arrow) {
        guard isEnabled, let window = service.focusedWindow(), let frame = service.frame(window) else { return }
        let id = service.windowID(window)
        // Stale memory (moved or resized by other means) must not drive the shortcut.
        if let id, let snapped = applied[id], !matches(frame, snapped) { forget(id) }
        let current = id.flatMap { memory.current($0) }
        guard let action = SnapGeometry.keyboardAction(current: current, arrow: arrow) else { return }
        switch action {
        case .snap(let target):
            apply(target, to: window, id: id, frame: frame, screenIndex: screenIndex(containing: frame))
        case .restore:
            if let id, let original = memory.original(id) {
                service.setFrame(window, original)
                forget(id)
            }
        case .minimize:
            service.minimize(window)
        }
    }

    // MARK: Win+Shift+arrows

    /// Win+Shift+Up: the focused window takes its screen's full usable height; x and width stay.
    func verticalMaximize() {
        guard isEnabled, let window = service.focusedWindow(), let frame = service.frame(window) else { return }
        if let id = service.windowID(window) { forget(id) }
        let area = usable(screenIndex: screenIndex(containing: frame))
        service.setFrame(window, WindowMoves.verticallyMaximized(frame, usable: area))
    }

    /// Win+Shift+Left/Right: the focused window moves to the previous/next screen, keeping its
    /// position and size relative to the screen's usable area.
    func moveToNeighborScreen(forward: Bool) {
        guard isEnabled, let window = service.focusedWindow(), let frame = service.frame(window) else { return }
        let from = screenIndex(containing: frame)
        guard let to = WindowMoves.neighborScreen(of: from, screens: axScreens, forward: forward) else { return }
        if let id = service.windowID(window) { forget(id) }
        service.setFrame(window, WindowMoves.frame(frame, movedFrom: usable(screenIndex: from), to: usable(screenIndex: to)))
    }
}

import AppKit
import ApplicationServices
import OSLog
import Win7Core

/// Windows 7's work area: an app window that settles with its bottom under the
/// taskbar is moved up out of the band, or clamped to the visible height when it is taller
/// (`WorkArea.adjusted`). Moves, resizes and new windows are watched through the window service's AX
/// observers; a window is looked at 150 ms after its last change. Changes are coalesced per AX element
/// before any AX call: while a mouse button is down nothing is read at all, the window id is
/// read only once the window settles, and a drag costs no AX calls. A window's existing frame is looked
/// at once; a frame the keeper moved it from is never adjusted again, and a window is moved at most
/// twice per 10 s (`WorkAreaMemory`), so an app that puts its window back is not fought. The windows an
/// app already has are swept once when its observation starts. Fullscreen windows, sheets, panels and
/// the shell's own windows are never moved. On only with Accessibility and without
/// `defaults write com.win7mac.shell W7WorkAreaDisabled -bool YES` (read on every permission poll). After a
/// display mode change `sweepActive()` looks at every observed window once more.
@MainActor
final class WorkAreaKeeper {
    static let disabledKey = "W7WorkAreaDisabled"
    static let settleDelay: TimeInterval = 0.15
    private static let retryDelays: [TimeInterval] = [0.5, 2, 5]
    private static let log = Logger(subsystem: "com.win7mac.shell", category: "workarea")

    static var isSwitchedOff: Bool { UserDefaults.standard.bool(forKey: disabledKey) }

    /// An AX element as a dictionary key: CFHash/CFEqual compare the element locally (no IPC to the app).
    private struct ElementKey: Hashable {
        let element: AXUIElement
        static func == (a: ElementKey, b: ElementKey) -> Bool { CFEqual(a.element, b.element) }
        func hash(into hasher: inout Hasher) { hasher.combine(CFHash(element)) }
    }

    private let service: WindowService
    /// The taskbar window's AppKit frame, nil while it is not on screen.
    private let barFrame: () -> NSRect?
    private var observations: [pid_t: WindowService.WindowObservation] = [:]
    private var pending: [ElementKey: DispatchWorkItem] = [:]
    /// Frames looked at and moved from, and recent moves, per app (`WorkAreaMemory`, capped at 256 windows).
    private var memory: [pid_t: WorkAreaMemory] = [:]
    private var workspaceTokens: [NSObjectProtocol] = []
    /// The running keeper (at most one: AppDelegate's), for the Screen Resolution window's sweep.
    private static weak var active: WorkAreaKeeper?

    var isEnabled = false {
        didSet {
            guard isEnabled != oldValue else { return }
            if isEnabled { start() } else { stop() }
        }
    }

    init(service: WindowService, barFrame: @escaping () -> NSRect?) {
        self.service = service
        self.barFrame = barFrame
    }

    private static var mouseButtonDown: Bool { NSEvent.pressedMouseButtons != 0 }

    private static func isEligible(_ app: NSRunningApplication) -> Bool {
        app.activationPolicy == .regular && app.processIdentifier != getpid() && !app.isTerminated
    }

    /// The usable area of `screen` in AX coordinates, shared by the keeper and Aero Snap: on the
    /// taskbar's screen (the screen its frame intersects, else the primary) `WorkArea.visible` of the
    /// screen's visible frame and the bar, elsewhere the visible frame. Also returns the bar (AX) when
    /// `screen` is the bar's screen.
    static func usableArea(of screen: NSScreen, barAppKit: NSRect?) -> (usable: CGRect, bar: CGRect?) {
        let screens = NSScreen.screens
        let h = screens.first?.frame.height ?? screen.frame.height
        let screenVisible = Coordinates.ax(fromAppKit: screen.visibleFrame, primaryHeight: h)
        guard let barAppKit, let primary = screens.first else { return (screenVisible, nil) }
        let barScreen = screens.first { $0.frame.intersects(barAppKit) } ?? primary
        guard barScreen == screen else { return (screenVisible, nil) }
        let bar = Coordinates.ax(fromAppKit: barAppKit, primaryHeight: h)
        return (SnapGeometry.usableRect(screenVisible: screenVisible, bar: bar), bar)
    }

    // MARK: Observation

    private func start() {
        Self.active = self
        for app in NSWorkspace.shared.runningApplications where Self.isEligible(app) {
            observe(app.processIdentifier, attempt: Self.retryDelays.count)
        }
        let center = NSWorkspace.shared.notificationCenter
        workspaceTokens.append(center.addObserver(
            forName: NSWorkspace.didLaunchApplicationNotification, object: nil, queue: .main
        ) { [weak self] note in
            guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
            // A just-launched app often refuses AX observers until it has finished launching.
            MainActor.assumeIsolated {
                if WorkAreaKeeper.isEligible(app) { self?.observe(app.processIdentifier, attempt: 0) }
            }
        })
        workspaceTokens.append(center.addObserver(
            forName: NSWorkspace.didTerminateApplicationNotification, object: nil, queue: .main
        ) { [weak self] note in
            guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
            let pid = app.processIdentifier
            MainActor.assumeIsolated { self?.forget(pid) }
        })
    }

    private func stop() {
        if Self.active === self { Self.active = nil }
        for token in workspaceTokens { NSWorkspace.shared.notificationCenter.removeObserver(token) }
        workspaceTokens = []
        for o in observations.values { o.invalidate() }
        observations = [:]
        for item in pending.values { item.cancel() }
        pending = [:]
        memory = [:]
    }

    /// `attempt` < `retryDelays.count`: wait that attempt's delay first, and try again later on failure.
    private func observe(_ pid: pid_t, attempt: Int) {
        if attempt < Self.retryDelays.count {
            DispatchQueue.main.asyncAfter(deadline: .now() + Self.retryDelays[attempt]) { [weak self] in
                MainActor.assumeIsolated { self?.tryObserve(pid, attempt: attempt) }
            }
        } else {
            tryObserve(pid, attempt: attempt)
        }
    }

    private func tryObserve(_ pid: pid_t, attempt: Int) {
        guard isEnabled, observations[pid] == nil,
              let app = NSRunningApplication(processIdentifier: pid), !app.isTerminated else { return }
        if let o = service.observeWindowChanges(pid: pid, onChange: { [weak self] window in
            self?.changed(window, pid: pid)
        }) {
            observations[pid] = o
            // Windows that existed before the observer attached (at start, or in the first seconds after a
            // launch) are looked at once too.
            for window in service.windows(pid: pid) { schedule(window, pid: pid) }
        } else if attempt + 1 < Self.retryDelays.count {
            observe(pid, attempt: attempt + 1)
        }
    }

    private func forget(_ pid: pid_t) {
        observations.removeValue(forKey: pid)?.invalidate()
        memory[pid] = nil
    }

    /// The screens changed (a display mode was applied or reverted): the frames looked at are forgotten and every
    /// observed app's windows are looked at again in the new work area (frames moved from and the move limit hold).
    func sweep() {
        guard isEnabled else { return }
        for pid in observations.keys {
            memory[pid]?.forgetLooks()
            for window in service.windows(pid: pid) { schedule(window, pid: pid) }
        }
        Self.log.info("work area: swept \(self.observations.count, privacy: .public) apps after a screen change")
    }

    /// `sweep()` on the running keeper, if the work area is kept at all.
    static func sweepActive() { active?.sweep() }

    // MARK: Settling

    /// No AX call here: the change only (re)arms the element's settle timer.
    private func changed(_ window: AXUIElement, pid: pid_t) {
        guard isEnabled else { return }
        schedule(window, pid: pid)
    }

    private func schedule(_ window: AXUIElement, pid: pid_t) {
        let key = ElementKey(element: window)
        pending[key]?.cancel()
        let item = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated { self?.settle(window, pid: pid) }
        }
        pending[key] = item
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.settleDelay, execute: item)
    }

    private func settle(_ window: AXUIElement, pid: pid_t) {
        pending[ElementKey(element: window)] = nil
        guard isEnabled, observations[pid] != nil else { return }
        // A drag or resize in progress: look again once the button is up; nothing is read during it.
        if Self.mouseButtonDown {
            schedule(window, pid: pid)
            return
        }
        guard let id = service.windowID(window), !service.isMinimized(window), let frame = service.frame(window),
              memory[pid, default: WorkAreaMemory()].shouldLook(id: id, frame: frame) else { return }
        memory[pid, default: WorkAreaMemory()].noteLooked(id: id, frame: frame)
        var flags: WorkAreaFlags = []
        if pid == getpid() { flags.insert(.shellOwned) }
        if !service.isStandard(window) { flags.insert(.sheetOrPanel) }
        if service.isFullscreen(window) { flags.insert(.fullscreen) }
        if Self.mouseButtonDown { flags.insert(.userDragging) }
        guard let (visible, bar) = geometry(),
              let target = WorkArea.adjusted(frame: frame, visible: visible, bar: bar, flags: flags) else { return }
        let now = ProcessInfo.processInfo.systemUptime
        guard memory[pid, default: WorkAreaMemory()].canMove(id: id, now: now) else {
            Self.log.info("work area: window left alone (moved \(WorkAreaMemory.maxMoves, privacy: .public) times in \(WorkAreaMemory.moveWindow, privacy: .public) s)")
            return
        }
        if target.size == frame.size {
            service.setPosition(window, target.origin)
        } else {
            service.setFrame(window, target)
        }
        // What the app made of it; the frame it was moved from is never adjusted again.
        let result = service.frame(window) ?? target
        memory[pid, default: WorkAreaMemory()].noteMoved(id: id, from: frame, to: result, now: now)
        Self.log.info("work area: window moved up \(frame.minY - result.minY, privacy: .public) pt, height \(frame.height, privacy: .public) -> \(result.height, privacy: .public)")
    }

    /// The visible area and the taskbar, in AX coordinates, from the real screen and taskbar frames.
    private func geometry() -> (visible: CGRect, bar: CGRect)? {
        guard let barAppKit = barFrame(), let primary = NSScreen.screens.first else { return nil }
        let screen = NSScreen.screens.first { $0.frame.intersects(barAppKit) } ?? primary
        let area = Self.usableArea(of: screen, barAppKit: barAppKit)
        guard let bar = area.bar else { return nil }
        return (area.usable, bar)
    }
}

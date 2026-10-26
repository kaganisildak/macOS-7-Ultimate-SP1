import AppKit
import Win7Core

/// Registers the Windows-key shortcuts (`Shortcuts`, Win = Control+Option) and runs them. Actions
/// owned by other parts of the shell are closures the AppDelegate wires.
@MainActor
final class WinKeyShortcuts {
    private static let taskbarFocusTag = "taskbarFocus"
    /// Win+T's taskbar focus ends after this long without another Win+T, so Esc is never held for good.
    private static let taskbarFocusTimeout: TimeInterval = 5
    /// Win+L waits up to this long for Control and Option to go up before it locks anyway.
    private static let lockReleaseTimeout: TimeInterval = 1.5
    private static let lockPollInterval: TimeInterval = 0.03

    var isAccessibilityTrusted: () -> Bool = { false }
    /// An action needing Accessibility was used without it.
    var onNeedsAccessibility: () -> Void = {}
    var showDesktop: () -> Void = {}
    var run: () -> Void = {}
    var peekBegin: () -> Void = {}
    var peekEnd: () -> Void = {}
    var taskbar: () -> TaskbarView? = { nil }

    private let hotKeys: HotKeyCenter
    private let service: WindowService
    private let snap: SnapController
    private let minimizer: WindowMinimizer
    private var taskbarFocus: Int?
    private var taskbarFocusTimer: Timer?
    private var lockTimer: Timer?
    private var lockDeadline = Date.distantPast

    init(hotKeys: HotKeyCenter, service: WindowService, snap: SnapController, minimizer: WindowMinimizer) {
        self.hotKeys = hotKeys
        self.service = service
        self.snap = snap
        self.minimizer = minimizer
    }

    /// Hot keys need no permission, so every shortcut is registered; those needing Accessibility
    /// check it when used.
    func start() {
        for shortcut in Shortcuts.all {
            let action = shortcut.action
            let release: (() -> Void)? = action.isHeld ? { [weak self] in self?.release(action) } : nil
            hotKeys.register(shortcut.combo, onRelease: release) { [weak self] in self?.perform(action) }
        }
    }

    private func perform(_ action: ShortcutAction) {
        if action != .focusTaskbar { endTaskbarFocus() }
        if action.needsAccessibility && !isAccessibilityTrusted() {
            onNeedsAccessibility()
            return
        }
        switch action {
        case .showDesktop: showDesktop()
        case .minimizeAll: minimizer.minimizeAll(accessibility: isAccessibilityTrusted())
        case .restoreMinimized: minimizer.restoreAll()
        case .openComputer: NSWorkspace.shared.open(FileManager.default.homeDirectoryForCurrentUser)
        case .lock: lockOnceWinKeysReleased()
        case .run: run()
        case .minimizeOthers:
            if let window = service.focusedWindow() { minimizer.toggleOthers(keeping: window, on: nil) }
        case .peekDesktop: peekBegin()
        case .taskbarButton(let i): taskbar()?.click(buttonAt: i)
        case .focusTaskbar: advanceTaskbarFocus()
        case .verticalMaximize: snap.verticalMaximize()
        case .previousScreen: snap.moveToNeighborScreen(forward: false)
        case .nextScreen: snap.moveToNeighborScreen(forward: true)
        }
    }

    private func release(_ action: ShortcutAction) {
        if action == .peekDesktop { peekEnd() }
    }

    // MARK: Win+L

    /// The hot key fires while Control and Option are still down; a Ctrl+Cmd+Q posted then can pick
    /// up Option and not lock. Poll until they are up (at most `lockReleaseTimeout`), then lock.
    private func lockOnceWinKeysReleased() {
        guard lockTimer == nil else { return }
        lockDeadline = Date().addingTimeInterval(Self.lockReleaseTimeout)
        if lockIfReady() { return }
        lockTimer = Timer.w7Scheduled(Self.lockPollInterval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { _ = self?.lockIfReady() }
        }
    }

    private func lockIfReady() -> Bool {
        let released = ShortcutModifiers.win.isReleased(in: CGEventSource.flagsState(.combinedSessionState))
        guard released || Date() >= lockDeadline else { return false }
        lockTimer?.invalidate()
        lockTimer = nil
        PowerActions.perform(.lock)
        return true
    }

    // MARK: Win+T

    /// The first press focuses the first button, each further press the next, wrapping; Esc ends.
    private func advanceTaskbarFocus() {
        guard let bar = taskbar(), bar.visibleButtonCount > 0 else { return }
        if taskbarFocus == nil {
            hotKeys.register(Shortcuts.escape, tag: Self.taskbarFocusTag) { [weak self] in self?.endTaskbarFocus() }
        }
        let next = taskbarFocus.map { ($0 + 1) % bar.visibleButtonCount } ?? 0
        taskbarFocus = next
        bar.setKeyboardFocus(next)
        taskbarFocusTimer?.invalidate()
        taskbarFocusTimer = Timer.w7Scheduled(Self.taskbarFocusTimeout, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.endTaskbarFocus() }
        }
    }

    private func endTaskbarFocus() {
        guard taskbarFocus != nil else { return }
        taskbarFocus = nil
        taskbarFocusTimer?.invalidate(); taskbarFocusTimer = nil
        hotKeys.unregisterAll(tag: Self.taskbarFocusTag)
        taskbar()?.setKeyboardFocus(nil)
    }
}

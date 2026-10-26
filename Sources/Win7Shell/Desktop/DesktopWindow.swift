import AppKit
import Win7Theme

/// The Windows 7 desktop: one borderless panel on the primary screen at the desktop-icon window level,
/// so every app window, the taskbar and the Start menu sit above it and it only gets clicks that land
/// on bare wallpaper. Transparent, so the wallpaper shows through. Becomes key (without activating the
/// shell) only when clicked, for rename and the keyboard.
@MainActor
final class DesktopWindow: NSPanel {
    static let level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.desktopIconWindow)))

    let desktopView: DesktopView
    private var screenToken: NSObjectProtocol?
    private var reportedScanError = false

    init(store: DesktopStore, actions: DesktopActions) {
        desktopView = DesktopView(store: store, actions: actions)
        super.init(contentRect: DesktopWindow.targetFrame(), styleMask: [.borderless, .nonactivatingPanel],
                   backing: .buffered, defer: false)
        level = DesktopWindow.level
        collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        // Explicitly NO: receive clicks on the transparent areas too (rubber band, empty-space menu).
        ignoresMouseEvents = false
        acceptsMouseMovedEvents = true
        isReleasedWhenClosed = false
        hidesOnDeactivate = false
        contentView = desktopView
        store.onChange = { [weak self, weak store, weak actions] in
            guard let self, let store else { return }
            self.desktopView.reload()
            // Say once why the desktop is empty (e.g. no permission for the Desktop folder).
            if let error = store.scanError {
                if !self.reportedScanError { actions?.showError(error) }
                self.reportedScanError = true
            } else {
                self.reportedScanError = false
            }
        }
        screenToken = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.reframe() }
        }
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    override func becomeKey() {
        super.becomeKey()
        desktopView.keyStateChanged()
    }

    override func resignKey() {
        super.resignKey()
        desktopView.keyStateChanged()
    }

    /// The primary screen minus the taskbar at the bottom and, when it is showing, the menu bar.
    static func targetFrame() -> NSRect {
        guard let screen = NSScreen.screens.first else { return NSRect(x: 0, y: W7TaskbarHeight, width: 1440, height: 860) }
        let f = screen.frame
        let top = min(f.maxY, screen.visibleFrame.maxY)
        return NSRect(x: f.minX, y: f.minY + W7TaskbarHeight, width: f.width, height: max(0, top - f.minY - W7TaskbarHeight))
    }

    private func reframe() { setFrame(DesktopWindow.targetFrame(), display: true) }
}

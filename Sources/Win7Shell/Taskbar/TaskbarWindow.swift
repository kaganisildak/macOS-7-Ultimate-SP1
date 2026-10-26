import AppKit
import Win7Theme

@MainActor
final class TaskbarWindow: NSPanel {
    let taskbarView: TaskbarView
    private var screenToken: NSObjectProtocol?

    init(observer: RunningAppsObserver) {
        taskbarView = TaskbarView(observer: observer)
        super.init(contentRect: TaskbarWindow.targetFrame(), styleMask: [.borderless, .nonactivatingPanel],
                   backing: .buffered, defer: false)
        level = TaskbarLevel.current
        collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        isReleasedWhenClosed = false
        hidesOnDeactivate = false
        allowsToolTipsWhenApplicationIsInactive = true   // tray tooltips while another app is active
        // The taskbar's tint sits on a blur, so what is behind the bar never shows sharply.
        taskbarView.frame = NSRect(origin: .zero, size: frame.size)
        contentView = GlassBlur.host(taskbarView)
        screenToken = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.reframe() }
        }
    }


    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    /// The bottom `W7TaskbarHeight` points of the primary screen.
    static func targetFrame() -> NSRect {
        let f = NSScreen.screens.first?.frame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        return NSRect(x: f.minX, y: f.minY, width: f.width, height: W7TaskbarHeight)
    }

    private func reframe() { setFrame(TaskbarWindow.targetFrame(), display: true) }
}

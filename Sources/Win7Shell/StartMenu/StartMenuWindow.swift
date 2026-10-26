import AppKit
import Win7Core
import Win7Theme

@MainActor
final class StartMenuWindow: NSPanel {
    static let size = NSSize(width: 400, height: 535)
    static let leftPaneWidth: CGFloat = 250

    var onVisibilityChange: ((Bool) -> Void)?
    /// True while one of the menu's popups (power, context menu) tracks, so losing key does not close it.
    var popupActive = false
    private let content = StartMenuContentView(frame: NSRect(origin: .zero, size: StartMenuWindow.size))

    init() {
        super.init(contentRect: NSRect(origin: .zero, size: StartMenuWindow.size), styleMask: [.borderless],
                   backing: .buffered, defer: false)
        level = NSWindow.Level(rawValue: ShellWindowLevels.startMenu)
        collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        isReleasedWhenClosed = false
        hidesOnDeactivate = false
        // The dark glass sits on a blur, clipped to the menu's radius-6 outline.
        contentView = GlassBlur.host(content, cornerRadius: 6)
        content.owner = self
        AppCatalogCache.shared.start()
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    override func resignKey() {
        super.resignKey()
        if !popupActive { close() }
    }

    override func cancelOperation(_ sender: Any?) { close() }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        StandardEditKeys.perform(event) || super.performKeyEquivalent(with: event)
    }

    override func close() {
        guard isVisible else { return }
        content.stop()
        super.close()
        onVisibilityChange?(false)
    }

    func toggle() {
        if isVisible { close() } else { open() }
    }

    func open() {
        guard let screen = NSScreen.screens.first else { return }
        AppCatalogCache.shared.refreshIfStale()
        content.reset()
        setFrameOrigin(NSPoint(x: screen.frame.minX, y: screen.frame.minY + W7TaskbarHeight))
        // The shell is an accessory app: it must be active for the search field to receive typing.
        NSApp.activate()
        makeKeyAndOrderFront(nil)
        content.focusSearch()
        onVisibilityChange?(true)
    }
}

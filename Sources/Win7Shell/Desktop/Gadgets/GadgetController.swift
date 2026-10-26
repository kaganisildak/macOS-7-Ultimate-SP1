import AppKit
import Win7Core

/// The desktop gadgets: which are on the desktop and where (GadgetBoard, persisted in the shell's
/// defaults), their windows, and the gallery that adds them.
@MainActor
final class GadgetController {
    static let boardKey = "desktopGadgets"

    private let defaults: UserDefaults
    private var board: GadgetBoard
    private var windows: [GadgetKind: GadgetWindow] = [:]
    private var gallery: GadgetGallery?
    private var screenToken: NSObjectProtocol?

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        board = GadgetBoard.decode(defaults.data(forKey: Self.boardKey))
    }

    /// The desktop area gadgets stay inside: the main screen above the taskbar and below the menu bar.
    private var area: CGRect { DesktopWindow.targetFrame() }

    /// Shows the gadgets saved last time and keeps them on screen when displays change.
    func start() {
        board.clampAll(in: area)
        save()
        for kind in board.kinds { open(kind) }
        screenToken = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.screensChanged() }
        }
    }

    func showGallery() {
        let g = gallery ?? GadgetGallery { [weak self] kind in self?.add(kind) }
        gallery = g
        g.present()
    }

    /// Adds `kind` to the desktop (one of each; adding one that is there brings it forward).
    func add(_ kind: GadgetKind) {
        if board.add(kind, in: area) {
            save()
            open(kind)
        } else {
            windows[kind]?.orderFrontRegardless()
        }
    }

    func remove(_ kind: GadgetKind) {
        board.remove(kind)
        save()
        if let w = windows.removeValue(forKey: kind) {
            w.content.stop()
            w.orderOut(nil)
        }
    }

    private func open(_ kind: GadgetKind) {
        guard windows[kind] == nil, let frame = board.frame(of: kind) else { return }
        let w = GadgetWindow(kind: kind, content: Self.content(for: kind, preview: false))
        w.onClose = { [weak self] in self?.remove(kind) }
        w.onAddGadgets = { [weak self] in self?.showGallery() }
        w.onMoved = { [weak self, weak w] origin in
            guard let self else { return }
            self.board.move(kind, to: origin, in: self.area)
            self.save()
            if let f = self.board.frame(of: kind) { w?.place(contentOrigin: f.origin) }
        }
        w.place(contentOrigin: frame.origin)
        windows[kind] = w
        w.orderFrontRegardless()
        w.content.start()
    }

    private func screensChanged() {
        board.clampAll(in: area)
        save()
        for (kind, w) in windows { if let f = board.frame(of: kind) { w.place(contentOrigin: f.origin) } }
    }

    private func save() { defaults.set(board.encoded(), forKey: Self.boardKey) }

    /// A gadget's content view. A preview (for the gallery's tiles) runs no timers and never reads ~/Pictures; it
    /// draws with the imported gadget artwork like the gadget itself.
    static func content(for kind: GadgetKind, preview: Bool) -> GadgetContentView {
        let view: GadgetContentView
        switch kind {
        case .clock: view = ClockGadgetView()
        case .calendar: view = CalendarGadgetView()
        case .cpuMeter: view = CPUMeterGadgetView()
        case .slideShow: view = SlideShowGadgetView(preview: preview)
        }
        view.frame = NSRect(origin: .zero, size: kind.size)
        return view
    }
}

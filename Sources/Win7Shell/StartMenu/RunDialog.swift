import AppKit
import Win7ChromeCore
import Win7Core
import Win7Theme

/// The shell has no main menu, so text fields get no Edit-menu shortcuts; its windows route
/// Cmd+X/C/V/A/Z to the first responder themselves.
@MainActor
enum StandardEditKeys {
    static func perform(_ event: NSEvent) -> Bool {
        guard event.type == .keyDown,
              event.modifierFlags.intersection(.deviceIndependentFlagsMask).subtracting(.capsLock) == .command,
              let key = event.charactersIgnoringModifiers?.lowercased() else { return false }
        let action: Selector
        switch key {
        case "x": action = #selector(NSText.cut(_:))
        case "c": action = #selector(NSText.copy(_:))
        case "v": action = #selector(NSText.paste(_:))
        case "a": action = #selector(NSText.selectAll(_:))
        case "z": action = Selector(("undo:"))
        default: return false
        }
        return NSApp.sendAction(action, to: nil, from: nil)
    }
}

/// A Windows 7 dialog body: white over a grey `#F0F0F0` button band with a `#DFDFDF` line, as the Run
/// dialog and message boxes draw it. `icon` draws the 32 pt icon at the top left.
final class DialogBody: NSView {
    var bandHeight: CGFloat = 46
    var icon: ((NSRect) -> Void)?
    var message = ""
    override var isFlipped: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.white.setFill()
        bounds.fill()
        let band = NSRect(x: 0, y: bounds.height - bandHeight, width: bounds.width, height: bandHeight)
        NSColor(srgbRed: 0xF0 / 255, green: 0xF0 / 255, blue: 0xF0 / 255, alpha: 1).setFill()
        band.fill()
        NSColor(srgbRed: 0xDF / 255, green: 0xDF / 255, blue: 0xDF / 255, alpha: 1).setFill()
        NSRect(x: 0, y: band.minY, width: bounds.width, height: 1).fill()
        icon?(NSRect(x: 14, y: 16, width: 32, height: 32))
        let style = NSMutableParagraphStyle()
        style.lineBreakMode = .byWordWrapping
        (message as NSString).draw(in: NSRect(x: 58, y: 16, width: bounds.width - 72, height: band.minY - 24),
                                   withAttributes: [.font: W7UIFont(12), .foregroundColor: NSColor.black, .paragraphStyle: style])
    }
}

/// A small Aero-framed dialog window (the title bar comes from Win7ChromeCore).
@MainActor
class AeroDialog: NSWindow {
    let body = DialogBody()

    init(title: String, size: NSSize) {
        super.init(contentRect: NSRect(origin: .zero, size: size), styleMask: [.titled, .closable],
                   backing: .buffered, defer: false)
        self.title = title
        isReleasedWhenClosed = false
        collectionBehavior = [.moveToActiveSpace]
        body.frame = NSRect(origin: .zero, size: size)
        contentView = body
        W7ChromeController.decorateWindow(self)
        // The shell does not run W7ChromeController.start(), which would redraw title bars on key
        // changes; the dialog watches its own, so its glass switches between active and inactive.
        for name in [NSWindow.didBecomeKeyNotification, NSWindow.didResignKeyNotification] {
            NotificationCenter.default.addObserver(self, selector: #selector(keyChanged(_:)), name: name, object: self)
        }
    }

    @objc private func keyChanged(_ n: Notification) {
        guard let bar = standardWindowButton(.closeButton)?.superview else { return }
        AeroDialog.refreshTitlebars(in: bar)
    }

    private static func refreshTitlebars(in view: NSView) {
        for sub in view.subviews {
            if let bar = sub as? W7TitlebarView { bar.refresh() } else { refreshTitlebars(in: sub) }
        }
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        StandardEditKeys.perform(event) || super.performKeyEquivalent(with: event)
    }

    /// A Windows 7 push button in the grey band; `slot` 0 is the rightmost.
    func bandButton(_ title: String, slot: Int, action: Selector) -> NSButton {
        let b = NSButton(title: title, target: self, action: action)
        b.bezelStyle = .push
        b.font = W7UIFont(12)
        let w: CGFloat = 82, gap: CGFloat = 6
        let x = body.bounds.width - 10 - w - CGFloat(slot) * (w + gap)
        b.frame = NSRect(x: x, y: body.bounds.height - body.bandHeight / 2 - 13, width: w, height: 26)
        body.addSubview(b)
        return b
    }

    /// Bottom left of the main screen, above the taskbar, where Windows 7 opens Run.
    fileprivate func placeAboveStartButton() {
        guard let screen = NSScreen.screens.first else { return }
        setFrameOrigin(NSPoint(x: screen.frame.minX + 12, y: screen.frame.minY + W7TaskbarHeight + 12))
    }
}

/// Windows 7's Run dialog: opens a program by name, a file or folder by path (~ expanded) or a URL.
@MainActor
final class RunDialog: AeroDialog, NSComboBoxDelegate {
    static let shared = RunDialog()
    static let historyKey = "runHistory"

    private let field = NSComboBox()
    private var okButton: NSButton!
    private var history = RunDialog.loadHistory()
    private var errorBox: RunErrorBox?

    private init() {
        super.init(title: "Run", size: NSSize(width: 400, height: 178))
        body.message = "Type the name of a program, folder, document, or Internet resource, and Win7Mac will open it for you."
        body.icon = { r in if !IconOverrides.draw("run", in: r) { RunDialog.drawRunIcon(r) } }
        let label = NSTextField(labelWithString: "Open:")
        label.font = W7UIFont(12)
        label.frame = NSRect(x: 14, y: 84, width: 40, height: 18)
        body.addSubview(label)
        field.font = W7UIFont(12)
        field.frame = NSRect(x: 58, y: 80, width: 328, height: 26)
        field.completes = true
        field.numberOfVisibleItems = 10
        field.delegate = self
        body.addSubview(field)
        _ = bandButton("Browse…", slot: 0, action: #selector(browse(_:)))
        let cancel = bandButton("Cancel", slot: 1, action: #selector(cancel(_:)))
        cancel.keyEquivalent = "\u{1b}"
        okButton = bandButton("OK", slot: 2, action: #selector(confirm(_:)))
        okButton.keyEquivalent = "\r"
    }

    private static func loadHistory() -> RunHistory {
        guard let data = UserDefaults.standard.data(forKey: historyKey),
              let h = try? JSONDecoder().decode(RunHistory.self, from: data) else { return RunHistory() }
        return h
    }

    func present() {
        field.removeAllItems()
        field.addItems(withObjectValues: history.entries)
        // Windows 7 offers the last command again, selected so typing replaces it.
        field.stringValue = history.entries.first ?? ""
        updateOK()
        placeAboveStartButton()
        NSApp.activate()
        makeKeyAndOrderFront(nil)
        makeFirstResponder(field)
        field.currentEditor()?.selectAll(nil)
    }

    override func cancelOperation(_ sender: Any?) { close() }

    private func updateOK() {
        okButton.isEnabled = !field.stringValue.trimmingCharacters(in: .whitespaces).isEmpty
    }

    func controlTextDidChange(_ obj: Notification) { updateOK() }
    func comboBoxSelectionDidChange(_ notification: Notification) {
        DispatchQueue.main.async { MainActor.assumeIsolated { self.updateOK() } }
    }

    @objc private func cancel(_ sender: Any?) { close() }

    @objc private func browse(_ sender: Any?) {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.prompt = "Open"
        panel.beginSheetModal(for: self) { [weak self] response in
            guard response == .OK, let url = panel.url else { return }
            MainActor.assumeIsolated {
                self?.field.stringValue = url.path
                self?.updateOK()
            }
        }
    }

    @objc private func confirm(_ sender: Any?) {
        let text = field.stringValue
        let fm = FileManager.default
        let target = RunResolver.resolve(text, apps: AppCatalogCache.shared.apps, home: fm.homeDirectoryForCurrentUser.path) {
            fm.fileExists(atPath: $0)
        }
        let opened: Bool
        switch target {
        case .empty: return
        case .app(let e):
            // Launching reports failure only in its completion: the dialog stays open until then.
            okButton.isEnabled = false
            NSWorkspace.shared.openApplication(at: URL(fileURLWithPath: e.path),
                                               configuration: NSWorkspace.OpenConfiguration()) { _, error in
                let failed = error != nil
                DispatchQueue.main.async {
                    MainActor.assumeIsolated { RunDialog.shared.finish(text, opened: !failed) }
                }
            }
            return
        case .file(let path): opened = NSWorkspace.shared.open(URL(fileURLWithPath: path))
        case .url(let url): opened = NSWorkspace.shared.open(url)
        case .notFound: opened = false
        }
        finish(text, opened: opened)
    }

    /// Records a command that opened and closes the dialog, or shows the error box for one that did not.
    private func finish(_ text: String, opened: Bool) {
        updateOK()
        guard opened else {
            showError(text.trimmingCharacters(in: .whitespacesAndNewlines))
            return
        }
        history.record(text)
        if let data = try? JSONEncoder().encode(history) { UserDefaults.standard.set(data, forKey: RunDialog.historyKey) }
        close()
    }

    private func showError(_ text: String) {
        let box = RunErrorBox(text: text) { [weak self] in
            guard let self else { return }
            self.makeKeyAndOrderFront(nil)
            self.makeFirstResponder(self.field)
            self.field.currentEditor()?.selectAll(nil)
        }
        errorBox = box
        box.setFrameOrigin(NSPoint(x: frame.midX - box.frame.width / 2, y: frame.midY - box.frame.height / 2))
        box.makeKeyAndOrderFront(nil)
    }

    /// The Run icon: a small window with a blue caption and an arrow pointing into it.
    private static func drawRunIcon(_ r: NSRect) {
        let win = NSRect(x: r.minX + 2, y: r.minY + 4, width: 28, height: 22)
        let frame = NSBezierPath(roundedRect: win, xRadius: 2, yRadius: 2)
        NSColor.white.setFill(); frame.fill()
        NSColor(srgbRed: 0x2B / 255, green: 0x5F / 255, blue: 0xA8 / 255, alpha: 1).setStroke()
        frame.lineWidth = 1.5; frame.stroke()
        NSColor(srgbRed: 0x4A / 255, green: 0x8C / 255, blue: 0xDE / 255, alpha: 1).setFill()
        NSRect(x: win.minX + 1, y: win.minY + 1, width: win.width - 2, height: 6).fill()
        let arrow = NSBezierPath()
        arrow.move(to: NSPoint(x: r.minX + 8, y: r.minY + 22))
        arrow.line(to: NSPoint(x: r.minX + 18, y: r.minY + 14))
        arrow.lineWidth = 2.5
        arrow.lineCapStyle = .round
        NSColor(srgbRed: 0x1E / 255, green: 0x39 / 255, blue: 0x5B / 255, alpha: 1).setStroke()
        arrow.stroke()
        let head = NSBezierPath()
        head.move(to: NSPoint(x: r.minX + 21, y: r.minY + 11))
        head.line(to: NSPoint(x: r.minX + 12, y: r.minY + 12))
        head.line(to: NSPoint(x: r.minX + 20, y: r.minY + 20))
        head.close()
        NSColor(srgbRed: 0x1E / 255, green: 0x39 / 255, blue: 0x5B / 255, alpha: 1).setFill()
        head.fill()
    }
}

/// The Windows 7 message box Run shows for a name it cannot find: the typed text as its title, the
/// red error icon, the message and OK.
@MainActor
final class RunErrorBox: AeroDialog {
    private let onDismiss: () -> Void

    init(text: String, onDismiss: @escaping () -> Void) {
        self.onDismiss = onDismiss
        super.init(title: text, size: NSSize(width: 380, height: 124))
        body.message = RunResolver.notFoundMessage(text)
        body.icon = { r in if !IconOverrides.draw("msgbox-error", in: r) { RunErrorBox.drawErrorIcon(r) } }
        let ok = bandButton("OK", slot: 0, action: #selector(dismiss(_:)))
        ok.keyEquivalent = "\r"
    }

    override func cancelOperation(_ sender: Any?) { dismiss(nil) }

    @objc private func dismiss(_ sender: Any?) {
        close()
        onDismiss()
    }

    /// A red disc with a white ×.
    private static func drawErrorIcon(_ r: NSRect) {
        let disc = NSBezierPath(ovalIn: r.insetBy(dx: 1, dy: 1))
        NSGradient(starting: NSColor(srgbRed: 0xF0 / 255, green: 0x6A / 255, blue: 0x5E / 255, alpha: 1),
                   ending: NSColor(srgbRed: 0xB8 / 255, green: 0x1C / 255, blue: 0x12 / 255, alpha: 1))?
            .draw(in: disc, angle: 90)
        NSColor(srgbRed: 0x8A / 255, green: 0x14 / 255, blue: 0x0C / 255, alpha: 1).setStroke()
        disc.lineWidth = 1
        disc.stroke()
        let x = NSBezierPath()
        let c = NSPoint(x: r.midX, y: r.midY), d: CGFloat = 6.5
        x.move(to: NSPoint(x: c.x - d, y: c.y - d)); x.line(to: NSPoint(x: c.x + d, y: c.y + d))
        x.move(to: NSPoint(x: c.x + d, y: c.y - d)); x.line(to: NSPoint(x: c.x - d, y: c.y + d))
        x.lineWidth = 3
        x.lineCapStyle = .round
        NSColor.white.setStroke()
        x.stroke()
    }
}

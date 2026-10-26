import AppKit
import Carbon.HIToolbox
import Win7ChromeCore
import Win7Core
import Win7Theme

/// The shell's Windows 7 dialog: a small Aero-captioned window owned by a parent window. It is the
/// parent's child window (it moves with it and closes with it), redraws its caption glass on key changes, opens
/// centred on the parent wholly inside that screen's work area (ShellDialogLayout.origin), and has a row of
/// Windows 7 push buttons: Return presses the default one, Esc the cancel one. No taskbar button, no frame
/// autosave. Closing it any other way (Esc, the caption's ×, Alt+F4, Cmd+W, the parent closing) runs the cancel
/// button's action. Two bodies: a message (`message` can change while it is open, e.g. Screen Resolution's
/// "Reverting to previous display settings in N seconds."; the dialog is laid out again and grows to fit) or a
/// custom view (the device Properties sheet).
@MainActor
final class ShellDialog: NSWindow {
    enum Role { case normal, `default`, cancel }

    struct Button {
        var title: String
        var role: Role = .normal
        var action: (() -> Void)?
    }

    /// The open dialogs, kept until they close.
    private static var open: [ShellDialog] = []

    let buttons: [Button]
    private let buttonWidths: [CGFloat]
    private let body: ShellDialogView
    private weak var owner: NSWindow?
    /// The key-state and owner observers, removed when it closes.
    private var observers: [NSObjectProtocol] = []
    private var finished = false

    /// The message body's text. Setting it lays a message box out again (ShellDialogLayout.relayout): the dialog
    /// grows to fit a longer text, keeping its top-left corner, then stays inside the work area; it never shrinks
    /// while open, so a countdown doesn't make it jitter.
    var message: String {
        get { body.message }
        set {
            guard newValue != body.message else { return }
            body.message = newValue
            if body.messageFrames != nil {
                let r = ShellDialogLayout.relayout(textSize: Self.measure(newValue), hasIcon: body.icon != nil,
                                                   buttonWidths: buttonWidths, current: body.frames)
                body.frames = r.frames
                body.messageFrames = r.message
                if r.frames.size != body.frame.size {
                    let top = frame.maxY
                    var f = frameRect(forContentRect: NSRect(origin: .zero, size: r.frames.size))
                    f.origin = NSPoint(x: frame.minX, y: top - f.height)
                    setFrame(f, display: false)
                    body.frame = NSRect(origin: .zero, size: r.frames.size)
                    if isVisible { keepInWorkArea() }
                }
            }
            body.needsDisplay = true
        }
    }

    /// `message` measured in the dialog font, wrapped at ShellDialogLayout.messageTextWidth.
    private static func measure(_ message: String) -> NSSize {
        (message as NSString).boundingRect(
            with: NSSize(width: ShellDialogLayout.messageTextWidth, height: 10_000),
            options: [.usesLineFragmentOrigin, .usesFontLeading], attributes: [.font: ShellDialogView.font]).size
    }

    /// A message box: the message (wrapped at ShellDialogLayout.messageTextWidth), an optional 32 pt icon, the
    /// buttons on the grey strip.
    convenience init(title: String, message: String, icon: NSImage? = nil, buttons: [Button]) {
        let m = ShellDialogLayout.message(textSize: Self.measure(message), hasIcon: icon != nil)
        self.init(title: title, contentSize: m.size, style: .messageBox, buttons: buttons, custom: nil)
        body.message = message
        body.icon = icon
        body.messageFrames = m
    }

    /// A custom body (its frame size is the content size) over the buttons, all on the grey face.
    convenience init(title: String, content: NSView, buttons: [Button]) {
        self.init(title: title, contentSize: content.frame.size, style: .face, buttons: buttons, custom: content)
    }

    private init(title: String, contentSize: NSSize, style: ShellDialogLayout.Style, buttons: [Button], custom: NSView?) {
        self.buttons = buttons
        let font = ShellDialogView.font
        let widths = buttons.map {
            ShellDialogLayout.buttonWidth(titleWidth: ($0.title as NSString).size(withAttributes: [.font: font]).width)
        }
        buttonWidths = widths
        let frames = ShellDialogLayout.layout(content: contentSize, buttonWidths: widths, style: style)
        body = ShellDialogView(frame: NSRect(origin: .zero, size: frames.size), style: style, frames: frames,
                               titles: buttons.map(\.title), defaultIndex: buttons.firstIndex { $0.role == .default })
        super.init(contentRect: NSRect(origin: .zero, size: frames.size), styleMask: [.titled, .closable],
                   backing: .buffered, defer: false)
        self.title = title
        isReleasedWhenClosed = false
        collectionBehavior = [.moveToActiveSpace]
        if let custom {
            custom.frame = frames.content
            custom.autoresizingMask = []
            body.addSubview(custom)
        }
        body.onPress = { [weak self] i in self?.choose(i) }
        contentView = body
        W7ChromeController.decorateWindow(self)
        for name in [NSWindow.didBecomeKeyNotification, NSWindow.didResignKeyNotification] {
            observers.append(NotificationCenter.default.addObserver(forName: name, object: self, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    ShellWindow.refreshTitlebars(of: self)
                    self.body.needsDisplay = true
                }
            })
        }
        ShellWindow.observeScreenChanges()
    }

    // MARK: Showing

    /// Shows the dialog over `parent` (its child window; it closes when the parent closes), or centred on the
    /// main screen's work area without one, and makes it key.
    func present(over parent: NSWindow?) {
        owner = parent
        let size = frame.size
        let area = parent.flatMap { ShellWindowPlacement.area(holding: $0.frame, in: NSScreen.screens.map(ShellWindow.workArea)) }
            ?? (NSScreen.main ?? NSScreen.screens.first).map(ShellWindow.workArea)
        if let area {
            setFrameOrigin(ShellDialogLayout.origin(size: size, parent: parent?.frame, workArea: area))
        }
        Self.open.append(self)
        if let parent {
            parent.addChildWindow(self, ordered: .above)
            observers.append(NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: parent,
                                                                    queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.close() }
            })
        }
        ShellWindowButtons.bringForward(self)
    }

    /// After a screen change: moved back wholly inside the work area it is on (or the main one).
    func keepInWorkArea() {
        let areas = NSScreen.screens.map(ShellWindow.workArea)
        guard let area = ShellWindowPlacement.area(holding: frame, in: areas)
                ?? (NSScreen.main ?? NSScreen.screens.first).map(ShellWindow.workArea) else { return }
        let origin = ShellDialogLayout.origin(size: frame.size, parent: frame, workArea: area)
        if origin != frame.origin { setFrameOrigin(origin) }
    }

    // MARK: Ending

    /// Button `index` was pressed: the dialog closes, then its action runs.
    func choose(_ index: Int) {
        guard !finished, buttons.indices.contains(index) else { return }
        finished = true
        let action = buttons[index].action
        close()
        action?()
    }

    /// Esc: the cancel button, else a plain close (which runs the cancel action, if any).
    override func cancelOperation(_ sender: Any?) {
        if let i = buttons.firstIndex(where: { $0.role == .cancel }) { choose(i) } else { close() }
    }

    override func close() {
        guard Self.open.contains(where: { $0 === self }) || isVisible else { return }
        let cancel = finished ? nil : buttons.first { $0.role == .cancel }?.action
        finished = true
        observers.forEach { NotificationCenter.default.removeObserver($0) }
        observers = []
        owner?.removeChildWindow(self)
        super.close()
        Self.open.removeAll { $0 === self }
        cancel?()
    }

    // MARK: Keyboard

    /// Return and keypad Enter press the default button (without one they pass through to the content), Esc the
    /// cancel one; Alt+F4 and Cmd+W close.
    override func sendEvent(_ event: NSEvent) {
        if event.type == .keyDown {
            let flags = ShellWindow.flags(event)
            switch Int(event.keyCode) {
            case kVK_Return where flags.isEmpty, kVK_ANSI_KeypadEnter where flags.isEmpty:
                if let i = buttons.firstIndex(where: { $0.role == .default }) {
                    choose(i)
                    return
                }
            case kVK_Escape where flags.isEmpty:
                cancelOperation(nil)
                return
            case kVK_F4 where flags == .option || flags == [.control, .option], kVK_ANSI_W where flags == .command:
                performClose(nil)
                return
            default:
                if StandardEditKeys.perform(event) { return }
            }
        }
        super.sendEvent(event)
    }
}

/// The dialog's body: the face or the message box (white over the grey strip with its `#DFDFDF` line), the
/// message and its icon, and the push buttons. Non-flipped.
@MainActor
final class ShellDialogView: NSView {
    static let font = W7UIFont(12)
    var message = ""
    var icon: NSImage?
    var messageFrames: ShellDialogLayout.MessageFrames?
    var onPress: ((Int) -> Void)?
    private let style: ShellDialogLayout.Style
    /// Laid out again when a message box's message changes (ShellDialog.message).
    var frames: ShellDialogLayout.Frames
    private let titles: [String]
    private let defaultIndex: Int?
    private var pressed: Int?
    private var hover: Int?

    init(frame: NSRect, style: ShellDialogLayout.Style, frames: ShellDialogLayout.Frames, titles: [String], defaultIndex: Int?) {
        self.style = style
        self.frames = frames
        self.titles = titles
        self.defaultIndex = defaultIndex
        super.init(frame: frame)
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseMoved, .mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                       owner: self, userInfo: nil))
    }
    required init?(coder: NSCoder) { fatalError() }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override var mouseDownCanMoveWindow: Bool { false }

    private static let face = NSColor(srgbRed: 0xF0 / 255, green: 0xF0 / 255, blue: 0xF0 / 255, alpha: 1)
    private static let stripLine = NSColor(srgbRed: 0xDF / 255, green: 0xDF / 255, blue: 0xDF / 255, alpha: 1)

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        Self.face.setFill()
        bounds.fill()
        if style == .messageBox {
            NSColor.white.setFill()
            frames.content.fill()
            Self.stripLine.setFill()
            NSRect(x: 0, y: frames.strip.maxY - 1, width: bounds.width, height: 1).fill()
            if let m = messageFrames {
                let origin = frames.content.origin
                if let icon, let r = m.icon { icon.draw(in: r.offsetBy(dx: origin.x, dy: origin.y)) }
                let style = NSMutableParagraphStyle()
                style.lineBreakMode = .byWordWrapping
                (message as NSString).draw(with: m.text.offsetBy(dx: origin.x, dy: origin.y),
                                           options: [.usesLineFragmentOrigin, .usesFontLeading],
                                           attributes: [.font: Self.font, .foregroundColor: NSColor.black, .paragraphStyle: style])
            }
        }
        let keyWindow = window?.isKeyWindow ?? false
        for (i, r) in frames.buttons.enumerated() {
            let state: W7ControlState = pressed == i && hover == i ? .pressed : (hover == i && pressed == nil ? .hover : .normal)
            W7DrawPushButton(ctx, r, state, i == defaultIndex && keyWindow)
            let t = titles[i] as NSString
            let size = t.size(withAttributes: [.font: Self.font])
            t.draw(at: NSPoint(x: (r.midX - size.width / 2).rounded(), y: (r.midY - size.height / 2).rounded()),
                   withAttributes: [.font: Self.font, .foregroundColor: NSColor.black])
        }
    }

    private func button(at event: NSEvent) -> Int? {
        let p = convert(event.locationInWindow, from: nil)
        return frames.buttons.firstIndex { $0.contains(p) }
    }

    override func mouseMoved(with event: NSEvent) {
        let b = button(at: event)
        if b != hover { hover = b; needsDisplay = true }
    }

    override func mouseExited(with event: NSEvent) {
        if hover != nil { hover = nil; needsDisplay = true }
    }

    override func mouseDown(with event: NSEvent) {
        pressed = button(at: event)
        hover = pressed
        needsDisplay = true
    }

    override func mouseDragged(with event: NSEvent) {
        let b = button(at: event)
        if b != hover { hover = b; needsDisplay = true }
    }

    override func mouseUp(with event: NSEvent) {
        let hit = button(at: event)
        let was = pressed
        pressed = nil
        needsDisplay = true
        if let hit, hit == was { onPress?(hit) }
    }
}

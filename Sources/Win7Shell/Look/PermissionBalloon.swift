import AppKit
import Win7Core
import Win7Theme

private final class BalloonView: NSView {
    var onClick: () -> Void = {}
    /// The × in the top-right corner; nil draws none.
    var onClose: (() -> Void)?
    let text: String
    /// A bold first line, as Windows 7 tray balloons have.
    let title: String?
    /// Room kept under the text for the button.
    var bottomBand: CGFloat = 0
    init(text: String, title: String? = nil, size: NSSize) {
        self.text = text
        self.title = title
        super.init(frame: NSRect(origin: .zero, size: size))
    }

    static let closeBoxSize: CGFloat = 14
    static var titleFont: NSFont { NSFontManager.shared.convert(W7UIFont(12), toHaveTrait: .boldFontMask) }
    var closeRect: NSRect {
        NSRect(x: bounds.maxX - 6 - Self.closeBoxSize, y: bounds.maxY - 6 - Self.closeBoxSize,
               width: Self.closeBoxSize, height: Self.closeBoxSize)
    }

    /// The "Open System Settings" button, bottom right.
    func addButton(_ title: String) {
        let b = FirstMouseButton(title: title, target: self, action: #selector(buttonPressed(_:)))
        b.bezelStyle = .push
        b.font = W7UIFont(12)
        b.sizeToFit()
        b.frame = NSRect(x: bounds.maxX - b.frame.width - 8, y: 6, width: b.frame.width, height: b.frame.height)
        addSubview(b)
    }

    @objc private func buttonPressed(_ sender: Any?) { onClick() }
    required init?(coder: NSCoder) { fatalError() }

    override func draw(_ dirtyRect: NSRect) {
        let body = NSBezierPath(roundedRect: bounds.insetBy(dx: 1, dy: 1), xRadius: 4, yRadius: 4)
        NSColor(srgbRed: 1, green: 1, blue: 0.88, alpha: 1).setFill()
        body.fill()
        NSColor(srgbRed: 0.46, green: 0.46, blue: 0.46, alpha: 1).setStroke()
        body.lineWidth = 1
        body.stroke()
        let style = NSMutableParagraphStyle()
        style.lineBreakMode = .byWordWrapping
        var textRect = bounds.insetBy(dx: 10, dy: 8)
        textRect.origin.y += bottomBand
        textRect.size.height -= bottomBand
        if let title {
            let attrs: [NSAttributedString.Key: Any] = [.font: BalloonView.titleFont, .foregroundColor: NSColor.black,
                                                        .paragraphStyle: style]
            let width = textRect.width - (onClose == nil ? 0 : Self.closeBoxSize + 4)
            let h = ceil((title as NSString).boundingRect(with: NSSize(width: width, height: 400),
                                                          options: [.usesLineFragmentOrigin], attributes: attrs).height)
            (title as NSString).draw(in: NSRect(x: textRect.minX, y: textRect.maxY - h, width: width, height: h),
                                     withAttributes: attrs)
            textRect.size.height -= h + 4
        }
        (text as NSString).draw(in: textRect, withAttributes: [
            .font: W7UIFont(12), .foregroundColor: NSColor.black, .paragraphStyle: style,
        ])
        if onClose != nil {
            let r = closeRect.insetBy(dx: 3.5, dy: 3.5)
            let cross = NSBezierPath()
            cross.move(to: NSPoint(x: r.minX, y: r.minY))
            cross.line(to: NSPoint(x: r.maxX, y: r.maxY))
            cross.move(to: NSPoint(x: r.minX, y: r.maxY))
            cross.line(to: NSPoint(x: r.maxX, y: r.minY))
            cross.lineWidth = 1.5
            NSColor(srgbRed: 0.35, green: 0.35, blue: 0.35, alpha: 1).setStroke()
            cross.stroke()
        }
    }

    override func mouseDown(with event: NSEvent) {
        if let onClose, closeRect.insetBy(dx: -3, dy: -3).contains(convert(event.locationInWindow, from: nil)) {
            onClose()
        } else {
            onClick()
        }
    }
}

/// The balloon never becomes key, so its button takes the first click.
private final class FirstMouseButton: NSButton {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

/// Win7-style tray balloon shown above the taskbar's notification area. The default is the
/// Accessibility prompt; `init(message:onClick:)` reuses the look for other notices (desktop file errors).
@MainActor
final class PermissionBalloon: NSPanel {
    static let message = "Win7Mac needs the Accessibility permission to close, snap and switch windows. "
        + "In System Settings, Privacy & Security, Accessibility, turn on Win7Shell."
    static let screenCaptureMessage = "Win7Mac needs the Screen Recording permission for taskbar thumbnails and window titles. "
        + "In System Settings, Privacy & Security, Screen Recording, turn on Win7Shell."
    static let settingsURL = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!
    static let screenCaptureSettingsURL = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!
    static let settingsButtonTitle = "Open System Settings"

    convenience init() { self.init(permission: .accessibility) }

    /// What to enable for `permission`, with an "Open System Settings" button for its pane.
    /// Opening the pane grants nothing; the user turns the switch on.
    convenience init(permission: PermissionKind) {
        let url = permission == .accessibility ? PermissionBalloon.settingsURL : PermissionBalloon.screenCaptureSettingsURL
        self.init(message: permission == .accessibility ? PermissionBalloon.message : PermissionBalloon.screenCaptureMessage,
                  button: PermissionBalloon.settingsButtonTitle) { NSWorkspace.shared.open(url) }
    }

    /// `onClick` runs before the balloon dismisses itself, for a click on the balloon or its `button`.
    /// With `onClose` the balloon has a × that dismisses it and runs `onClose` instead; `title` is a
    /// bold first line.
    init(message: String, title: String? = nil, button: String? = nil,
         onClose: (@MainActor () -> Void)? = nil, onClick: @escaping @MainActor () -> Void = {}) {
        var textHeight = (message as NSString).boundingRect(
            with: NSSize(width: 240, height: 400), options: [.usesLineFragmentOrigin],
            attributes: [.font: W7UIFont(12)]).height
        if let title {
            let titleWidth: CGFloat = onClose == nil ? 240 : 240 - BalloonView.closeBoxSize - 4
            textHeight += ceil((title as NSString).boundingRect(
                with: NSSize(width: titleWidth, height: 400), options: [.usesLineFragmentOrigin],
                attributes: [.font: BalloonView.titleFont]).height) + 4
        }
        let buttonBand: CGFloat = button == nil ? 0 : 32
        let size = NSSize(width: 260, height: max(70, ceil(textHeight) + 18 + buttonBand))
        super.init(contentRect: NSRect(origin: .zero, size: size), styleMask: [.borderless, .nonactivatingPanel],
                   backing: .buffered, defer: true)
        level = NSWindow.Level(rawValue: ShellWindowLevels.permissionBalloon)
        collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        isReleasedWhenClosed = false
        hidesOnDeactivate = false
        let view = BalloonView(text: message, title: title, size: size)
        view.onClick = { [weak self] in
            onClick()
            self?.dismiss()
        }
        if let onClose {
            view.onClose = { [weak self] in
                onClose()
                self?.dismiss()
            }
        }
        if let button {
            view.bottomBand = buttonBand
            view.addButton(button)
        }
        contentView = view
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    func present() {
        guard !isVisible, let screen = NSScreen.screens.first else { return }
        // stacked above any balloon already showing, so none covers another.
        var y = screen.frame.minY + W7TaskbarHeight + 6
        for case let other as PermissionBalloon in NSApp.windows where other !== self && other.isVisible {
            y = max(y, other.frame.maxY + 6)
        }
        setFrameOrigin(NSPoint(x: screen.frame.maxX - frame.width - 8, y: y))
        orderFrontRegardless()
    }

    func dismiss() { orderOut(nil) }
}

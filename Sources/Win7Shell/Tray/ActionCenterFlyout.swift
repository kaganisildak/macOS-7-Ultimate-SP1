import AppKit
import Win7Core
import Win7Theme

/// The Windows 7 Action Center flyout: "Solve N problems" (or "No current issues detected"), one row
/// per message with its explanation and a button that runs its action, and "Open Action Center"
/// (Notifications settings) in the footer band.
@MainActor
final class ActionCenterFlyout: NSView {
    static let width: CGFloat = 300
    private static let headerHeight: CGFloat = 40
    private static let rowHeight: CGFloat = 84
    private static let footerHeight: CGFloat = 36
    private static let headerColor = NSColor(srgbRed: 0x1E / 255.0, green: 0x39 / 255.0, blue: 0x5B / 255.0, alpha: 1)

    private let status: ActionCenterStatus
    private let perform: (TrayMenuAction) -> Void
    private var shown: [ActionCenterMessage] = []

    init(status: ActionCenterStatus, perform: @escaping (TrayMenuAction) -> Void) {
        self.status = status
        self.perform = perform
        super.init(frame: NSRect(x: 0, y: 0, width: ActionCenterFlyout.width, height: 0))
        build()
    }
    required init?(coder: NSCoder) { fatalError() }

    static func height(messageCount n: Int) -> CGFloat {
        headerHeight + CGFloat(n) * rowHeight + footerHeight + (n == 0 ? 12 : 4)
    }

    /// Rebuilds the content for the current messages and resizes the open flyout to fit.
    func sync() {
        subviews.forEach { $0.removeFromSuperview() }
        build()
        needsDisplay = true
        (window as? TrayFlyout)?.fitContent()
    }

    private func build() {
        shown = status.messages
        setFrameSize(NSSize(width: ActionCenterFlyout.width, height: ActionCenterFlyout.height(messageCount: shown.count)))

        let header = flyoutLabel(ActionCenterModel.headerText(count: shown.count), size: 13, color: ActionCenterFlyout.headerColor)
        header.setFrameOrigin(NSPoint(x: 12, y: bounds.height - 30))
        addSubview(header)

        var top = bounds.height - ActionCenterFlyout.headerHeight
        for (i, m) in shown.enumerated() {
            let title = flyoutLabel(m.title, bold: true)
            title.setFrameOrigin(NSPoint(x: 40, y: top - 22))
            title.frame.size.width = min(title.frame.width, bounds.width - 52)
            title.lineBreakMode = .byTruncatingTail
            addSubview(title)

            let detail = NSTextField(wrappingLabelWithString: m.detail)
            detail.font = W7UIFont(11)
            detail.textColor = .darkGray
            detail.preferredMaxLayoutWidth = bounds.width - 52
            detail.frame = NSRect(x: 40, y: top - 54, width: bounds.width - 52, height: 30)
            addSubview(detail)

            let button = NSButton(title: m.buttonTitle, target: self, action: #selector(buttonPressed(_:)))
            button.bezelStyle = .push
            button.controlSize = .small
            button.font = W7UIFont(11)
            button.tag = i
            button.sizeToFit()
            button.setFrameOrigin(NSPoint(x: bounds.width - button.frame.width - 10, y: top - ActionCenterFlyout.rowHeight + 4))
            addSubview(button)
            top -= ActionCenterFlyout.rowHeight
        }

        let link = FlyoutLink("Open Action Center") { [perform] in perform(.open(.notifications)) }
        link.setFrameOrigin(NSPoint(x: (bounds.width - link.frame.width) / 2, y: 10))
        addSubview(link)
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        var top = bounds.height - ActionCenterFlyout.headerHeight
        NSColor(srgbRed: 0xE2 / 255.0, green: 0xE3 / 255.0, blue: 0xE3 / 255.0, alpha: 1).setFill()
        for m in shown {
            NSRect(x: 10, y: top, width: bounds.width - 20, height: 1).fill()
            // The message's icon: an empty battery, or the flag with its badge for a permission.
            let icon = NSRect(x: 12, y: top - 26, width: 20, height: 20)
            if m.kind == .batteryLow {
                TrayIcons.draw(ctx, in: icon, kind: .battery, level: 0, flag: false)
            } else {
                TrayIcons.drawActionCenter(ctx, in: icon, alert: true)
            }
            top -= ActionCenterFlyout.rowHeight
        }
        NSColor(srgbRed: 0xF1 / 255.0, green: 0xF5 / 255.0, blue: 0xFB / 255.0, alpha: 1).setFill()
        NSRect(x: 0, y: 0, width: bounds.width, height: ActionCenterFlyout.footerHeight).fill()
        NSColor(srgbRed: 0xCC / 255.0, green: 0xD9 / 255.0, blue: 0xEA / 255.0, alpha: 1).setFill()
        NSRect(x: 0, y: ActionCenterFlyout.footerHeight, width: bounds.width, height: 1).fill()
    }

    @objc private func buttonPressed(_ sender: NSButton) {
        guard shown.indices.contains(sender.tag) else { return }
        perform(shown[sender.tag].action)
    }
}

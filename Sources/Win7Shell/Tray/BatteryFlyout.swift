import AppKit
import Win7Theme

/// The Windows 7 battery flyout: the battery icon, its percent and state, and "More power options"
/// (Battery settings).
@MainActor
final class BatteryFlyout: NSView {
    static let size = NSSize(width: 240, height: 108)
    private let status: BatteryStatus

    init(status: BatteryStatus) {
        self.status = status
        super.init(frame: NSRect(origin: .zero, size: BatteryFlyout.size))
        build()
    }
    required init?(coder: NSCoder) { fatalError() }

    func sync() {
        subviews.forEach { $0.removeFromSuperview() }
        build()
        needsDisplay = true
    }

    private func build() {
        let pct = flyoutLabel("\(status.percent)%", size: 15, bold: true)
        pct.setFrameOrigin(NSPoint(x: 52, y: bounds.height - 34))
        addSubview(pct)
        let state = flyoutLabel(status.tooltip, color: .darkGray)
        state.setFrameOrigin(NSPoint(x: 52, y: bounds.height - 54))
        addSubview(state)
        let link = FlyoutLink("More power options") {
            openSettings(.battery)
        }
        link.setFrameOrigin(NSPoint(x: (bounds.width - link.frame.width) / 2, y: 10))
        addSubview(link)
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        TrayIcons.draw(ctx, in: NSRect(x: 12, y: bounds.height - 52, width: 32, height: 32), kind: .battery,
                       level: status.iconLevel, flag: status.pluggedIn)
        NSColor(srgbRed: 0xF1 / 255.0, green: 0xF5 / 255.0, blue: 0xFB / 255.0, alpha: 1).setFill()
        NSRect(x: 0, y: 0, width: bounds.width, height: 36).fill()
        NSColor(srgbRed: 0xCC / 255.0, green: 0xD9 / 255.0, blue: 0xEA / 255.0, alpha: 1).setFill()
        NSRect(x: 0, y: 36, width: bounds.width, height: 1).fill()
    }
}

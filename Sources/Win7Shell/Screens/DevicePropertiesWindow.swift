import AppKit
import Win7Core
import Win7Theme

/// Windows 7's device Properties dialog, General tab only: the device's icon and name, Device
/// type, Manufacturer, Location, the "Device status" box ("This device is working properly.") and OK / Cancel,
/// which both just close it. A ShellDialog: the parent's child window with the Aero caption, inside the
/// work area; Return and Esc close it. Not an NSAlert; read-only.
@MainActor
enum DevicePropertiesWindow {
    static func present(_ props: DeviceProperties, icon: NSImage, over parent: NSWindow) {
        let sheet = DevicePropertiesView(frame: NSRect(origin: .zero, size: DevicePropertiesView.size), props: props, icon: icon)
        let dialog = ShellDialog(title: props.title, content: sheet,
                                 buttons: [.init(title: "OK", role: .default), .init(title: "Cancel", role: .cancel)])
        dialog.present(over: parent)
    }
}

/// The dialog's General tab, drawn with Win7Theme's tab, group box and text field pieces, above ShellDialog's
/// OK / Cancel row. Non-flipped.
@MainActor
final class DevicePropertiesView: NSView {
    static let size = NSSize(width: 380, height: 356)
    private let props: DeviceProperties
    private let icon: NSImage
    private static let font = W7UIFont(12)

    init(frame: NSRect, props: DeviceProperties, icon: NSImage) {
        self.props = props
        self.icon = icon
        super.init(frame: frame)
    }
    required init?(coder: NSCoder) { fatalError() }

    private var pane: NSRect { NSRect(x: 8, y: 0, width: bounds.width - 16, height: bounds.height - 8 - 22) }

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        NSColor(srgbRed: 0xF0 / 255, green: 0xF0 / 255, blue: 0xF0 / 255, alpha: 1).setFill()
        bounds.fill()
        let p = pane
        W7DrawTabPane(ctx, p)
        let tabW = ceil(("General" as NSString).size(withAttributes: [.font: Self.font]).width) + 16
        let tab = NSRect(x: p.minX + 2 - 2, y: p.maxY - 1, width: tabW + 4, height: 22)
        W7DrawTabItem(ctx, tab, true, false)
        text("General", at: NSPoint(x: tab.minX + 10, y: tab.minY + 4))

        // Icon and name.
        let top = p.maxY - 16
        icon.draw(in: NSRect(x: p.minX + 14, y: top - 32, width: 32, height: 32))
        text(props.name, at: NSPoint(x: p.minX + 62, y: top - 23), width: p.width - 76)
        // The etched line under them.
        NSColor(srgbRed: 0xA0 / 255, green: 0xA0 / 255, blue: 0xA0 / 255, alpha: 1).setFill()
        NSRect(x: p.minX + 14, y: top - 46, width: p.width - 28, height: 1).fill()
        NSColor.white.setFill()
        NSRect(x: p.minX + 14, y: top - 47, width: p.width - 28, height: 1).fill()

        let rows = [("Device type:", props.deviceType), ("Manufacturer:", props.manufacturer), ("Location:", props.location)]
        for (i, row) in rows.enumerated() {
            let y = top - 72 - CGFloat(i) * 22
            text(row.0, at: NSPoint(x: p.minX + 62, y: y))
            text(row.1, at: NSPoint(x: p.minX + 150, y: y), width: p.width - 164)
        }

        // Device status.
        let titleWidth = ceil(("Device status" as NSString).size(withAttributes: [.font: Self.font]).width)
        let box = NSRect(x: p.minX + 14, y: p.minY + 16, width: p.width - 28, height: top - 150 - (p.minY + 16))
        W7DrawGroupBox(ctx, box, titleWidth)
        text("Device status", at: NSPoint(x: box.minX + 8, y: box.maxY - 8))
        let field = box.insetBy(dx: 10, dy: 12).offsetBy(dx: 0, dy: -4)
        W7DrawTextFieldBox(ctx, field, false, true)
        text(DeviceProperties.status, at: NSPoint(x: field.minX + 5, y: field.maxY - 20), width: field.width - 10)
    }

    private func text(_ s: String, at p: NSPoint, width: CGFloat = 400) {
        let style = NSMutableParagraphStyle()
        style.lineBreakMode = .byTruncatingTail
        let h = ceil((s as NSString).size(withAttributes: [.font: Self.font]).height)
        (s as NSString).draw(in: NSRect(x: p.x, y: p.y, width: max(0, width), height: h),
                             withAttributes: [.font: Self.font, .foregroundColor: NSColor.black, .paragraphStyle: style])
    }
}

import AppKit
import CoreLocation
import Win7Core
import Win7Theme

/// The Windows 7 network flyout: "Currently connected to:" with the network and its icon (or "Not
/// connected" and whether anything can be joined), a "Show network name" button while Location has
/// not been asked, the visible Wi-Fi networks with their signal bars while Wi-Fi is on, and "Open
/// Network and Sharing Center" (Network settings) in the footer band.
@MainActor
final class NetworkFlyout: NSView {
    static let width: CGFloat = 300
    private static let statusHeight: CGFloat = 80
    private static let noteHeight: CGFloat = 32
    private static let sectionHeight: CGFloat = 26
    private static let footerHeight: CGFloat = 36
    /// Rows shown before the list scrolls.
    private static let visibleRows = 7

    private let status: NetworkStatus
    private var rows: [NetworkListRow] = []

    init(status: NetworkStatus) {
        self.status = status
        super.init(frame: NSRect(x: 0, y: 0, width: NetworkFlyout.width, height: 0))
        build()
    }
    required init?(coder: NSCoder) { fatalError() }

    /// Rebuilds the content (called when the network or the Location grant changes) and resizes the
    /// open flyout to fit.
    func sync() {
        subviews.forEach { $0.removeFromSuperview() }
        build()
        needsDisplay = true
        (window as? TrayFlyout)?.fitContent()
    }

    private var connectedName: String? {
        switch status.kind {
        case .wifi: status.ssid ?? "Wi-Fi network"
        case .wired: "Ethernet"
        case .disconnected, .noInterface: nil
        }
    }

    private enum Note { case none, showNameButton, allowLocation }

    private var note: Note {
        guard case .wifi = status.kind, status.ssid == nil else { return .none }
        return status.locationStatus == .notDetermined ? .showNameButton : .allowLocation
    }

    private var listHeight: CGFloat {
        rows.isEmpty ? 0 : CGFloat(min(rows.count, NetworkFlyout.visibleRows)) * NetworkRowView.height + 4
    }

    private func build() {
        rows = status.networkRows
        let note = self.note
        let height = NetworkFlyout.statusHeight + (note == .none ? 0 : NetworkFlyout.noteHeight)
            + (rows.isEmpty ? 0 : NetworkFlyout.sectionHeight + listHeight) + NetworkFlyout.footerHeight + 8
        setFrameSize(NSSize(width: NetworkFlyout.width, height: height))

        let connected = connectedName
        let lines = NetworkListModel.headerLines(connectedName: connected, networksAvailable: !rows.isEmpty)
        let header = flyoutLabel(lines.header, color: .darkGray)
        header.setFrameOrigin(NSPoint(x: 12, y: bounds.height - 28))
        addSubview(header)

        let name = flyoutLabel(lines.detail, bold: connected != nil)
        name.setFrameOrigin(NSPoint(x: 40, y: bounds.height - 56))
        name.frame.size.width = min(name.frame.width, bounds.width - 52)
        name.lineBreakMode = .byTruncatingTail
        addSubview(name)
        if connected != nil {
            let access = flyoutLabel("Internet access", size: 11, color: .darkGray)
            access.setFrameOrigin(NSPoint(x: 40, y: bounds.height - 72))
            addSubview(access)
        }

        var top = bounds.height - NetworkFlyout.statusHeight
        switch note {
        case .none: break
        case .showNameButton:
            let button = NSButton(title: "Show network name", target: self, action: #selector(showName))
            button.bezelStyle = .push
            button.font = W7UIFont(12)
            button.sizeToFit()
            button.setFrameOrigin(NSPoint(x: 36, y: top - NetworkFlyout.noteHeight + 2))
            addSubview(button)
        case .allowLocation:
            let text = flyoutLabel("Allow Location for Win7Shell to see the name.", size: 11, color: .darkGray)
            text.setFrameOrigin(NSPoint(x: 40, y: top - NetworkFlyout.noteHeight + 8))
            addSubview(text)
        }
        if note != .none { top -= NetworkFlyout.noteHeight }

        if !rows.isEmpty {
            let section = flyoutLabel("Wi-Fi", color: NSColor(srgbRed: 0x1E / 255.0, green: 0x39 / 255.0, blue: 0x5B / 255.0, alpha: 1))
            section.setFrameOrigin(NSPoint(x: 12, y: top - 20))
            addSubview(section)
            top -= NetworkFlyout.sectionHeight
            addSubview(listView(frame: NSRect(x: 4, y: top - listHeight, width: bounds.width - 8, height: listHeight)))
        }

        let center = FlyoutLink("Open Network and Sharing Center") { openSettings(.network) }
        center.setFrameOrigin(NSPoint(x: (bounds.width - center.frame.width) / 2, y: 10))
        addSubview(center)
    }

    /// The rows, top to bottom, in a scroll view that scrolls past `visibleRows`.
    private func listView(frame: NSRect) -> NSView {
        let rowH = NetworkRowView.height
        let doc = FlippedView(frame: NSRect(x: 0, y: 0, width: frame.width, height: CGFloat(rows.count) * rowH + 4))
        for (i, row) in rows.enumerated() {
            let v = NetworkRowView(row: row, frame: NSRect(x: 0, y: 2 + CGFloat(i) * rowH, width: frame.width, height: rowH))
            v.onClick = { row in
                if let pane = NetworkListModel.clickAction(row) { openSettings(pane) }
            }
            doc.addSubview(v)
        }
        let scroll = NSScrollView(frame: frame)
        scroll.drawsBackground = false
        scroll.borderType = .noBorder
        scroll.hasVerticalScroller = rows.count > NetworkFlyout.visibleRows
        scroll.autohidesScrollers = true
        scroll.documentView = doc
        return scroll
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        let (kind, level) = status.icon
        TrayIcons.draw(ctx, in: NSRect(x: 12, y: bounds.height - 60, width: 22, height: 22), kind: kind, level: level, flag: false)
        if !rows.isEmpty {
            // A groove over the Wi-Fi section.
            let y = bounds.height - NetworkFlyout.statusHeight - (note == .none ? 0 : NetworkFlyout.noteHeight)
            NSColor(srgbRed: 0xE2 / 255.0, green: 0xE3 / 255.0, blue: 0xE3 / 255.0, alpha: 1).setFill()
            NSRect(x: 10, y: y, width: bounds.width - 20, height: 1).fill()
        }
        NSColor(srgbRed: 0xF1 / 255.0, green: 0xF5 / 255.0, blue: 0xFB / 255.0, alpha: 1).setFill()
        NSRect(x: 0, y: 0, width: bounds.width, height: NetworkFlyout.footerHeight).fill()
        NSColor(srgbRed: 0xCC / 255.0, green: 0xD9 / 255.0, blue: 0xEA / 255.0, alpha: 1).setFill()
        NSRect(x: 0, y: NetworkFlyout.footerHeight, width: bounds.width, height: 1).fill()
    }

    @objc private func showName() {
        status.requestNetworkName()
    }
}

private final class FlippedView: NSView {
    override var isFlipped: Bool { true }
}

/// One network in the list: its name ("Connected" beside the current one) and Windows 7 signal
/// bars, with the Explorer hover highlight (`#E5F3FB`, border `#70C0E7`).
@MainActor
private final class NetworkRowView: NSView {
    static let height: CGFloat = 26
    var onClick: ((NetworkListRow) -> Void)?
    private let row: NetworkListRow
    private var hover = false

    init(row: NetworkListRow, frame: NSRect) {
        self.row = row
        super.init(frame: frame)
    }
    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        if hover && !row.isCurrent {
            let path = NSBezierPath(roundedRect: bounds.insetBy(dx: 4.5, dy: 1.5), xRadius: 2, yRadius: 2)
            NSColor(srgbRed: 0xE5 / 255.0, green: 0xF3 / 255.0, blue: 0xFB / 255.0, alpha: 1).setFill()
            path.fill()
            NSColor(srgbRed: 0x70 / 255.0, green: 0xC0 / 255.0, blue: 0xE7 / 255.0, alpha: 1).setStroke()
            path.stroke()
        }
        let font = W7UIFont(12)
        let textY = (bounds.height - ceil(font.ascender - font.descender)) / 2
        var textRight = bounds.width - 12
        if case .network = row {
            // CoreGraphics bars want a bottom-up context: flip back for them.
            let bars = NSRect(x: bounds.width - 32, y: 6, width: 20, height: 14)
            ctx.saveGState()
            ctx.translateBy(x: 0, y: bounds.height)
            ctx.scaleBy(x: 1, y: -1)
            W7DrawSignalBars(ctx, CGRect(x: bars.minX, y: bounds.height - bars.maxY, width: bars.width, height: bars.height), row.bars)
            ctx.restoreGState()
            textRight = bars.minX - 8
        }
        if row.isCurrent {
            let attrs: [NSAttributedString.Key: Any] = [.font: W7UIFont(11), .foregroundColor: NSColor.darkGray]
            let w = ceil(("Connected" as NSString).size(withAttributes: attrs).width)
            ("Connected" as NSString).draw(at: NSPoint(x: textRight - w, y: textY + 1), withAttributes: attrs)
            textRight -= w + 8
        }
        let para = NSMutableParagraphStyle()
        para.lineBreakMode = .byTruncatingTail
        let color: NSColor = if case .summary = row { .darkGray } else { .black }
        (row.name as NSString).draw(in: NSRect(x: 14, y: textY, width: max(0, textRight - 14), height: bounds.height - textY),
                                    withAttributes: [.font: font, .foregroundColor: color, .paragraphStyle: para])
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        for a in trackingAreas { removeTrackingArea(a) }
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                       owner: self, userInfo: nil))
    }
    override func mouseEntered(with event: NSEvent) { hover = true; needsDisplay = true }
    override func mouseExited(with event: NSEvent) { hover = false; needsDisplay = true }
    override func mouseDown(with event: NSEvent) {}
    override func mouseUp(with event: NSEvent) {
        if bounds.contains(convert(event.locationInWindow, from: nil)) { onClick?(row) }
    }
}

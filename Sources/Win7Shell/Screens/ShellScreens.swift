import AppKit
import Win7ChromeCore
import Win7Core
import Win7Theme

/// Opens the shell's own windows by target: Control Panel links, the Start menu, Help links, the desktop's Personalize
/// and Screen resolution.
@MainActor
enum ShellScreens {
    static func open(_ target: ShellWindowTarget) {
        ShellWindowButtons.log.info("shell window \(target.identifier, privacy: .public) requested")
        switch target {
        case .deviceManager: DeviceManagerWindow.shared.show()
        case .devicesAndPrinters: DevicesAndPrintersWindow.shared.show()
        case .help: HelpWindow.shared.show()
        case .calculator: CalculatorWindow.shared.show()
        case .personalization: PersonalizationWindow.shared.show()
        case .desktopBackground: DesktopBackgroundWindow.shared.show()
        case .screenResolution: ScreenResolutionWindow.shared.show()
        }
    }
}

/// Device icons: the user's imported `dev-<name>.png`, then an older name with the same Windows 7 picture, then a
/// drawn navigation-pane glyph (the application badge for most). No artwork of its own.
@MainActor
enum DeviceIcons {
    static func image(_ kind: DeviceKind, side: CGFloat) -> NSImage {
        ControlPanelIcons.image(names: [kind.iconName] + (kind.sharedIconName.map { [$0] } ?? []), glyph: glyph(kind), side: side)
    }

    private static func glyph(_ kind: DeviceKind) -> ControlPanelIcons.Glyph {
        switch kind {
        case .computer: .nav(.computer)
        case .diskDrives: .nav(.drive)
        case .networkAdapters: .nav(.network)
        default: .nav(.appBadge)
        }
    }

    /// Device Manager's window and taskbar icon.
    static func deviceManagerWindow(side: CGFloat) -> NSImage { image(.computer, side: side) }

    /// Devices and Printers' window and taskbar icon: the Control Panel item's.
    static func devicesAndPrintersWindow(side: CGFloat) -> NSImage {
        ControlPanelIcons.image(names: ["cp-devices-printers", "devices"], glyph: .nav(.computer), side: side)
    }
}

/// A Windows 7 menu strip ("File  Action  View  Help") along the top of a shell window's content, for the shell's
/// own windows (it has no main menu for W7MenuStripController to read). Each title opens its menu in W7MenuWindow
/// (ShellMenus) under the title. Non-flipped.
@MainActor
final class ShellMenuStripView: NSView {
    struct Entry {
        var title: String
        var menu: () -> NSMenu
    }

    var entries: [Entry] = [] { didSet { needsDisplay = true } }
    private var open: Int?
    private var hover: Int?
    private static let font = W7UIFont(12)

    override init(frame: NSRect) {
        super.init(frame: frame)
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseMoved, .mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                       owner: self, userInfo: nil))
    }
    required init?(coder: NSCoder) { fatalError() }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override var mouseDownCanMoveWindow: Bool { false }

    private var titleRects: [NSRect] {
        W7MenuStripTitleRects(entries.map(\.title), Self.font, bounds.height).map { $0.rectValue.offsetBy(dx: 2, dy: 0) }
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        W7DrawMenuStripBackground(ctx, bounds)
        for (i, r) in titleRects.enumerated() {
            if i == open || (open == nil && i == hover) { W7DrawMenuHighlight(ctx, r.insetBy(dx: 0, dy: 1)) }
            let title = entries[i].title as NSString
            let size = title.size(withAttributes: [.font: Self.font])
            title.draw(at: NSPoint(x: r.midX - size.width / 2, y: r.midY - size.height / 2),
                       withAttributes: [.font: Self.font, .foregroundColor: NSColor.black])
        }
    }

    private func index(at event: NSEvent) -> Int? {
        let p = convert(event.locationInWindow, from: nil)
        return titleRects.firstIndex { $0.contains(p) }
    }

    override func mouseMoved(with event: NSEvent) {
        let i = index(at: event)
        if i != hover { hover = i; needsDisplay = true }
    }

    override func mouseExited(with event: NSEvent) {
        if hover != nil { hover = nil; needsDisplay = true }
    }

    override func mouseDown(with event: NSEvent) {
        guard let i = index(at: event) else { return }
        popUp(i)
    }

    /// Shows menu `i` under its title; returns after the menu closes (and its chosen action ran).
    func popUp(_ i: Int) {
        guard entries.indices.contains(i), let window else { return }
        let r = titleRects[i]
        let bottomLeft = window.convertPoint(toScreen: convert(NSPoint(x: r.minX, y: r.minY), to: nil))
        open = i
        display()
        ShellMenus.show(entries[i].menu(), at: bottomLeft)
        open = nil
        hover = nil
        needsDisplay = true
    }
}

/// A small Windows 7 toolbar glyph, drawn (16 pt, non-flipped context).
enum ToolbarGlyph {
    case back, forward, properties, update, uninstall, scan

    func draw(_ ctx: CGContext, _ r: CGRect) {
        let blue = CGColor(srgbRed: 0x2A / 255, green: 0x6C / 255, blue: 0xC4 / 255, alpha: 1)
        ctx.saveGState()
        defer { ctx.restoreGState() }
        switch self {
        case .back, .forward:
            let dir: CGFloat = self == .back ? -1 : 1
            let c = CGPoint(x: r.midX, y: r.midY)
            let path = CGMutablePath()
            path.move(to: CGPoint(x: c.x + dir * 6, y: c.y))
            path.addLine(to: CGPoint(x: c.x + dir * 0.5, y: c.y + 5.5))
            path.addLine(to: CGPoint(x: c.x + dir * 0.5, y: c.y + 2.2))
            path.addLine(to: CGPoint(x: c.x - dir * 6, y: c.y + 2.2))
            path.addLine(to: CGPoint(x: c.x - dir * 6, y: c.y - 2.2))
            path.addLine(to: CGPoint(x: c.x + dir * 0.5, y: c.y - 2.2))
            path.addLine(to: CGPoint(x: c.x + dir * 0.5, y: c.y - 5.5))
            path.closeSubpath()
            ctx.addPath(path)
            ctx.setFillColor(blue)
            ctx.fillPath()
        case .properties, .update, .uninstall:
            Self.sheet(ctx, CGRect(x: r.minX + 2.5, y: r.minY + 1.5, width: 10, height: 13))
            if self == .update {
                ctx.setFillColor(CGColor(srgbRed: 0x2E / 255, green: 0x9E / 255, blue: 0x3A / 255, alpha: 1))
                let p = CGMutablePath()
                let x = r.maxX - 4.5, y = r.minY + 1
                p.move(to: CGPoint(x: x, y: y + 9)); p.addLine(to: CGPoint(x: x + 4, y: y + 4.5))
                p.addLine(to: CGPoint(x: x + 1.5, y: y + 4.5)); p.addLine(to: CGPoint(x: x + 1.5, y: y))
                p.addLine(to: CGPoint(x: x - 1.5, y: y)); p.addLine(to: CGPoint(x: x - 1.5, y: y + 4.5))
                p.addLine(to: CGPoint(x: x - 4, y: y + 4.5)); p.closeSubpath()
                ctx.addPath(p); ctx.fillPath()
            } else if self == .uninstall {
                ctx.setStrokeColor(CGColor(srgbRed: 0xD3 / 255, green: 0x2F / 255, blue: 0x2F / 255, alpha: 1))
                ctx.setLineWidth(2)
                ctx.setLineCap(.round)
                let c = CGPoint(x: r.maxX - 4.5, y: r.minY + 4.5)
                ctx.move(to: CGPoint(x: c.x - 3, y: c.y - 3)); ctx.addLine(to: CGPoint(x: c.x + 3, y: c.y + 3))
                ctx.move(to: CGPoint(x: c.x - 3, y: c.y + 3)); ctx.addLine(to: CGPoint(x: c.x + 3, y: c.y - 3))
                ctx.strokePath()
            }
        case .scan:
            // A monitor with a magnifier.
            let screen = CGRect(x: r.minX + 1, y: r.minY + 5, width: 11, height: 8.5)
            ctx.setFillColor(CGColor(srgbRed: 0x6F / 255, green: 0xA8 / 255, blue: 0xE0 / 255, alpha: 1))
            ctx.fill(screen)
            ctx.setStrokeColor(CGColor(gray: 0.3, alpha: 1))
            ctx.setLineWidth(1)
            ctx.stroke(screen.insetBy(dx: 0.5, dy: 0.5))
            ctx.fill(CGRect(x: r.minX + 4, y: r.minY + 2.5, width: 5, height: 1.5))
            let lens = CGRect(x: r.maxX - 8, y: r.minY + 2, width: 6, height: 6)
            ctx.setFillColor(CGColor(gray: 1, alpha: 0.85))
            ctx.fillEllipse(in: lens)
            ctx.setStrokeColor(CGColor(gray: 0.2, alpha: 1))
            ctx.setLineWidth(1.4)
            ctx.strokeEllipse(in: lens)
            ctx.move(to: CGPoint(x: lens.minX + 0.8, y: lens.minY + 0.8))
            ctx.addLine(to: CGPoint(x: lens.minX - 1.5, y: lens.minY - 1.5))
            ctx.strokePath()
        }
    }

    /// A white sheet with a folded corner and three text lines.
    private static func sheet(_ ctx: CGContext, _ s: CGRect) {
        let p = CGMutablePath()
        p.move(to: CGPoint(x: s.minX, y: s.minY)); p.addLine(to: CGPoint(x: s.maxX, y: s.minY))
        p.addLine(to: CGPoint(x: s.maxX, y: s.maxY - 3)); p.addLine(to: CGPoint(x: s.maxX - 3, y: s.maxY))
        p.addLine(to: CGPoint(x: s.minX, y: s.maxY)); p.closeSubpath()
        ctx.addPath(p)
        ctx.setFillColor(CGColor(gray: 1, alpha: 1))
        ctx.fillPath()
        ctx.addPath(p)
        ctx.setStrokeColor(CGColor(gray: 0.45, alpha: 1))
        ctx.setLineWidth(1)
        ctx.strokePath()
        ctx.setFillColor(CGColor(srgbRed: 0x7A / 255, green: 0x96 / 255, blue: 0xB8 / 255, alpha: 1))
        for i in 0..<3 { ctx.fill(CGRect(x: s.minX + 2, y: s.maxY - 5 - CGFloat(i) * 2.5, width: s.width - 4.5, height: 1)) }
    }
}

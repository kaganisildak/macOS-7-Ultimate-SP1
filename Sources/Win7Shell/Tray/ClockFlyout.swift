import AppKit
import Win7Core
import Win7Theme

/// The Windows 7 clock flyout: the long date on top, a month calendar on the left, an analog clock
/// on the right and "Change date and time settings…" at the bottom.
@MainActor
final class ClockFlyout: NSView {
    static let size = NSSize(width: 380, height: 270)

    init() {
        super.init(frame: NSRect(origin: .zero, size: ClockFlyout.size))
        let header = FlyoutLink(ClockFlyout.longDate(Date())) {
            openSettings(.dateTime)
        }
        header.setFrameOrigin(NSPoint(x: 12, y: bounds.height - 28))
        addSubview(header)

        let calendar = CalendarView(frame: NSRect(x: 10, y: 42, width: 7 * CalendarView.cell + 8, height: 190))
        addSubview(calendar)

        let face = AnalogClockView(frame: NSRect(x: bounds.width - 100 - 26, y: 92, width: 100, height: 100))
        addSubview(face)
        let time = ClockTimeLabel(frame: NSRect(x: face.frame.minX - 20, y: 64, width: 140, height: 20))
        addSubview(time)

        let link = FlyoutLink("Change date and time settings…") {
            openSettings(.dateTime)
        }
        link.setFrameOrigin(NSPoint(x: (bounds.width - link.frame.width) / 2, y: 10))
        addSubview(link)
    }
    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { false }

    override func draw(_ dirtyRect: NSRect) {
        // A light band behind the footer link, as in Windows 7.
        NSColor(srgbRed: 0xF1 / 255.0, green: 0xF5 / 255.0, blue: 0xFB / 255.0, alpha: 1).setFill()
        NSRect(x: 0, y: 0, width: bounds.width, height: 36).fill()
        NSColor(srgbRed: 0xCC / 255.0, green: 0xD9 / 255.0, blue: 0xEA / 255.0, alpha: 1).setFill()
        NSRect(x: 0, y: 36, width: bounds.width, height: 1).fill()
    }

    static func longDate(_ date: Date) -> String {
        let f = DateFormatter()
        f.locale = .autoupdatingCurrent
        f.dateStyle = .full
        f.timeStyle = .none
        return f.string(from: date)
    }
}

/// The month calendar: ‹ Month Year ›, weekday initials and the `TrayLogic.monthGrid` days, with
/// today highlighted in #CCE8FF with a #99D1FF border.
@MainActor
private final class CalendarView: NSView {
    static let cell: CGFloat = 26
    private var year: Int
    private var month: Int
    private let calendar = Calendar.autoupdatingCurrent
    private static let font = W7UIFont(12)
    private static let headerFont = W7UIFont(13)

    override init(frame: NSRect) {
        let now = Calendar.autoupdatingCurrent.dateComponents([.year, .month], from: Date())
        year = now.year ?? 2026
        month = now.month ?? 1
        super.init(frame: frame)
    }
    required init?(coder: NSCoder) { fatalError() }

    private var gridLeft: CGFloat { 4 }
    private var headerRect: NSRect { NSRect(x: 0, y: bounds.height - 26, width: bounds.width, height: 24) }
    private var prevRect: NSRect { NSRect(x: 2, y: headerRect.minY, width: 24, height: 24) }
    private var nextRect: NSRect { NSRect(x: bounds.width - 26, y: headerRect.minY, width: 24, height: 24) }

    override func draw(_ dirtyRect: NSRect) {
        let center = NSMutableParagraphStyle()
        center.alignment = .center
        let blue = NSColor(srgbRed: 0x1E / 255.0, green: 0x39 / 255.0, blue: 0x87 / 255.0, alpha: 1)
        let monthDate = calendar.date(from: DateComponents(year: year, month: month, day: 1)) ?? Date()
        let mf = DateFormatter()
        mf.locale = .autoupdatingCurrent
        mf.setLocalizedDateFormatFromTemplate("MMMMy")
        draw(mf.string(from: monthDate), in: headerRect.offsetBy(dx: 0, dy: -3), font: CalendarView.headerFont,
             color: blue, para: center)
        draw("◀", in: prevRect.offsetBy(dx: 0, dy: -4), font: W7UIFont(10), color: .darkGray, para: center)
        draw("▶", in: nextRect.offsetBy(dx: 0, dy: -4), font: W7UIFont(10), color: .darkGray, para: center)

        // Weekday initials starting from the locale's first weekday.
        let symbols = calendar.shortStandaloneWeekdaySymbols
        let first = calendar.firstWeekday
        let c = CalendarView.cell
        let weekdayY = headerRect.minY - 22
        for col in 0..<7 {
            let s = symbols[(first - 1 + col) % 7]
            draw(String(s.prefix(2)), in: NSRect(x: gridLeft + CGFloat(col) * c, y: weekdayY, width: c, height: 18),
                 font: CalendarView.font, color: .black, para: center)
        }
        NSColor(srgbRed: 0xD5 / 255.0, green: 0xDF / 255.0, blue: 0xE5 / 255.0, alpha: 1).setFill()
        NSRect(x: gridLeft, y: weekdayY - 2, width: c * 7, height: 1).fill()

        let today = calendar.dateComponents([.year, .month, .day], from: Date())
        let grid = TrayLogic.monthGrid(year: year, month: month, firstWeekday: first, calendar: calendar)
        for (row, week) in grid.enumerated() {
            for (col, day) in week.enumerated() {
                guard let day else { continue }
                let r = NSRect(x: gridLeft + CGFloat(col) * c, y: weekdayY - 4 - CGFloat(row + 1) * 21, width: c, height: 21)
                if today.year == year && today.month == month && today.day == day {
                    let hl = NSBezierPath(rect: r.insetBy(dx: 1.5, dy: 1.5))
                    NSColor(srgbRed: 0xCC / 255.0, green: 0xE8 / 255.0, blue: 0xFF / 255.0, alpha: 1).setFill()
                    hl.fill()
                    NSColor(srgbRed: 0x99 / 255.0, green: 0xD1 / 255.0, blue: 0xFF / 255.0, alpha: 1).setStroke()
                    hl.lineWidth = 1
                    hl.stroke()
                }
                draw("\(day)", in: r.offsetBy(dx: 0, dy: -2), font: CalendarView.font, color: .black, para: center)
            }
        }
    }

    private func draw(_ s: String, in r: NSRect, font: NSFont, color: NSColor, para: NSParagraphStyle) {
        (s as NSString).draw(in: r, withAttributes: [.font: font, .foregroundColor: color, .paragraphStyle: para])
    }

    override func mouseDown(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        if prevRect.contains(p) { shift(-1) } else if nextRect.contains(p) { shift(1) }
    }

    private func shift(_ delta: Int) {
        month += delta
        if month < 1 { month = 12; year -= 1 }
        if month > 12 { month = 1; year += 1 }
        needsDisplay = true
    }
}

/// Ticks once a second while it is in a window (the flyout removes it when it closes).
@MainActor
private class SecondTickingView: NSView {
    private var timer: Timer?

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        timer?.invalidate()
        timer = nil
        guard window != nil else { return }
        timer = Timer.w7Scheduled(1, repeats: true, mode: .common) { [weak self] _ in
            MainActor.assumeIsolated { self?.needsDisplay = true }
        }
    }
}

/// A 100 pt analog clock face: white face, gradient rim, hour/minute/second hands.
@MainActor
private final class AnalogClockView: SecondTickingView {
    override func draw(_ dirtyRect: NSRect) {
        let d = min(bounds.width, bounds.height)
        let rect = NSRect(x: bounds.midX - d / 2, y: bounds.midY - d / 2, width: d, height: d)
        let rim = NSBezierPath(ovalIn: rect.insetBy(dx: 1, dy: 1))
        NSGradient(starting: NSColor(srgbRed: 0xE8 / 255.0, green: 0xEE / 255.0, blue: 0xF6 / 255.0, alpha: 1),
                   ending: NSColor(srgbRed: 0x6E / 255.0, green: 0x86 / 255.0, blue: 0xA8 / 255.0, alpha: 1))?
            .draw(in: rim, angle: -90)
        NSColor(srgbRed: 0.25, green: 0.32, blue: 0.42, alpha: 1).setStroke()
        rim.lineWidth = 1
        rim.stroke()
        let face = NSBezierPath(ovalIn: rect.insetBy(dx: 6, dy: 6))
        NSColor.white.setFill()
        face.fill()
        NSColor(white: 0.6, alpha: 1).setStroke()
        face.lineWidth = 0.5
        face.stroke()

        let c = NSPoint(x: rect.midX, y: rect.midY)
        let r = d / 2 - 6
        func point(_ angle: CGFloat, _ len: CGFloat) -> NSPoint {
            NSPoint(x: c.x + sin(angle) * len, y: c.y + cos(angle) * len)
        }
        for i in 0..<60 {
            let a = CGFloat(i) * .pi / 30
            let major = i % 5 == 0
            let tick = NSBezierPath()
            tick.move(to: point(a, r - (major ? 7 : 3)))
            tick.line(to: point(a, r - 1.5))
            tick.lineWidth = major ? 1.6 : 0.6
            NSColor(white: major ? 0.2 : 0.5, alpha: 1).setStroke()
            tick.stroke()
        }

        let comps = Calendar.autoupdatingCurrent.dateComponents([.hour, .minute, .second], from: Date())
        let h = CGFloat(comps.hour ?? 0), m = CGFloat(comps.minute ?? 0), s = CGFloat(comps.second ?? 0)
        func hand(_ angle: CGFloat, _ len: CGFloat, _ width: CGFloat, _ color: NSColor) {
            let p = NSBezierPath()
            p.move(to: point(angle + .pi, len * 0.15))
            p.line(to: point(angle, len))
            p.lineWidth = width
            p.lineCapStyle = .round
            color.setStroke()
            p.stroke()
        }
        hand((h.truncatingRemainder(dividingBy: 12) + m / 60) * .pi / 6, r * 0.5, 3, NSColor(white: 0.15, alpha: 1))
        hand((m + s / 60) * .pi / 30, r * 0.75, 2, NSColor(white: 0.15, alpha: 1))
        hand(s * .pi / 30, r * 0.82, 1, NSColor(srgbRed: 0.8, green: 0.1, blue: 0.1, alpha: 1))
        let hub = NSBezierPath(ovalIn: NSRect(x: c.x - 2.5, y: c.y - 2.5, width: 5, height: 5))
        NSColor(white: 0.15, alpha: 1).setFill()
        hub.fill()
    }
}

/// The digital time under the clock face.
@MainActor
private final class ClockTimeLabel: SecondTickingView {
    override func draw(_ dirtyRect: NSRect) {
        let f = DateFormatter()
        f.locale = .autoupdatingCurrent
        f.setLocalizedDateFormatFromTemplate("jms")
        let para = NSMutableParagraphStyle()
        para.alignment = .center
        (f.string(from: Date()) as NSString).draw(in: bounds, withAttributes: [
            .font: W7UIFont(12), .foregroundColor: NSColor.black, .paragraphStyle: para,
        ])
    }
}

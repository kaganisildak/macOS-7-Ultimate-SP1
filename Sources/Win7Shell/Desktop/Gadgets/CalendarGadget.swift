import AppKit
import Win7Core
import Win7Theme

/// The Calendar gadget. With the user's artwork (Assets/gadgets/Calendar/images/), as calendar.js draws it docked:
/// - the day page: today on `calendar_single_orange.png` in white, another day on `calendar_single.png` in black, with
///   the weekday, the date and month + year centred where calendar.css puts them; on another day the curl
///   (`curl.png`, `curl-hot.png` under the pointer) at the bottom left goes back to today. A click on the page opens
///   the month view of that day's month.
/// - the month view: `calendar_single.png` with the rings (`calendar_ring_docked.png`), ◀ ▶ (`bPrev/bNext`, `-hot`,
///   `-down`) around the short month and year, the weekday letters (today's in `#FF6400` in today's month) and the
///   grid of CalendarMonthGrid (other months' days silver, today on `#FF6400`, a day under the pointer in `#FF6400`,
///   `#DEDFDE` lines between the columns). A day opens its page; the title opens the year view.
/// - the year view: the twelve months (`month.png` over each name); ◀ ▶ change the year, a month opens its month view.
/// Month and weekday names come from Calendar.current. Without the two page images: the drawn page, as before (a
/// click switches between the day and a month view).
final class CalendarGadgetView: GadgetContentView {
    private enum Mode { case day, month, year }
    private enum Target: Equatable { case curl, previous, next, title, cell(row: Int, column: Int), month(Int) }
    private typealias L = GadgetLayout.Calendar

    private let art = GadgetArt(folder: "Calendar", kind: .calendar)
    private var monthView = false   // the drawn fallback's state
    private var timer: Timer?
    private var mode = Mode.day
    private var today = Date()
    /// The day page's date.
    private var shownDay = Date()
    /// The month (or, in the year view, the year) shown (calendar.js g_initDate).
    private var shownMonth = Date()
    private var hover: Target?
    private var pressed: Target?
    /// The month grid, rebuilt only when the shown month or today changes.
    private var cachedGrid: (key: DateComponents, grid: CalendarMonthGrid)?

    private var hasArt: Bool { art.has(["calendar_single.png", "calendar_single_orange.png"]) }
    private var calendar: Calendar { .current }
    private var canvas: GadgetCanvas { GadgetCanvas(height: bounds.height) }

    override func start() {
        today = Date()
        timer = gadgetTimer(60) { [weak self] in self?.tick() }
    }

    override func stop() { timer?.invalidate(); timer = nil }

    /// After midnight a page showing "today" turns to the new day (calendar.js setCalendarAlarm).
    private func tick() {
        let now = Date()
        if !calendar.isDate(now, inSameDayAs: today) {
            if calendar.isDate(shownDay, inSameDayAs: today) { shownDay = now }
            today = now
        }
        needsDisplay = true
    }

    private var showsToday: Bool { calendar.isDate(shownDay, inSameDayAs: today) }

    private func grid() -> CalendarMonthGrid {
        var key = calendar.dateComponents([.year, .month], from: shownMonth)
        key.day = calendar.ordinality(of: .day, in: .era, for: today)
        if let cachedGrid, cachedGrid.key == key { return cachedGrid.grid }
        let g = CalendarMonthGrid(month: shownMonth, today: today, calendar: calendar)
        cachedGrid = (key, g)
        return g
    }

    private var yearTitle: String {
        let f = DateFormatter()
        f.calendar = calendar
        f.setLocalizedDateFormatFromTemplate("y")
        return f.string(from: shownMonth)
    }

    private var title: String { mode == .year ? yearTitle : grid().title }

    // MARK: Pointer

    private func target(at p: NSPoint) -> Target? {
        let q = canvas.topLeft(p)
        switch mode {
        case .day:
            return !showsToday && L.curlHit.contains(q) ? .curl : nil
        case .month, .year:
            if L.previousButton.contains(q) { return .previous }
            if L.nextButton.contains(q) { return .next }
            let w = (title as NSString).size(withAttributes: [.font: GadgetFonts.segoe(10)]).width
            if mode == .month, CGRect(x: L.titleCenterX - w / 2 - 2, y: 20, width: w + 4, height: 16).contains(q) { return .title }
            if mode == .month {
                for row in 1...grid().weeks.count {
                    for column in 0..<7 where L.dayCell(row: row, column: column).contains(q) { return .cell(row: row, column: column) }
                }
            } else {
                for i in 0..<12 where L.monthCell(i).contains(q) { return .month(i) }
            }
            return nil
        }
    }

    override func hover(at point: NSPoint?) {
        guard hasArt else { return }
        let t = point.flatMap(target)
        if t != hover { hover = t; needsDisplay = true }
    }

    override func press(at point: NSPoint?) {
        guard hasArt else { return }
        let t = point.flatMap(target)
        if t != pressed { pressed = t; needsDisplay = true }
    }

    override func click(at point: NSPoint) {
        defer { needsDisplay = true }
        guard hasArt else { monthView.toggle(); return }
        let t = target(at: point)
        switch mode {
        case .day:
            if t == .curl {
                shownDay = today
            } else {
                shownMonth = shownDay
                mode = .month
            }
        case .month:
            switch t {
            case .previous: shownMonth = calendar.date(byAdding: .month, value: -1, to: shownMonth) ?? shownMonth
            case .next: shownMonth = calendar.date(byAdding: .month, value: 1, to: shownMonth) ?? shownMonth
            case .title: mode = .year
            case let .cell(row, column):
                let weeks = grid().weeks
                if weeks.indices.contains(row - 1) {
                    shownDay = weeks[row - 1][column].date
                    mode = .day
                }
            default: break
            }
        case .year:
            switch t {
            case .previous: shownMonth = calendar.date(byAdding: .year, value: -1, to: shownMonth) ?? shownMonth
            case .next: shownMonth = calendar.date(byAdding: .year, value: 1, to: shownMonth) ?? shownMonth
            case let .month(i):
                let current = calendar.component(.month, from: shownMonth)
                shownMonth = calendar.date(byAdding: .month, value: i + 1 - current, to: shownMonth) ?? shownMonth
                mode = .month
            default: break
            }
        }
        hover = nil
    }

    // MARK: Drawing

    private static let orange = NSColor(srgbRed: 1, green: 0x64 / 255, blue: 0, alpha: 1)
    private static let gray = NSColor(srgbRed: 0x80 / 255, green: 0x80 / 255, blue: 0x80 / 255, alpha: 1)
    private static let silver = NSColor(srgbRed: 0xC0 / 255, green: 0xC0 / 255, blue: 0xC0 / 255, alpha: 1)
    private static let columnLine = NSColor(srgbRed: 0xDE / 255, green: 0xDF / 255, blue: 0xDE / 255, alpha: 1)

    override func draw(_ dirtyRect: NSRect) {
        guard hasArt, let single = art.image("calendar_single.png"), let orangePage = art.image("calendar_single_orange.png") else {
            drawFallback()
            return
        }
        let c = canvas
        switch mode {
        case .day:
            let isToday = showsToday
            c.draw(isToday ? orangePage : single, at: .zero)
            let page = CalendarPage(date: shownDay, calendar: calendar)
            let color: NSColor = isToday ? .white : .black
            c.text(page.weekday, font: GadgetFonts.segoe(13), color: color, x: L.dayCenterX, baseline: L.weekdayBaseline,
                   align: .center, maxWidth: 90)
            c.text("\(page.day)", font: GadgetFonts.segoe(75), color: color, x: L.dayCenterX, baseline: L.dateBaseline, align: .center)
            c.text(page.monthYear, font: GadgetFonts.segoe(13), color: color, x: L.monthYearCenterX, baseline: L.monthYearBaseline,
                   align: .center, maxWidth: 110)
            if !isToday, let curl = art.image(hover == .curl ? "curl-hot.png" : "curl.png") ?? art.image("curl.png") {
                c.draw(curl, in: L.curl)
            }
        case .month, .year:
            c.draw(single, at: .zero)
            if let ring = art.image("calendar_ring_docked.png") { c.draw(ring, in: L.ring) }
            drawButton("bPrev", .previous, L.previousButton)
            drawButton("bNext", .next, L.nextButton)
            c.text(title, font: GadgetFonts.segoe(10), color: .black, x: L.titleCenterX, baseline: L.titleBaseline,
                   align: .center, maxWidth: 80)
            if mode == .month { drawMonth() } else { drawYear() }
        }
    }

    private func drawButton(_ name: String, _ t: Target, _ r: CGRect) {
        let state = pressed == t && hover == t ? "-down" : (hover == t ? "-hot" : "")
        if let img = art.image("\(name)\(state).png") ?? art.image("\(name).png") { canvas.draw(img, in: r) }
    }

    private func drawMonth() {
        let c = canvas
        let g = grid()
        let font = GadgetFonts.segoe(10), bold = GadgetFonts.segoe(10, bold: true)
        func line(_ r: CGRect) {
            Self.columnLine.setFill()
            c.rect(CGRect(x: r.minX, y: r.minY, width: 1, height: r.height)).fill()
        }
        for column in 0..<7 {
            let r = L.dayCell(row: 0, column: column)
            if column > 0 { line(r) }
            c.text(g.weekdaySymbols[column], font: bold, color: column == g.todayColumn ? Self.orange : Self.gray,
                   x: r.minX + 13, baseline: r.minY + 10, align: .right)
        }
        for (i, week) in g.weeks.enumerated() {
            for (column, cell) in week.enumerated() {
                let r = L.dayCell(row: i + 1, column: column)
                let today = cell.inMonth && cell.isToday
                if today {
                    Self.orange.setFill()
                    c.rect(r).fill()
                }
                if column > 0 { line(r) }
                let color: NSColor = !cell.inMonth ? Self.silver
                    : today ? .white
                    : hover == .cell(row: i + 1, column: column) ? Self.orange : .black
                c.text("\(cell.day)", font: font, color: color, x: r.minX + 13, baseline: r.minY + 10, align: .right)
            }
        }
    }

    private func drawYear() {
        let c = canvas
        let names = CalendarMonthGrid.shortMonthNames(calendar: calendar)
        let icon = art.image("month.png")
        for (i, name) in names.prefix(12).enumerated() {
            let r = L.monthCell(i)
            if let icon { c.draw(icon, at: CGPoint(x: (r.midX - icon.size.width / 2).rounded(), y: r.minY)) }
            c.text(name.localizedCapitalized, font: GadgetFonts.segoe(10), color: hover == .month(i) ? Self.orange : .black,
                   x: r.midX, baseline: r.minY + 20, align: .center, maxWidth: 28)
        }
    }

    /// The drawn page (no artwork imported).
    private func drawFallback() {
        let page = bounds.insetBy(dx: 6, dy: 6)
        let path = NSBezierPath(roundedRect: page, xRadius: 6, yRadius: 6)
        NSGraphicsContext.saveGraphicsState()
        let shadow = NSShadow()
        shadow.shadowColor = NSColor(white: 0, alpha: 0.5)
        shadow.shadowOffset = NSSize(width: 0, height: -2)
        shadow.shadowBlurRadius = 4
        shadow.set()
        NSColor.white.setFill()
        path.fill()
        NSGraphicsContext.restoreGraphicsState()
        NSGradient(starting: .white, ending: NSColor(srgbRed: 0xE8 / 255, green: 0xED / 255, blue: 0xF3 / 255, alpha: 1))?
            .draw(in: path, angle: -90)
        // Header band.
        let band = NSRect(x: page.minX, y: page.maxY - 24, width: page.width, height: 24)
        NSGraphicsContext.saveGraphicsState()
        path.addClip()
        NSGradient(starting: NSColor(srgbRed: 0x3D / 255, green: 0x7E / 255, blue: 0xC9 / 255, alpha: 1),
                   ending: NSColor(srgbRed: 0x1D / 255, green: 0x4F / 255, blue: 0x8C / 255, alpha: 1))?.draw(in: band, angle: -90)
        NSGraphicsContext.restoreGraphicsState()
        NSColor(srgbRed: 0x6E / 255, green: 0x7F / 255, blue: 0x93 / 255, alpha: 1).setStroke()
        path.lineWidth = 1
        path.stroke()

        let p = CalendarPage(date: Date())
        let dark = NSColor(srgbRed: 0x1E / 255, green: 0x39 / 255, blue: 0x5B / 255, alpha: 1)
        if !monthView {
            drawCentered(gadgetText(p.weekday, size: 12, color: .white, bold: true), x: band.midX, y: band.midY)
            drawCentered(gadgetText("\(p.day)", size: 50, color: dark, bold: true), x: page.midX, y: page.midY - 4)
            drawCentered(gadgetText(p.monthYear, size: 11, color: NSColor(white: 0.25, alpha: 1)), x: page.midX, y: page.minY + 12)
            return
        }
        drawCentered(gadgetText(p.monthYear, size: 11, color: .white, bold: true), x: band.midX, y: band.midY)
        let cols = 7, cw = (page.width - 8) / CGFloat(cols)
        let rowH = (band.minY - page.minY - 18) / CGFloat(max(5, p.weeks.count))
        var y = band.minY - 9
        for (i, s) in p.weekdaySymbols.enumerated() {
            drawCentered(gadgetText(s, size: 9, color: NSColor(white: 0.4, alpha: 1), bold: true), x: page.minX + 4 + cw * (CGFloat(i) + 0.5), y: y)
        }
        y -= 4
        for week in p.weeks {
            y -= rowH
            for (i, day) in week.enumerated() {
                guard let day else { continue }
                let cx = page.minX + 4 + cw * (CGFloat(i) + 0.5), cy = y + rowH / 2
                let today = day == p.day
                if today {
                    NSColor(srgbRed: 0x2E / 255, green: 0x6D / 255, blue: 0xB4 / 255, alpha: 1).setFill()
                    NSBezierPath(roundedRect: NSRect(x: cx - cw / 2 + 1, y: cy - rowH / 2 + 0.5, width: cw - 2, height: rowH - 1),
                                 xRadius: 2, yRadius: 2).fill()
                }
                drawCentered(gadgetText("\(day)", size: 9, color: today ? .white : dark, bold: today), x: cx, y: cy)
            }
        }
    }
}


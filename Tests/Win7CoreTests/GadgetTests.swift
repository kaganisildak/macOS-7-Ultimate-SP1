import CoreGraphics
import Foundation
import Testing
@testable import Win7Core

@Suite struct GadgetBoardTests {
    /// A 1440×860 desktop above a 40 pt taskbar (AppKit coordinates, bottom-left origin).
    private let area = CGRect(x: 0, y: 40, width: 1440, height: 860)

    @Test func kindsAndSizes() {
        #expect(GadgetKind.allCases == [.clock, .calendar, .cpuMeter, .slideShow])
        #expect(GadgetKind.clock.title == "Clock" && GadgetKind.cpuMeter.title == "CPU Meter")
        #expect(GadgetKind.calendar.title == "Calendar" && GadgetKind.slideShow.title == "Slide Show")
        #expect(GadgetKind.clock.size == CGSize(width: 130, height: 130))
        #expect(GadgetKind.calendar.size == CGSize(width: 130, height: 141))   // calendar.js Dock(): body 130×141
        #expect(GadgetKind.cpuMeter.size == CGSize(width: 130, height: 101))   // cpu.js dockedState(): body 130×101
        #expect(GadgetKind.slideShow.size == CGSize(width: 130, height: 100))
    }

    /// New gadgets dock top-right, stacked downward, leaving room for the hover toolbar.
    @Test func addStacksDownTheRightEdge() {
        var b = GadgetBoard()
        do { let r = b.add(.clock, in: area); #expect(r) }
        do { let r = b.add(.clock, in: area); #expect(!r) }          // one instance per kind
        do { let r = b.add(.calendar, in: area); #expect(r) }
        let x = area.maxX - GadgetBoard.margin - GadgetBoard.toolbarWidth - 130
        #expect(b.frame(of: .clock) == CGRect(x: x, y: area.maxY - GadgetBoard.margin - 130, width: 130, height: 130))
        #expect(b.frame(of: .calendar) == CGRect(x: x, y: area.maxY - GadgetBoard.margin - 130 - GadgetBoard.gap - 141,
                                                 width: 130, height: 141))
        #expect(b.kinds == [.clock, .calendar])
    }

    /// When the column is full, the next gadget starts a column to the left.
    @Test func addWrapsToNextColumn() {
        let short = CGRect(x: 0, y: 0, width: 800, height: 250)
        var b = GadgetBoard()
        do { let r = b.add(.clock, in: short); #expect(r) }
        do { let r = b.add(.calendar, in: short); #expect(r) }
        let c = b.frame(of: .calendar)!
        #expect(c.maxX <= b.frame(of: .clock)!.minX)
        #expect(c.maxY == short.maxY - GadgetBoard.margin)
    }

    /// A free slot left by a moved gadget is reused.
    @Test func addSkipsOccupiedSlots() {
        var b = GadgetBoard()
        _ = b.add(.clock, in: area)
        b.move(.clock, to: CGPoint(x: 100, y: 500), in: area)
        _ = b.add(.cpuMeter, in: area)
        #expect(b.frame(of: .cpuMeter)!.maxY == area.maxY - GadgetBoard.margin)
    }

    @Test func moveClampsIntoArea() {
        var b = GadgetBoard()
        _ = b.add(.clock, in: area)
        b.move(.clock, to: CGPoint(x: -500, y: 5000), in: area)
        #expect(b.frame(of: .clock)!.origin == CGPoint(x: 0, y: area.maxY - 130))
        b.move(.clock, to: CGPoint(x: 99_999, y: -99), in: area)
        #expect(b.frame(of: .clock)!.origin == CGPoint(x: area.maxX - GadgetBoard.toolbarWidth - 130, y: area.minY))
        b.move(.slideShow, to: .zero, in: area)     // not on the board: nothing happens
        #expect(b.frame(of: .slideShow) == nil)
    }

    @Test func removeAndPersist() throws {
        var b = GadgetBoard()
        _ = b.add(.clock, in: area)
        _ = b.add(.slideShow, in: area)
        b.remove(.clock)
        #expect(b.kinds == [.slideShow])
        let restored = GadgetBoard.decode(b.encoded())
        #expect(restored == b)
        #expect(GadgetBoard.decode(nil) == GadgetBoard())
        #expect(GadgetBoard.decode(Data("junk".utf8)) == GadgetBoard())
        // Unknown kinds (from a later version) are dropped, the rest kept.
        let json = #"[{"kind":"weather","x":1,"y":2},{"kind":"clock","x":3,"y":4}]"#
        #expect(GadgetBoard.decode(Data(json.utf8)).kinds == [.clock])
    }

    /// After a screen change every gadget is pulled back fully on screen.
    @Test func clampAll() {
        var b = GadgetBoard()
        _ = b.add(.clock, in: area)
        let small = CGRect(x: 0, y: 40, width: 800, height: 600)
        b.clampAll(in: small)
        #expect(small.contains(b.frame(of: .clock)!))
    }

    @Test func galleryGrid() {
        let rects = GadgetGalleryLayout.tileRects(count: 5, width: 400, tile: CGSize(width: 90, height: 100), spacing: 10)
        #expect(rects.count == 5)
        #expect(rects[0] == CGRect(x: 10, y: 10, width: 90, height: 100))
        #expect(rects[1] == CGRect(x: 110, y: 10, width: 90, height: 100))
        #expect(rects[3] == CGRect(x: 310, y: 10, width: 90, height: 100))
        #expect(rects[4] == CGRect(x: 10, y: 120, width: 90, height: 100))   // second row (top-left origin)
        #expect(GadgetGalleryLayout.index(at: CGPoint(x: 120, y: 50), in: rects) == 1)
        #expect(GadgetGalleryLayout.index(at: CGPoint(x: 105, y: 50), in: rects) == nil)
    }
}

@Suite struct GadgetContentTests {
    private func date(_ s: String) -> Date {
        let f = ISO8601DateFormatter()
        f.timeZone = TimeZone(identifier: "UTC")
        return f.date(from: s)!
    }
    private var utc: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC")!
        return c
    }

    @Test func clockHandAngles() {
        let h = ClockHands(date: date("2026-10-16T15:30:45Z"), calendar: utc)
        #expect(abs(h.hour - (3.5 * 30 + 0.75 * 0.5)) < 0.0001)     // 105.375°
        #expect(abs(h.minute - (30.75 * 6)) < 0.0001)              // 184.5°
        #expect(h.second == 270)
        let midnight = ClockHands(date: date("2026-10-16T00:00:00Z"), calendar: utc)
        #expect(midnight.hour == 0 && midnight.minute == 0 && midnight.second == 0)
    }

    @Test func calendarPage() {
        var cal = utc
        cal.locale = Locale(identifier: "en_US")
        cal.firstWeekday = 1
        let page = CalendarPage(date: date("2026-10-16T12:00:00Z"), calendar: cal)
        #expect(page.day == 16)
        #expect(page.weekday == "Friday")
        #expect(page.monthYear == "October 2026")
        #expect(page.weekdaySymbols == ["S", "M", "T", "W", "T", "F", "S"])
        #expect(page.weeks.first == [nil, nil, nil, nil, 1, 2, 3])
        #expect(page.weeks.last == [25, 26, 27, 28, 29, 30, 31])
        #expect(page.weeks.count == 5)
        cal.firstWeekday = 2
        let monday = CalendarPage(date: date("2026-10-16T12:00:00Z"), calendar: cal)
        #expect(monday.weeks.first == [nil, nil, nil, 1, 2, 3, 4])
        #expect(monday.weekdaySymbols.first == "M")
        #expect(monday.weeks.last == [26, 27, 28, 29, 30, 31, nil])
    }

    @Test func calendarPageTurkish() {
        var cal = utc
        cal.locale = Locale(identifier: "tr_TR")
        let page = CalendarPage(date: date("2026-10-16T12:00:00Z"), calendar: cal)
        #expect(page.weekday == "Cuma")
        #expect(page.monthYear == "Ekim 2026")
    }

    /// CPU % = busy ticks over all ticks between two samples, summed over every core.
    @Test func cpuPercentFromSamples() {
        let a = [CPUTicks(user: 100, system: 50, idle: 800, nice: 50), CPUTicks(user: 0, system: 0, idle: 1000, nice: 0)]
        let b = [CPUTicks(user: 160, system: 70, idle: 860, nice: 50), CPUTicks(user: 50, system: 50, idle: 1100, nice: 0)]
        // busy: 60+20 + 100 = 180; total: 140 + 200 = 340
        #expect(abs(SystemLoad.cpuPercent(previous: a, current: b) - 180.0 / 340.0 * 100) < 0.0001)
        #expect(SystemLoad.cpuPercent(previous: a, current: a) == 0)
        #expect(SystemLoad.cpuPercent(previous: [], current: b) == 0)
        // 32-bit tick counters wrap.
        let w0 = [CPUTicks(user: UInt32.max - 9, system: 0, idle: 0, nice: 0)]
        let w1 = [CPUTicks(user: 10, system: 0, idle: 20, nice: 0)]
        #expect(abs(SystemLoad.cpuPercent(previous: w0, current: w1) - 50) < 0.0001)
    }

    /// Memory % = (wired + active + compressed) pages over physical memory.
    @Test func memoryPercentFromSample() {
        let pages = VMPageCounts(free: 1000, active: 3000, inactive: 2000, wired: 1500, compressed: 500, speculative: 100)
        let total: UInt64 = 16384 * 10_000
        #expect(abs(SystemLoad.memoryPercent(pages, pageSize: 16384, totalBytes: total) - 50) < 0.0001)
        #expect(SystemLoad.memoryPercent(pages, pageSize: 16384, totalBytes: 0) == 0)
        let over = VMPageCounts(free: 0, active: 20_000, inactive: 0, wired: 0, compressed: 0, speculative: 0)
        #expect(SystemLoad.memoryPercent(over, pageSize: 16384, totalBytes: total) == 100)
    }

    @Test func slideShowPlaylist() {
        let names = ["b.JPG", "a.png", "notes.txt", ".hidden.jpg", "Photos Library.photoslibrary", "c.heic", "img10.jpg", "img9.jpg"]
        let list = SlideShowPlaylist.images(in: names)
        #expect(list == ["a.png", "b.JPG", "c.heic", "img9.jpg", "img10.jpg"])
        #expect(SlideShowPlaylist.next(after: 0, count: 3) == 1)
        #expect(SlideShowPlaylist.next(after: 2, count: 3) == 0)
        #expect(SlideShowPlaylist.next(after: 0, count: 0) == nil)
    }
}

/// The geometry the shell draws the user's Windows 7 gadget artwork with, measured from the gadgets' HTML/CSS/JS.
@Suite struct GadgetArtworkTests {
    private func date(_ s: String) -> Date {
        let f = ISO8601DateFormatter()
        f.timeZone = TimeZone(identifier: "UTC")
        return f.date(from: s)!
    }
    private func utc(firstWeekday: Int = 1, locale: String = "en_US") -> Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC")!
        c.locale = Locale(identifier: locale)
        c.firstWeekday = firstWeekday
        return c
    }

    /// clock.js: the eight themes in order, "trad" first (themeID 0 is the default), second hand off by default.
    @Test func clockStyles() {
        #expect(ClockStyle.allCases.map(\.fileName) == ["trad", "system", "cronometer", "diner", "flower", "modern", "square", "novelty"])
        #expect(ClockStyle.default == .trad)
        #expect(ClockStyle.showsSecondHandByDefault == false)
        #expect(ClockStyle(storedIndex: 4) == .flower)
        #expect(ClockStyle(storedIndex: 99) == .trad && ClockStyle(storedIndex: -1) == .trad)
    }

    /// settings.js: the arrows wrap around (back from the first gives the last, forward from the last the first).
    @Test func clockStyleWrapsAround() {
        #expect(ClockStyle.trad.stepped(by: -1) == .novelty)
        #expect(ClockStyle.novelty.stepped(by: 1) == .trad)
        #expect(ClockStyle.flower.stepped(by: 1) == .modern)
        #expect(ClockStyle.system.stepped(by: -1) == .trad)
        #expect(ClockStyle.trad.stepped(by: 17) == .system)
        #expect(ClockStyle.trad.position == 1 && ClockStyle.novelty.position == 8)
    }

    /// clock.js settingsChanged(): the hand images' box per theme; they turn about its centre.
    @Test func clockHandPivots() {
        #expect(ClockStyle.trad.handRect == CGRect(x: 57, y: -1, width: 13, height: 129))
        #expect(ClockStyle.trad.pivot == CGPoint(x: 63.5, y: 63.5))
        #expect(ClockStyle.system.pivot == CGPoint(x: 64.5, y: 64.5))
        #expect(ClockStyle.flower.pivot == CGPoint(x: 65.5, y: 64.5))
        #expect(ClockStyle.novelty.handRect == CGRect(x: 59, y: 46, width: 7, height: 81))
        #expect(ClockStyle.novelty.pivot == CGPoint(x: 62.5, y: 86.5))
    }

    /// cpu.js: Rotation = percent × 2.5 − 125, so the needle sweeps −125°…+125°.
    @Test func cpuDialAngles() {
        #expect(CPUMeterDial.angle(percent: 0) == -125)
        #expect(CPUMeterDial.angle(percent: 50) == 0)
        #expect(CPUMeterDial.angle(percent: 100) == 125)
        #expect(CPUMeterDial.angle(percent: -3) == -125 && CPUMeterDial.angle(percent: 140) == 125)
    }

    /// cpu.js numberFormat(): two digits and a percent sign; "100%" moves 3 pt left (centerPercent).
    @Test func cpuReadout() {
        #expect(CPUMeterDial.readout(percent: 0) == "00%")
        #expect(CPUMeterDial.readout(percent: 0.4) == "00%")
        #expect(CPUMeterDial.readout(percent: 7.6) == "08%")
        #expect(CPUMeterDial.readout(percent: 42.4) == "42%")
        #expect(CPUMeterDial.readout(percent: 100) == "100%")
        #expect(CPUMeterDial.readoutLeft(base: 33, text: "42%") == 33)
        #expect(CPUMeterDial.readoutLeft(base: 33, text: "100%") == 30)
    }

    /// calendar.js monthGrid(): weeks from the first weekday on or before the 1st, other months' days dimmed, rows
    /// until a week starts after the month; today's cell and (in today's month) its weekday header marked.
    @Test func monthGridOctober2026() {
        let grid = CalendarMonthGrid(month: date("2026-10-16T12:00:00Z"), today: date("2026-10-16T12:00:00Z"), calendar: utc())
        #expect(grid.title == "Oct 26")
        #expect(grid.weekdaySymbols == ["S", "M", "T", "W", "T", "F", "S"])
        #expect(grid.weeks.count == 5)
        #expect(grid.weeks[0].map(\.day) == [27, 28, 29, 30, 1, 2, 3])
        #expect(grid.weeks[0].map(\.inMonth) == [false, false, false, false, true, true, true])
        #expect(grid.weeks[4].map(\.day) == [25, 26, 27, 28, 29, 30, 31])
        #expect(grid.weeks.joined().filter(\.isToday).map(\.day) == [16])
        #expect(grid.weeks[2][5].isToday)
        #expect(grid.todayColumn == 5)     // Friday
        let cell = grid.weeks[0][0]
        #expect(utc().component(.month, from: cell.date) == 9 && utc().component(.day, from: cell.date) == 27)
    }

    /// February 2026 starts on a Sunday: the first row starts on the 1st (no week of January), and it has 4 rows.
    @Test func monthGridStartingOnSunday() {
        let grid = CalendarMonthGrid(month: date("2026-02-10T12:00:00Z"), today: date("2026-10-16T12:00:00Z"), calendar: utc())
        #expect(grid.weeks.count == 4)
        #expect(grid.weeks[0].map(\.day) == [1, 2, 3, 4, 5, 6, 7])
        #expect(grid.weeks.joined().allSatisfy { $0.inMonth })
        #expect(grid.todayColumn == nil)
        #expect(!grid.weeks.joined().contains { $0.isToday })
    }

    /// August 2026 starts on a Saturday: 6 rows, ending with September's first days dimmed.
    @Test func monthGridWithSixRows() {
        let grid = CalendarMonthGrid(month: date("2026-08-20T12:00:00Z"), today: date("2026-08-31T12:00:00Z"), calendar: utc())
        #expect(grid.weeks.count == 6)
        #expect(grid.weeks[0].map(\.day) == [26, 27, 28, 29, 30, 31, 1])
        #expect(grid.weeks[5].map(\.day) == [30, 31, 1, 2, 3, 4, 5])
        #expect(grid.weeks[5].map(\.inMonth) == [true, true, false, false, false, false, false])
        #expect(grid.weeks[5][1].isToday)
        #expect(grid.todayColumn == 1)     // Monday
    }

    /// The first weekday comes from the calendar (Monday in Turkey); December does not run into January's weeks.
    @Test func monthGridMondayFirstAndDecember() {
        let monday = CalendarMonthGrid(month: date("2026-10-01T12:00:00Z"), today: date("2026-10-16T12:00:00Z"),
                                       calendar: utc(firstWeekday: 2, locale: "tr_TR"))
        #expect(monday.weeks[0].map(\.day) == [28, 29, 30, 1, 2, 3, 4])
        #expect(monday.weeks.last?.map(\.day) == [26, 27, 28, 29, 30, 31, 1])
        #expect(monday.todayColumn == 4)
        #expect(monday.weekdaySymbols.first == "P")
        let december = CalendarMonthGrid(month: date("2026-12-05T12:00:00Z"), today: date("2026-10-16T12:00:00Z"), calendar: utc())
        #expect(december.weeks.count == 5)
        #expect(december.weeks.last?.map(\.day) == [27, 28, 29, 30, 31, 1, 2])
    }

    /// The year view (calendar.js year.html): twelve short month names, four to a row.
    @Test func yearViewMonths() {
        let names = CalendarMonthGrid.shortMonthNames(calendar: utc())
        #expect(names.count == 12 && names.first == "Jan" && names.last == "Dec")
    }

    @Test func slideShowPreviousAndFit() {
        #expect(SlideShowPlaylist.previous(before: 0, count: 3) == 2)
        #expect(SlideShowPlaylist.previous(before: 2, count: 3) == 1)
        #expect(SlideShowPlaylist.previous(before: 0, count: 0) == nil)
        // slideShow.js docked: the picture fits inside 120×90, centred (the table cell's align/valign).
        let box = CGRect(x: 4, y: 5, width: 120, height: 90)
        #expect(SlideShowPlaylist.fit(CGSize(width: 400, height: 200), in: box) == CGRect(x: 4, y: 20, width: 120, height: 60))
        #expect(SlideShowPlaylist.fit(CGSize(width: 300, height: 600), in: box) == CGRect(x: 41.5, y: 5, width: 45, height: 90))
        #expect(SlideShowPlaylist.fit(.zero, in: box) == box)
    }

    /// Top-left measurements become AppKit rects in a gadget of the given height.
    @Test func layoutFlip() {
        #expect(GadgetLayout.flip(CGRect(x: 4, y: 5, width: 120, height: 90), height: 100) == CGRect(x: 4, y: 5, width: 120, height: 90))
        #expect(GadgetLayout.flip(CGRect(x: 7, y: 68, width: 112, height: 23), height: 100) == CGRect(x: 7, y: 9, width: 112, height: 23))
        #expect(GadgetLayout.Calendar.dayCell(row: 0, column: 0) == CGRect(x: 4, y: 38, width: 15, height: 13))
        #expect(GadgetLayout.Calendar.dayCell(row: 2, column: 6) == CGRect(x: 106, y: 64, width: 15, height: 13))
        #expect(GadgetLayout.Calendar.monthCell(11) == CGRect(x: 92, y: 100, width: 28, height: 28))
        #expect(GadgetLayout.SlideShow.buttons.map(\.minX) == [14, 40, 63, 86])
    }
}

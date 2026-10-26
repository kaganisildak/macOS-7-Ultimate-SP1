import CoreGraphics
import Foundation

// The geometry the shell draws the user's own Windows 7 gadget artwork with (Assets/gadgets/<Name>/images/, imported
// from their media). Every number is measured from the gadgets' HTML, CSS and JavaScript in the docked (small) state,
// in points with a TOP-LEFT origin, as the HTML has it; `GadgetLayout.flip` turns a rect into AppKit's bottom-left one.

// MARK: - Clock

/// The Clock gadget's eight themes (clock.js `clockThemes`; themeID 0, "trad", is the default). Each theme is a face
/// `<fileName>.png`, hands `<fileName>_h/_m/_s.png`, a centre cap `<fileName>_dot.png` and a settings preview
/// `<fileName>_settings.png`.
public enum ClockStyle: Int, CaseIterable, Sendable {
    case trad, system, cronometer, diner, flower, modern, square, novelty

    public static let `default` = ClockStyle.trad
    /// settings.js `clockSettings`: `secondsEnabled = false`.
    public static let showsSecondHandByDefault = false

    /// The stored theme index; anything out of range gives the default (settings.js getValidThemeID).
    public init(storedIndex: Int) {
        self = ClockStyle(rawValue: storedIndex) ?? .default
    }

    public var fileName: String {
        switch self {
        case .trad: "trad"
        case .system: "system"
        case .cronometer: "cronometer"
        case .diner: "diner"
        case .flower: "flower"
        case .modern: "modern"
        case .square: "square"
        case .novelty: "novelty"
        }
    }

    /// 1-based, for settings.html's "1 of 8".
    public var position: Int { rawValue + 1 }

    /// The theme `offset` steps on, wrapping at both ends (settings.js settingsButtonBack/Forward).
    public func stepped(by offset: Int) -> ClockStyle {
        let n = Self.allCases.count
        return ClockStyle(rawValue: ((rawValue + offset) % n + n) % n) ?? .default
    }

    /// The hand images' box (clock.js settingsChanged: clockPartsLeft/Top/Width/Height). Every hand and the cap
    /// are drawn in this box and turned about its centre, as the gadget's g:image Rotation does.
    public var handRect: CGRect {
        switch self {
        case .trad, .cronometer, .square: CGRect(x: 57, y: -1, width: 13, height: 129)
        case .system: CGRect(x: 58, y: 0, width: 13, height: 129)
        case .diner, .modern: CGRect(x: 58, y: -1, width: 13, height: 129)
        case .flower: CGRect(x: 59, y: 0, width: 13, height: 129)
        case .novelty: CGRect(x: 59, y: 46, width: 7, height: 81)
        }
    }

    public var pivot: CGPoint { CGPoint(x: handRect.midX, y: handRect.midY) }
}

// MARK: - CPU Meter

public enum CPUMeterDial {
    /// The needle's rotation in degrees clockwise from straight up (cpu.js: percent × 2.5 + dialOffset −125).
    public static func angle(percent: Double) -> Double {
        min(100, max(0, percent)) * 2.5 - 125
    }

    /// The readout under a dial (cpu.js numberFormat): "00%" below 0.5, two digits, "100%".
    public static func readout(percent: Double) -> String {
        guard percent >= 0.5 else { return "00%" }
        let n = min(100, Int(percent.rounded()))
        return n < 10 ? "0\(n)%" : "\(n)%"
    }

    /// The readout's left edge (cpu.js centerPercent, docked): 3 pt further left for "100%".
    public static func readoutLeft(base: CGFloat, text: String) -> CGFloat {
        text.count > 3 ? base - 3 : base
    }
}

// MARK: - Calendar

/// The Calendar gadget's month view (calendar.js monthGrid): weeks from the calendar's first weekday on or before
/// the 1st (a month that starts on the first weekday starts its first row with the 1st), with the neighbouring
/// months' days shown dimmed, and rows until a week would start after the month.
public struct CalendarMonthGrid: Equatable, Sendable {
    public struct Cell: Equatable, Sendable {
        public var date: Date
        public var day: Int
        public var inMonth: Bool
        public var isToday: Bool
    }

    /// The short month name and two-digit year ("Oct 26"), in the calendar's locale (calendar.js month.html).
    public var title: String
    /// One letter per weekday, starting at the calendar's first weekday.
    public var weekdaySymbols: [String]
    /// The header column of today's weekday, marked when this is today's month (calendar.js ckCurrentMonth).
    public var todayColumn: Int?
    public var weeks: [[Cell]]

    public init(month: Date, today: Date, calendar: Calendar = .current) {
        let f = DateFormatter()
        f.calendar = calendar
        f.locale = calendar.locale ?? .current
        f.timeZone = calendar.timeZone
        f.setLocalizedDateFormatFromTemplate("MMMyy")
        title = f.string(from: month)
        let symbols = calendar.veryShortStandaloneWeekdaySymbols
        let first = calendar.firstWeekday - 1
        weekdaySymbols = (0..<7).map { symbols[(first + $0) % 7] }

        let start = calendar.dateInterval(of: .month, for: month)?.start ?? month
        let shown = calendar.dateComponents([.year, .month], from: start)
        func inShownMonth(_ d: Date) -> Bool {
            let c = calendar.dateComponents([.year, .month], from: d)
            return c.year == shown.year && c.month == shown.month
        }
        func column(_ d: Date) -> Int { (calendar.component(.weekday, from: d) - calendar.firstWeekday + 7) % 7 }

        todayColumn = inShownMonth(today) ? column(today) : nil
        var rowStart = calendar.date(byAdding: .day, value: -column(start), to: start) ?? start
        var weeks: [[Cell]] = []
        repeat {
            weeks.append((0..<7).map { i in
                let d = calendar.date(byAdding: .day, value: i, to: rowStart) ?? rowStart
                return Cell(date: d, day: calendar.component(.day, from: d), inMonth: inShownMonth(d),
                            isToday: calendar.isDate(d, inSameDayAs: today))
            })
            rowStart = calendar.date(byAdding: .day, value: 7, to: rowStart) ?? rowStart
        } while inShownMonth(rowStart) && weeks.count < 6
        self.weeks = weeks
    }

    /// The twelve short month names of the year view (calendar.js year.html), in the calendar's locale.
    public static func shortMonthNames(calendar: Calendar = .current) -> [String] {
        calendar.shortStandaloneMonthSymbols
    }
}

// MARK: - Positions

public enum GadgetLayout {
    /// A top-left-origin rect as an AppKit (bottom-left origin) rect in a gadget `height` points tall.
    public static func flip(_ r: CGRect, height: CGFloat) -> CGRect {
        CGRect(x: r.minX, y: height - r.maxY, width: r.width, height: r.height)
    }

    /// calendar.html/.css/.js, docked: the page `calendar_single(_orange).png` fills the 130×141 body.
    public enum Calendar {
        /// `#dockedCalendarRing` (calendar_ring_docked.png), shown with the month and year views.
        public static let ring = CGRect(x: 5, y: 10, width: 119, height: 19)
        /// `#btnPrevious` / `#btnNext` (bPrev*.png / bNext*.png, 16×16) in `div.prevnext` (top 10, padding-top 10).
        public static let previousButton = CGRect(x: 6, y: 20, width: 16, height: 16)
        public static let nextButton = CGRect(x: 107, y: 20, width: 16, height: 16)
        /// The month view's title (`#tID`, 10 px, centred in the prev/next row).
        public static let titleCenterX: CGFloat = 63.5
        public static let titleBaseline: CGFloat = 32
        /// `img.curlDocked` (curl.png / curl-hot.png): left 0, bottom 2 in `#divFilterDocked` (4, 11, 121×127);
        /// clicking it, or `#dockedHitRegion` (the body's bottom-left 27×27), goes back to today.
        public static let curl = CGRect(x: 4, y: 109, width: 27, height: 27)
        public static let curlHit = CGRect(x: 0, y: 109, width: 31, height: 32)
        /// The day page (`DAY_DOCKED`, 120 wide at x 4, table `#dowId` 3 pt down from top 16): the weekday (13 px),
        /// the date (75 px on a 60 px line) and month + year (13 px), centred.
        public static let dayCenterX: CGFloat = 64
        public static let monthYearCenterX: CGFloat = 66.5
        public static let weekdayBaseline: CGFloat = 33
        public static let dateBaseline: CGFloat = 102
        public static let monthYearBaseline: CGFloat = 125
        /// The month grid's cell: `q.day` boxes 15×13 every 17 pt from x 4, rows every 13 pt from y 38 (row 0 holds
        /// the weekday letters; calendar.js dayPos uses the same 17/13 pitch).
        public static func dayCell(row: Int, column: Int) -> CGRect {
            CGRect(x: 4 + 17 * CGFloat(column), y: 38 + 13 * CGFloat(row), width: 15, height: 13)
        }
        /// The year view's month (`var`, 28×28, four to a row, from x 8, y 44; month.png at its top centre).
        public static func monthCell(_ index: Int) -> CGRect {
            CGRect(x: 8 + 28 * CGFloat(index % 4), y: 44 + 28 * CGFloat(index / 4), width: 28, height: 28)
        }
    }

    /// cpu.html/.css/.js, docked: back.png at the body's top-left (130×101 body; the image's 2 lower rows are clear).
    public enum CPU {
        /// The needles (g:image `cpuMeter` dial.png 8×72, `memMeter` dial_sml.png 8×50), turned about their centres.
        public static let cpuNeedle = CGRect(x: 38, y: 22, width: 8, height: 72)
        public static let memoryNeedle = CGRect(x: 92, y: 8, width: 8, height: 50)
        /// The readouts (`#cpuBackground` left 33 top 76, `#memoryBackground` left 89 top 43: Calibri 10 px bold
        /// white) as left edges and baselines.
        public static let cpuReadoutLeft: CGFloat = 33
        public static let cpuReadoutBaseline: CGFloat = 85
        public static let memoryReadoutLeft: CGFloat = 89
        public static let memoryReadoutBaseline: CGFloat = 52
    }

    /// slideShow.html/.css/.js, docked: the frame `in_sidebar/slideshow_glass_frame.png` fills the 130×100 body.
    public enum SlideShow {
        /// `#pictureFrame`: top 5, left 4, 120×90.
        public static let picture = CGRect(x: 4, y: 5, width: 120, height: 90)
        /// `#bar` (top 68, left 7, 112×23, in_sidebar/bg_sidebar.png), shown while the pointer is over the gadget.
        public static let bar = CGRect(x: 7, y: 68, width: 112, height: 23)
        /// prev (20×17), play/pause (17×17), next (17×17), reveal (23×17): `#topBar` (3, 4 in the bar), images
        /// with hspace 3, back to back (the "-" adds nothing, play is hidden): reveal at 63 + 17 + 3 + 3 = 86.
        public static let buttons: [CGRect] = [
            CGRect(x: 14, y: 71, width: 20, height: 17),
            CGRect(x: 40, y: 71, width: 17, height: 17),
            CGRect(x: 63, y: 71, width: 17, height: 17),
            CGRect(x: 86, y: 71, width: 23, height: 17),
        ]
    }
}

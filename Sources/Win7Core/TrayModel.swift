import Foundation

public enum VolumeLevel: Equatable, Sendable {
    case muted, zero, low, medium, high

    /// The tray icon level: 0 muted … 4 high.
    public var iconLevel: Int {
        switch self {
        case .muted: 0
        case .zero: 1
        case .low: 2
        case .medium: 3
        case .high: 4
        }
    }
}

/// Pure logic behind the notification area icons, tooltips and the clock flyout's calendar.
public enum TrayLogic {
    public static func volumeLevel(volume: Float, muted: Bool) -> VolumeLevel {
        if muted { return .muted }
        if volume <= 0 { return .zero }
        if volume <= 0.33 { return .low }
        if volume <= 0.66 { return .medium }
        return .high
    }

    /// Wi-Fi signal bars 0…4. A connected network never shows fewer than one bar.
    public static func wifiBars(rssi: Int?) -> Int {
        guard let rssi else { return 0 }
        if rssi >= -55 { return 4 }
        if rssi >= -65 { return 3 }
        if rssi >= -75 { return 2 }
        return 1
    }

    public static func batteryTooltip(percent: Int, charging: Bool, pluggedIn: Bool) -> String {
        if pluggedIn && percent >= 100 { return "Fully charged (100%)" }
        if charging { return "\(percent)% available (plugged in, charging)" }
        if pluggedIn { return "\(percent)% available (plugged in, not charging)" }
        return "\(percent)% remaining"
    }

    public static func batteryIconLevel(percent: Int) -> Int {
        if percent < 10 { return 0 }
        if percent < 35 { return 1 }
        if percent < 60 { return 2 }
        if percent < 85 { return 3 }
        return 4
    }

    /// "tr" → "TR", "en-US" → "EN"; with no language, the first two letters of the source's name.
    public static func inputSourceAbbreviation(languages: [String], fallbackName: String) -> String {
        if let first = languages.first(where: { !$0.isEmpty }) {
            let code = first.split(whereSeparator: { $0 == "-" || $0 == "_" }).first.map(String.init) ?? first
            return String(code.prefix(2)).uppercased(with: Locale(identifier: "en_US_POSIX"))
        }
        return String(fallbackName.prefix(2)).uppercased(with: Locale(identifier: "en_US_POSIX"))
    }

    /// The days of a month laid out as 6 weeks × 7 days, with nil padding. Column 0 is
    /// `firstWeekday` (1 = Sunday, 2 = Monday, … as in `Calendar`).
    public static func monthGrid(year: Int, month: Int, firstWeekday: Int, calendar: Calendar) -> [[Int?]] {
        var cal = calendar
        cal.firstWeekday = firstWeekday
        var grid = [[Int?]](repeating: [Int?](repeating: nil, count: 7), count: 6)
        guard let first = cal.date(from: DateComponents(year: year, month: month, day: 1)),
              let days = cal.range(of: .day, in: .month, for: first)?.count else { return grid }
        let weekday = cal.component(.weekday, from: first)
        let offset = (weekday - firstWeekday + 7) % 7
        for day in 1...days {
            let cell = offset + day - 1
            guard cell < 42 else { break }
            grid[cell / 7][cell % 7] = day
        }
        return grid
    }
}

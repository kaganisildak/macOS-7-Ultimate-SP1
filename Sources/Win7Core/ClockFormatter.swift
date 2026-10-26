import Foundation

public enum ClockFormatter {
    public static func lines(for date: Date, locale: Locale, timeZone: TimeZone) -> (time: String, date: String) {
        func format(_ template: String) -> String {
            let f = DateFormatter()
            f.locale = locale
            f.timeZone = timeZone
            f.setLocalizedDateFormatFromTemplate(template)
            return f.string(from: date)
        }
        return (format("jm"), format("yMd"))
    }
}

import Foundation

/// A timezone-free calendar day. Contract dates are days, not instants, so they
/// are modelled without a time component to avoid off-by-one errors when the
/// device timezone changes. Arithmetic uses the proleptic Gregorian calendar.
public struct CalendarDate: Codable, Hashable, Comparable, Sendable, CustomStringConvertible {
    public var year: Int
    public var month: Int
    public var day: Int

    public init?(year: Int, month: Int, day: Int) {
        guard (1...12).contains(month), year >= 1, year <= 9999,
              day >= 1, day <= CalendarDate.daysInMonth(year: year, month: month) else { return nil }
        self.year = year
        self.month = month
        self.day = day
    }

    /// Creates a date without validation. Only for values already known to be valid.
    init(unchecked year: Int, _ month: Int, _ day: Int) {
        self.year = year
        self.month = month
        self.day = day
    }

    public static func isLeapYear(_ year: Int) -> Bool {
        (year % 4 == 0 && year % 100 != 0) || year % 400 == 0
    }

    public static func daysInMonth(year: Int, month: Int) -> Int {
        switch month {
        case 1, 3, 5, 7, 8, 10, 12: return 31
        case 4, 6, 9, 11: return 30
        case 2: return isLeapYear(year) ? 29 : 28
        default: return 0
        }
    }

    // MARK: Julian day number conversion (Fliegel & Van Flandern).

    public var julianDay: Int {
        let a = (14 - month) / 12
        let y = year + 4800 - a
        let m = month + 12 * a - 3
        return day + (153 * m + 2) / 5 + 365 * y + y / 4 - y / 100 + y / 400 - 32045
    }

    public init(julianDay jd: Int) {
        let a = jd + 32044
        let b = (4 * a + 3) / 146097
        let c = a - 146097 * b / 4
        let d = (4 * c + 3) / 1461
        let e = c - 1461 * d / 4
        let m = (5 * e + 2) / 153
        let day = e - (153 * m + 2) / 5 + 1
        let month = m + 3 - 12 * (m / 10)
        let year = 100 * b + d - 4800 + m / 10
        self.init(unchecked: year, month, day)
    }

    public func adding(days: Int) -> CalendarDate {
        CalendarDate(julianDay: julianDay + days)
    }

    /// Adds calendar months, clamping to the last day of the target month
    /// (31 Jan + 1 month = 28/29 Feb).
    public func adding(months: Int) -> CalendarDate {
        let total = (year * 12 + (month - 1)) + months
        let newYear = total / 12
        let newMonth = total % 12 + 1
        let newDay = min(day, CalendarDate.daysInMonth(year: newYear, month: newMonth))
        return CalendarDate(unchecked: newYear, newMonth, newDay)
    }

    public func adding(years: Int) -> CalendarDate { adding(months: years * 12) }

    public func days(until other: CalendarDate) -> Int { other.julianDay - julianDay }

    public static func < (lhs: CalendarDate, rhs: CalendarDate) -> Bool {
        (lhs.year, lhs.month, lhs.day) < (rhs.year, rhs.month, rhs.day)
    }

    // MARK: Conversion to and from Foundation dates.

    public init(_ date: Date, calendar: Calendar = CalendarDate.gregorian()) {
        let c = calendar.dateComponents([.year, .month, .day], from: date)
        self.init(unchecked: c.year ?? 1970, c.month ?? 1, c.day ?? 1)
    }

    /// The instant at `hour:minute` on this day in the calendar's timezone.
    public func date(hour: Int = 9, minute: Int = 0, calendar: Calendar = CalendarDate.gregorian()) -> Date {
        var c = DateComponents()
        c.year = year; c.month = month; c.day = day; c.hour = hour; c.minute = minute
        return calendar.date(from: c) ?? Date(timeIntervalSince1970: 0)
    }

    public static func gregorian(timeZone: TimeZone = .current) -> Calendar {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = timeZone
        return cal
    }

    public static func today(calendar: Calendar = CalendarDate.gregorian()) -> CalendarDate {
        CalendarDate(Date(), calendar: calendar)
    }

    // MARK: Formatting (Indian conventions by default).

    public static let monthNames = ["January", "February", "March", "April", "May", "June", "July",
                                    "August", "September", "October", "November", "December"]
    public static let monthAbbreviations = ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul",
                                            "Aug", "Sep", "Oct", "Nov", "Dec"]

    /// `15/10/2026` — the default Indian DD/MM/YYYY format.
    public var numericString: String {
        String(format: "%02d/%02d/%04d", day, month, year)
    }

    /// `15 Oct 2026`
    public var mediumString: String { "\(day) \(CalendarDate.monthAbbreviations[month - 1]) \(year)" }

    /// `15 October 2026`
    public var longString: String { "\(day) \(CalendarDate.monthNames[month - 1]) \(year)" }

    /// `2026-10-15`
    public var isoString: String { String(format: "%04d-%02d-%02d", year, month, day) }

    public init?(iso: String) {
        let parts = iso.trimmingCharacters(in: .whitespaces).split(separator: "-")
        guard parts.count == 3, let y = Int(parts[0]), let m = Int(parts[1]), let d = Int(parts[2]) else { return nil }
        self.init(year: y, month: m, day: d)
    }

    public var description: String { numericString }
}

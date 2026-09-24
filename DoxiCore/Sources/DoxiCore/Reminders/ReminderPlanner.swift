import Foundation

/// An obligation that may need reminders.
public struct ReminderCandidate: Sendable {
    public var obligationID: UUID
    public var title: String
    public var body: String
    public var dueDate: CalendarDate
    /// First occurrence for recurring obligations (defaults to `dueDate`).
    public var recurrence: Recurrence?
    /// Days before the due date, e.g. [30, 14, 7, 0].
    public var offsets: [Int]
    public var isOpen: Bool

    public init(obligationID: UUID, title: String, body: String, dueDate: CalendarDate, recurrence: Recurrence?, offsets: [Int], isOpen: Bool) {
        self.obligationID = obligationID
        self.title = title
        self.body = body
        self.dueDate = dueDate
        self.recurrence = recurrence
        self.offsets = offsets
        self.isOpen = isOpen
    }
}

public struct PlannedNotification: Hashable, Sendable {
    /// Stable identifier so rescheduling replaces rather than duplicates.
    public var identifier: String
    public var obligationID: UUID
    public var fireDate: Date
    public var title: String
    public var body: String
    public var dueDate: CalendarDate
    public var daysBefore: Int
}

/// Chooses which local notifications to schedule. iOS keeps at most 64 pending
/// notifications per app, so only the nearest ones are scheduled; the app
/// re-plans on every launch and whenever obligations change.
public struct ReminderPlanner: Sendable {
    public static let systemLimit = 64
    public var limit: Int
    public var hour: Int
    public var minute: Int
    public var calendar: Calendar
    /// Occurrences of a recurring obligation considered per plan.
    public var occurrencesPerRecurring: Int

    public init(limit: Int = ReminderPlanner.systemLimit - 4, hour: Int = 9, minute: Int = 0,
                calendar: Calendar = CalendarDate.gregorian(), occurrencesPerRecurring: Int = 6) {
        self.limit = limit
        self.hour = hour
        self.minute = minute
        self.calendar = calendar
        self.occurrencesPerRecurring = occurrencesPerRecurring
    }

    public func plan(_ candidates: [ReminderCandidate], now: Date) -> [PlannedNotification] {
        let today = CalendarDate(now, calendar: calendar)
        var planned: [PlannedNotification] = []
        for c in candidates where c.isOpen {
            let dueDates: [CalendarDate]
            if let r = c.recurrence {
                dueDates = RecurrenceEngine.occurrences(start: c.dueDate, recurrence: r, from: today, limit: occurrencesPerRecurring)
            } else {
                dueDates = [c.dueDate]
            }
            for due in dueDates {
                for offset in Set(c.offsets) where offset >= 0 {
                    let day = due.adding(days: -offset)
                    let fire = day.date(hour: hour, minute: minute, calendar: calendar)
                    guard fire > now else { continue }
                    planned.append(PlannedNotification(
                        identifier: "doxi.\(c.obligationID.uuidString).\(due.isoString).\(offset)",
                        obligationID: c.obligationID, fireDate: fire, title: c.title,
                        body: ReminderPlanner.body(c.body, due: due, daysBefore: offset),
                        dueDate: due, daysBefore: offset))
                }
            }
        }
        planned.sort { $0.fireDate != $1.fireDate ? $0.fireDate < $1.fireDate : $0.identifier < $1.identifier }
        return Array(planned.prefix(limit))
    }

    static func body(_ base: String, due: CalendarDate, daysBefore: Int) -> String {
        let when: String
        switch daysBefore {
        case 0: when = "Due today (\(due.mediumString))"
        case 1: when = "Due tomorrow (\(due.mediumString))"
        default: when = "Due in \(daysBefore) days (\(due.mediumString))"
        }
        return base.isEmpty ? when : "\(when) · \(base)"
    }
}

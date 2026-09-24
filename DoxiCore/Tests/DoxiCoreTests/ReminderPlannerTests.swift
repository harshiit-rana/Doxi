import XCTest
@testable import DoxiCore

final class ReminderPlannerTests: XCTestCase {
    let calendar = CalendarDate.gregorian(timeZone: TimeZone(identifier: "Asia/Kolkata")!)
    lazy var planner = ReminderPlanner(limit: 60, hour: 9, calendar: calendar)
    func d(_ s: String) -> CalendarDate { CalendarDate(iso: s)! }
    func now(_ s: String, hour: Int = 12) -> Date { d(s).date(hour: hour, calendar: calendar) }

    func candidate(_ due: String, offsets: [Int] = [30, 14, 7, 0], recurrence: Recurrence? = nil, open: Bool = true) -> ReminderCandidate {
        ReminderCandidate(obligationID: UUID(), title: "₹40,000 payment", body: "ABC Technologies", dueDate: d(due),
                          recurrence: recurrence, offsets: offsets, isOpen: open)
    }

    func testSchedulesConfiguredOffsetsAtNineAM() {
        let plan = planner.plan([candidate("2026-10-15")], now: now("2026-09-01"))
        XCTAssertEqual(plan.map(\.daysBefore), [30, 14, 7, 0])
        XCTAssertEqual(plan.first.map { CalendarDate($0.fireDate, calendar: calendar) }, d("2026-09-15"))
        XCTAssertEqual(calendar.component(.hour, from: plan[0].fireDate), 9)
        XCTAssertEqual(plan.last?.body, "Due today (15 Oct 2026) · ABC Technologies")
    }

    func testSkipsPastFireDates() {
        let plan = planner.plan([candidate("2026-10-15")], now: now("2026-10-10"))
        XCTAssertEqual(plan.map(\.daysBefore), [0])
        // Same day after 9am: nothing left.
        XCTAssertTrue(planner.plan([candidate("2026-10-15", offsets: [0])], now: now("2026-10-15", hour: 10)).isEmpty)
    }

    func testClosedObligationsGetNoReminders() {
        XCTAssertTrue(planner.plan([candidate("2026-10-15", open: false)], now: now("2026-09-01")).isEmpty)
    }

    func testRespectsLimitKeepingNearest() {
        let candidates = (0..<40).map { i in candidate(d("2026-10-01").adding(days: i).isoString) }
        let plan = planner.plan(candidates, now: now("2026-08-01"))
        XCTAssertEqual(plan.count, 60)
        XCTAssertEqual(plan, plan.sorted { $0.fireDate < $1.fireDate })
        let last = plan.last!.fireDate
        let all = ReminderPlanner(limit: 1000, hour: 9, calendar: calendar).plan(candidates, now: now("2026-08-01"))
        XCTAssertTrue(all.dropFirst(60).allSatisfy { $0.fireDate >= last })
        XCTAssertLessThanOrEqual(ReminderPlanner().limit, ReminderPlanner.systemLimit)
    }

    func testRecurringObligationPlansUpcomingOccurrences() {
        let plan = planner.plan([candidate("2026-04-05", offsets: [3], recurrence: Recurrence(frequency: .monthly))], now: now("2026-06-10"))
        XCTAssertEqual(plan.prefix(3).map(\.dueDate.isoString), ["2026-07-05", "2026-08-05", "2026-09-05"])
    }

    func testIdentifiersAreStableAcrossPlans() {
        let c = candidate("2026-10-15")
        XCTAssertEqual(planner.plan([c], now: now("2026-09-01")).map(\.identifier), planner.plan([c], now: now("2026-09-02")).map(\.identifier))
    }
}

import XCTest
@testable import DoxiCore

final class ObligationTests: XCTestCase {
    func d(_ s: String) -> CalendarDate { CalendarDate(iso: s)! }

    func confirmedFields() async -> [ExtractedFieldDraft] {
        var fields = await ExtractionPipeline().run(Fixtures.doc(Fixtures.freelanceContract)).fields
        for i in fields.indices { fields[i].verification = .confirmed }
        return fields
    }

    func testBuildsPaymentsRenewalAndNoticeFromConfirmedFields() async {
        let fields = await confirmedFields()
        let ctx = ObligationContext(parties: [.init(name: "ABC Technologies Private Limited", role: "Client"), .init(name: "Harshit Rana", role: "Freelancer")],
                                    userParty: "Harshit Rana", userIsNeither: false)
        let obligations = ObligationBuilder.build(from: fields, context: ctx)
        let payments = obligations.filter { $0.category == .payment }
        XCTAssertEqual(payments.map(\.dueDate), [d("2026-10-15"), d("2026-11-15")])
        XCTAssertTrue(payments.allSatisfy { $0.direction == .owedToMe && $0.status == .pending })
        XCTAssertEqual(payments.first?.counterparty, "ABC Technologies Private Limited")
        XCTAssertEqual(payments.first?.amount, Money(minorUnits: 4_000_000))

        let renewal = obligations.first { $0.category == .renewal }
        XCTAssertEqual(renewal?.dueDate, d("2026-12-15"))
        XCTAssertTrue(renewal?.title.contains("automatically") ?? false)

        let notice = obligations.first { $0.category == .noticeDeadline }
        XCTAssertEqual(notice?.dueDate, d("2026-11-15"))
        XCTAssertEqual(notice?.dueDateExplanation, "30 days before 15/12/2026 (end date)")
    }

    func testUnconfirmedFieldsCreateNothing() async {
        var fields = await confirmedFields()
        for i in fields.indices { fields[i].verification = .pending }
        XCTAssertTrue(ObligationBuilder.build(from: fields, context: .init(parties: [], userParty: nil, userIsNeither: false)).isEmpty)
    }

    func testDirectionUnknownUntilUserChoosesParty() async {
        let obligations = ObligationBuilder.build(from: await confirmedFields(), context: .init(parties: [], userParty: nil, userIsNeither: false))
        XCTAssertTrue(obligations.filter { $0.category == .payment }.allSatisfy { $0.direction == .unknown })
    }

    func testTenantOwesRent() async {
        var fields = await ExtractionPipeline().run(Fixtures.doc(Fixtures.rentAgreement)).fields
        for i in fields.indices { fields[i].verification = .confirmed }
        let ctx = ObligationContext(parties: [.init(name: "Suresh Kumar", role: "Landlord"), .init(name: "Rana Digital Studio", role: "Tenant")],
                                    userParty: "Rana Digital Studio", userIsNeither: false)
        let rent = ObligationBuilder.build(from: fields, context: ctx).first { $0.category == .payment }
        XCTAssertEqual(rent?.direction, .iOwe)
        XCTAssertEqual(rent?.recurrence?.frequency, .monthly)
        XCTAssertEqual(rent?.recurrence?.endDate, d("2027-02-28"))
    }

    func testStatusBecomesOverdueButNeverReceived() {
        XCTAssertEqual(ObligationStatus.effective(stored: .pending, due: d("2026-10-15"), today: d("2026-10-16")), .overdue)
        XCTAssertEqual(ObligationStatus.effective(stored: .pending, due: d("2026-10-15"), today: d("2026-10-15")), .pending)
        XCTAssertEqual(ObligationStatus.effective(stored: .received, due: d("2026-10-15"), today: d("2027-01-01")), .received)
        XCTAssertEqual(ObligationStatus.effective(stored: .upcoming, due: nil, today: d("2027-01-01")), .upcoming)
    }

    func testRecurrenceClampsAndKeepsAnchorDay() {
        let r = Recurrence(frequency: .monthly)
        let dates = RecurrenceEngine.occurrences(start: d("2026-01-31"), recurrence: r, from: d("2026-01-01"), limit: 4)
        XCTAssertEqual(dates.map(\.isoString), ["2026-01-31", "2026-02-28", "2026-03-31", "2026-04-30"])
        XCTAssertEqual(RecurrenceEngine.next(after: d("2026-02-28"), start: d("2026-01-31"), recurrence: r), d("2026-03-31"))
    }

    func testRecurrenceStopsAtEndDate() {
        let r = Recurrence(frequency: .monthly, endDate: d("2026-06-10"))
        let dates = RecurrenceEngine.occurrences(start: d("2026-04-05"), recurrence: r, from: d("2026-01-01"), limit: 12)
        XCTAssertEqual(dates.map(\.isoString), ["2026-04-05", "2026-05-05", "2026-06-05"])
        XCTAssertNil(RecurrenceEngine.next(after: d("2026-06-05"), start: d("2026-04-05"), recurrence: r))
        XCTAssertEqual(RecurrenceEngine.occurrences(start: d("2026-01-01"), recurrence: Recurrence(frequency: .quarterly), from: d("2026-05-01"), limit: 2).map(\.isoString),
                       ["2026-07-01", "2026-10-01"])
    }

    func testMoneyTotalsOnlyCountOpenPaymentsWithDirection() {
        let t = MoneySummary.totals([
            .init(amount: Money(minorUnits: 4_000_000), direction: .owedToMe, status: .pending),
            .init(amount: Money(minorUnits: 4_000_000), direction: .owedToMe, status: .overdue),
            .init(amount: Money(minorUnits: 4_000_000), direction: .owedToMe, status: .received),
            .init(amount: Money(minorUnits: 2_500_000), direction: .iOwe, status: .pending),
            .init(amount: Money(minorUnits: 1_000_000), direction: .unknown, status: .pending),
            .init(amount: Money(minorUnits: 1_000_000), direction: .notMine, status: .pending),
        ])
        XCTAssertEqual(t.owedToMe["INR"], 8_000_000)
        XCTAssertEqual(t.iOwe["INR"], 2_500_000)
        XCTAssertEqual(t.unassignedCount, 1)
    }
}

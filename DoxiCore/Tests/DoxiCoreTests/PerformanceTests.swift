import XCTest
@testable import DoxiCore

/// Coarse timings printed to the test log; limits only catch pathological regressions.
final class PerformanceTests: XCTestCase {
    func time(_ label: String, _ block: () -> Void) -> TimeInterval {
        let start = Date()
        block()
        let t = Date().timeIntervalSince(start)
        print(String(format: "Performance: %@ %.3fs", label, t))
        return t
    }

    func testSearchAcrossFiveHundredDocuments() {
        var docs: [SearchableDocument] = []
        _ = time("build search keys for 500 documents (once, at import)") { docs = (0..<500).map { i in
            SearchableDocument(id: UUID(), filename: "doc\(i).pdf", title: "Agreement \(i)", documentType: "Contract",
                               parties: ["Client \(i) Private Limited", "Harshit Rana"],
                               fields: [.init(label: "Total amount", value: "₹\(i),000", amount: Money(minorUnits: Int64(i) * 100_000))],
                               obligations: [], fullText: String(repeating: Fixtures.freelanceContract + "\n", count: 3))
        } }
        var results: [SearchResult] = []
        let t = time("search 500 documents (~3 KB each)") { results = SearchEngine.search("ABC Technologies", in: docs) }
        XCTAssertEqual(results.count, 500)
        XCTAssertLessThan(t, 10)
    }

    func testReminderPlanningForThousandObligations() {
        let now = CalendarDate(iso: "2026-09-01")!.date(hour: 8)
        let candidates = (0..<1000).map { i in
            ReminderCandidate(obligationID: UUID(), title: "t", body: "", dueDate: CalendarDate(iso: "2026-09-10")!.adding(days: i % 400),
                              recurrence: i % 10 == 0 ? Recurrence(frequency: .monthly) : nil, offsets: [30, 14, 7, 0], isOpen: true)
        }
        var plan: [PlannedNotification] = []
        let t = time("plan reminders for 1000 obligations") { plan = ReminderPlanner().plan(candidates, now: now) }
        XCTAssertEqual(plan.count, 60)
        XCTAssertLessThan(t, 5)
    }

    func testExtractionOfLongContract() async {
        let body = (0..<80).map { i in "\(i + 1). Clause heading\nThe Service Provider shall perform task \(i) diligently and report on progress to the Client every week." }
            .joined(separator: "\n\n")
        let text = Fixtures.freelanceContract + "\n\n" + body + "\n\n" + Fixtures.freelanceContract
        let start = Date()
        let outcome = await ExtractionPipeline().run(DocumentText(plainText: text))
        let t = Date().timeIntervalSince(start)
        print(String(format: "Performance: extraction of %d-character contract %.3fs", text.count, t))
        XCTAssertFalse(outcome.fields.isEmpty)
        XCTAssertLessThan(t, 20)
    }
}

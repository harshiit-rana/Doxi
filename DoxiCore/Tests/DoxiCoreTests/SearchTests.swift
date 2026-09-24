import XCTest
@testable import DoxiCore

final class SearchTests: XCTestCase {
    let contractID = UUID()
    let invoiceID = UUID()
    let obligationID = UUID()

    lazy var docs: [SearchableDocument] = [
        SearchableDocument(
            id: contractID, filename: "client_contract.pdf", title: "Freelance Services Agreement", documentType: "Freelance Agreement",
            parties: ["ABC Technologies Private Limited", "Harshit Rana"],
            fields: [.init(label: "Total amount", value: "₹80,000", amount: Money(minorUnits: 8_000_000)),
                     .init(label: "End date", value: "15/12/2026", date: CalendarDate(iso: "2026-12-15"))],
            obligations: [.init(id: obligationID, title: "₹40,000 installment 1", amount: Money(minorUnits: 4_000_000),
                                dueDate: CalendarDate(iso: "2026-10-15"), status: .pending)],
            fullText: Fixtures.freelanceContract),
        SearchableDocument(
            id: invoiceID, filename: "IMG_2041.jpg", title: "Tax Invoice", documentType: "Invoice", parties: ["XYZ Agency LLP"],
            fields: [.init(label: "Total amount", value: "₹29,500", amount: Money(minorUnits: 2_950_000))],
            obligations: [], fullText: Fixtures.invoice),
    ]

    func testCompanyName() {
        let r = SearchEngine.search("ABC Technologies", in: docs)
        XCTAssertEqual(r.map(\.documentID), [contractID])
        XCTAssertTrue(r[0].score > 0)
    }

    func testPartialLastWord() {
        XCTAssertEqual(SearchEngine.search("abc tech", in: docs).first?.documentID, contractID)
    }

    func testAmountInDifferentFormats() {
        for q in ["₹80,000", "80000", "Rs 80,000", "80k", "0.8 lakh"] {
            XCTAssertEqual(SearchEngine.search(q, in: docs).first?.documentID, contractID, q)
        }
        let inst = SearchEngine.search("40,000", in: docs).first
        XCTAssertEqual(inst?.matchedObligationIDs, [obligationID])
        XCTAssertEqual(SearchEngine.search("29500", in: docs).first?.documentID, invoiceID)
    }

    func testMonthFindsDatesAndText() {
        let r = SearchEngine.search("October", in: docs)
        XCTAssertTrue(r.contains { $0.documentID == contractID && $0.matchedObligationIDs == [obligationID] })
        XCTAssertTrue(r.contains { $0.documentID == invoiceID }) // "Website maintenance - October"
    }

    func testFullDate() {
        XCTAssertEqual(SearchEngine.search("15/10/2026", in: docs).first?.documentID, contractID)
    }

    func testDocumentTypeAndOCRText() {
        XCTAssertEqual(SearchEngine.search("invoice", in: docs).first?.documentID, invoiceID)
        XCTAssertEqual(SearchEngine.search("maintenance", in: docs).map(\.documentID), [invoiceID])
        XCTAssertNotNil(SearchEngine.search("maintenance", in: docs).first?.snippet)
    }

    func testNoResults() {
        XCTAssertTrue(SearchEngine.search("Globex", in: docs).isEmpty)
        XCTAssertTrue(SearchEngine.search("   ", in: docs).isEmpty)
    }
}

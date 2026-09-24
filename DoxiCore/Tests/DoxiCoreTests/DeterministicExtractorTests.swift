import XCTest
@testable import DoxiCore

final class DeterministicExtractorTests: XCTestCase {
    let fields = DeterministicExtractor().extract(Fixtures.doc(Fixtures.freelanceContract))

    func testDocumentTypeAndTitle() {
        XCTAssertEqual(Fixtures.field(fields, .documentType)?.value, .documentType(.freelanceAgreement))
        XCTAssertEqual(Fixtures.field(fields, .title)?.displayValue, "FREELANCE SERVICES AGREEMENT")
    }

    func testParties() {
        let parties = fields.filter { $0.kind == .party }.compactMap { f -> PartyValue? in
            if case .party(let p) = f.value { return p }
            return nil
        }
        XCTAssertEqual(parties.map(\.name), ["ABC Technologies Private Limited", "Harshit Rana"])
        XCTAssertEqual(parties.map(\.role), ["Client", "Freelancer"])
    }

    func testDates() {
        XCTAssertEqual(Fixtures.field(fields, .effectiveDate)?.value.primaryDate?.isoString, "2026-09-15")
        XCTAssertEqual(Fixtures.field(fields, .endDate)?.value.primaryDate?.isoString, "2026-12-15")
    }

    func testMoney() {
        XCTAssertEqual(Fixtures.field(fields, .totalAmount)?.value, .money(Money(minorUnits: 8_000_000)))
        let payments = fields.filter { $0.kind == .payment }
        XCTAssertEqual(payments.count, 2)
        XCTAssertEqual(payments.map { $0.value.primaryAmount?.minorUnits }, [4_000_000, 4_000_000])
        XCTAssertEqual(payments.map { $0.value.primaryDate?.isoString }, ["2026-10-15", "2026-11-15"])
        if case .payment(let p) = payments[0].value { XCTAssertEqual(p.label, "Installment 1") }
    }

    func testNoticeAndRenewal() {
        XCTAssertEqual(Fixtures.field(fields, .noticePeriod)?.value, .duration(Duration(value: 30, unit: .days)))
        guard case .renewal(let r)? = Fixtures.field(fields, .renewal)?.value else { return XCTFail("no renewal") }
        XCTAssertEqual(r.automatic, true)
        XCTAssertEqual(r.term, Duration(value: 1, unit: .years))
    }

    func testEveryFieldHasASourceOnTheRightText() {
        for f in fields {
            let span = try? XCTUnwrap(f.source, "\(f.kind) has no source")
            XCTAssertEqual(span?.match, .exact)
            XCTAssertFalse(span?.boxes.isEmpty ?? true)
        }
        let total = Fixtures.field(fields, .totalAmount)?.source?.quote ?? ""
        XCTAssertTrue(total.contains("INR 80,000"), total)
    }

    func testRecurringRent() {
        let f = DeterministicExtractor().extract(Fixtures.doc(Fixtures.rentAgreement))
        XCTAssertEqual(Fixtures.field(f, .documentType)?.value, .documentType(.rentalAgreement))
        guard case .payment(let p)? = Fixtures.field(f, .payment)?.value else { return XCTFail("no rent payment") }
        XCTAssertEqual(p.amount, Money(minorUnits: 2_500_000))
        XCTAssertEqual(p.recurrence?.frequency, .monthly)
        XCTAssertEqual(p.due?.date?.isoString, "2026-04-05")
        XCTAssertEqual(Fixtures.field(f, .paymentFrequency)?.value, .frequency(.monthly))
        // 11-month term derived from the commencement date, base shown.
        guard case .date(let end)? = Fixtures.field(f, .endDate)?.value else { return XCTFail("no end date") }
        XCTAssertEqual(end.relative?.baseDate?.isoString, "2026-04-01")
        XCTAssertEqual(end.resolved?.isoString, "2027-03-01")
    }

    func testInvoice() {
        let f = DeterministicExtractor().extract(Fixtures.doc(Fixtures.invoice))
        XCTAssertEqual(Fixtures.field(f, .documentType)?.value, .documentType(.invoice))
        XCTAssertEqual(Fixtures.field(f, .totalAmount)?.value, .money(Money(minorUnits: 2_950_000)))
        guard case .payment(let p)? = Fixtures.field(f, .payment)?.value else { return XCTFail("no payment") }
        XCTAssertEqual(p.amount, Money(minorUnits: 2_950_000))
        XCTAssertEqual(p.due?.date?.isoString, "2026-10-31")
        XCTAssertEqual(Fixtures.field(f, .effectiveDate)?.value.primaryDate?.isoString, "2026-10-01")
        XCTAssertEqual(f.filter { $0.kind == .identifier }.map(\.displayValue), ["GSTIN: 07ABCPR1234K1Z2"])
        let parties = f.filter { $0.kind == .party }.map(\.displayValue)
        XCTAssertTrue(parties.contains("XYZ Agency LLP (Client)"), "\(parties)")
    }

    func testEmptyAndNoiseDocumentsDoNotCrash() {
        XCTAssertTrue(DeterministicExtractor().extract(DocumentText(pages: [])).isEmpty)
        XCTAssertTrue(DeterministicExtractor().extract(Fixtures.doc("   \n  ")).isEmpty)
        _ = DeterministicExtractor().extract(Fixtures.doc(String(repeating: "#@! 12/13/14 ₹ Rs. , , ", count: 200)))
    }

    func testDocumentWithNoDates() {
        let f = DeterministicExtractor().extract(Fixtures.doc("Quotation\nWebsite design Rs. 50,000\nValid for acceptance by the client."))
        XCTAssertNil(Fixtures.field(f, .effectiveDate))
        XCTAssertNil(Fixtures.field(f, .endDate))
    }

    func testUSOrderedDocumentReadsAmbiguousDatesMonthFirst() {
        let text = "SERVICE AGREEMENT\nThis Agreement is effective from 09/05/2026. Invoice issued on 12/31/2026."
        let f = DeterministicExtractor().extract(Fixtures.doc(text))
        XCTAssertEqual(Fixtures.field(f, .effectiveDate)?.value.primaryDate?.isoString, "2026-09-05")
    }
}

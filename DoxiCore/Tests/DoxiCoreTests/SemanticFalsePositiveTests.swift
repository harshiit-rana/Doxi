import XCTest
@testable import DoxiCore

/// The same amount or date can mean very different things. Only amounts that are
/// actually payable should become payment fields; dates keep their role.
final class SemanticFalsePositiveTests: XCTestCase {
    func extract(_ text: String) -> [ExtractedFieldDraft] { DeterministicExtractor().extract(DocumentText(plainText: text)) }

    func payments(_ fields: [ExtractedFieldDraft]) -> [PaymentValue] {
        fields.compactMap { if case .payment(let p) = $0.value { return p }; return nil }
    }

    func testTotalContractValueIsNotAPayment() {
        let f = extract("SERVICE AGREEMENT\nThe total contract value is ₹80,000.")
        XCTAssertEqual(Fixtures.field(f, .totalAmount)?.value.primaryAmount?.minorUnits, 8_000_000)
        XCTAssertTrue(payments(f).isEmpty)
    }

    func testAdvanceIsAPayment() {
        let f = extract("SERVICE AGREEMENT\nAn advance of ₹80,000 shall be paid on 01/10/2026.")
        XCTAssertEqual(payments(f).map { $0.amount?.minorUnits }, [8_000_000])
        XCTAssertEqual(payments(f).first?.label, "Advance payment")
    }

    func testPenaltyIsNotAPayment() {
        let f = extract("SERVICE AGREEMENT\nDelay beyond 15/11/2026 shall attract a penalty of ₹80,000.")
        XCTAssertTrue(payments(f).isEmpty)
        XCTAssertNil(Fixtures.field(f, .totalAmount))
    }

    func testExampleAmountIsIgnored() {
        let f = extract("SERVICE AGREEMENT\nFor example, if an invoice of ₹80,000 is raised on 01/10/2026, interest accrues monthly.")
        XCTAssertTrue(payments(f).isEmpty)
        XCTAssertNil(Fixtures.field(f, .totalAmount))
    }

    func testPreviousPaymentIsNotAnObligation() {
        let texts = [
            "SERVICE AGREEMENT\nThe Client has already paid ₹80,000 on 01/08/2026 as advance.",
            "SERVICE AGREEMENT\nThe Tenant has paid a security deposit of ₹80,000 on signing of this agreement.",
            "SERVICE AGREEMENT\nReceived with thanks ₹80,000 on 01/08/2026.",
        ]
        for t in texts { XCTAssertTrue(payments(extract(t)).isEmpty, t) }
    }

    func testSecurityDepositPayableIsAPaymentWithoutInventedDate() {
        let f = extract("RENT AGREEMENT\nThe Tenant shall pay a refundable security deposit of ₹80,000 on signing of this agreement.")
        XCTAssertEqual(payments(f).first?.label, "Security deposit")
        XCTAssertNil(payments(f).first?.due)
    }

    func testMonthlyAmountIsRecurringNotTotal() {
        let f = extract("RENT AGREEMENT\nThe licence commences on 01/07/2026. The monthly rent of ₹80,000 is payable on the 5th day of each month.")
        XCTAssertNil(Fixtures.field(f, .totalAmount))
        XCTAssertEqual(payments(f).first?.recurrence?.frequency, .monthly)
        XCTAssertEqual(payments(f).first?.due?.date?.isoString, "2026-07-05")
    }

    // MARK: Dates keep their meaning

    func testInvoiceDateIsNotTheDueDate() {
        let f = extract("TAX INVOICE\nInvoice No: 12\nInvoice Date: 01/10/2026\nDue Date: 31/10/2026\nGrand Total ₹80,000")
        XCTAssertEqual(Fixtures.field(f, .effectiveDate)?.value.primaryDate?.isoString, "2026-10-01")
        XCTAssertEqual(payments(f).first?.due?.date?.isoString, "2026-10-31")
        XCTAssertNil(Fixtures.field(f, .endDate))
    }

    func testReferenceDateIsNotAPaymentDate() {
        let f = extract("Dear Sir,\nPayment of ₹80,000 against our invoice dated 15/09/2026 is pending. Kindly pay by 10/10/2026.\nYours sincerely")
        XCTAssertEqual(payments(f).first?.due?.date?.isoString, "2026-10-10")
    }

    func testSigningEffectiveAndExpiryDatesAreSeparated() {
        let f = extract("""
        SERVICE AGREEMENT
        This Agreement is signed on 01/09/2026. It shall be effective from 15/09/2026 and shall expire on 14/09/2027.
        """)
        XCTAssertEqual(Fixtures.field(f, .effectiveDate)?.value.primaryDate?.isoString, "2026-09-15")
        XCTAssertEqual(Fixtures.field(f, .endDate)?.value.primaryDate?.isoString, "2027-09-14")
    }

    func testExampleDateIsNotADeadline() {
        let f = extract("SERVICE AGREEMENT\nFor example, a deliverable due on 01/01/2027 must be submitted in PDF format.")
        XCTAssertTrue(f.filter { $0.kind == .obligation }.isEmpty)
    }

    // MARK: Relative dates vs notice periods

    func testRelativePaymentDeadlineIsDerivedWithBase() {
        let f = extract("TAX INVOICE\nInvoice Date: 15/09/2026\nTotal Amount ₹80,000\nPayment shall be made within 30 days of invoice.")
        guard let due = payments(f).first?.due else { return XCTFail("no due date") }
        XCTAssertNil(due.date, "a derived date must not be stored as an explicit date")
        XCTAssertEqual(due.relative?.offset, Duration(value: 30, unit: .days))
        XCTAssertEqual(due.relative?.baseDate?.isoString, "2026-09-15")
        XCTAssertEqual(due.resolved?.isoString, "2026-10-15")
        XCTAssertTrue(due.formatted.contains("base 15/09/2026"), due.formatted)
    }

    func testNoticePeriodIsNotADeadline() {
        let f = extract("SERVICE AGREEMENT\nEither party may terminate by providing 30 days' written notice.")
        XCTAssertEqual(Fixtures.field(f, .noticePeriod)?.value, .duration(Duration(value: 30, unit: .days)))
        XCTAssertTrue(payments(f).isEmpty)
        XCTAssertTrue(f.filter { $0.kind == .obligation }.isEmpty)
        XCTAssertTrue(f.allSatisfy { $0.value.primaryDate == nil })
    }
}

final class OCRDigitTests: XCTestCase {
    func testRepairsDigitsInsideNumbersOnly() {
        XCTAssertEqual(OCRDigits.normalize("O1/12/2026 50,OOO 15/01/2O27"), "01/12/2026 50,000 15/01/2027")
        XCTAssertEqual(OCRDigits.normalize("All amounts, Ill, IO, A11, Rs.l"), "All amounts, Ill, IO, A11, Rs.l")
        XCTAssertEqual(OCRDigits.normalize("abc").utf16.count, 3)
    }

    func testScheduleTableWithOCRNoise() {
        let text = """
        PAYMENT SCHEDULE
        Milestone      Due date      Amount (Rs)
        Kick-off       O1/12/2026    50,OOO
        Launch         28/02/2027    75,000
        Total                        1,25,000
        """
        let f = DeterministicExtractor().extract(DocumentText(plainText: text))
        let payments = f.compactMap { x -> PaymentValue? in if case .payment(let p) = x.value { return p }; return nil }
        XCTAssertEqual(payments.map { $0.due?.date?.isoString }, ["2026-12-01", "2027-02-28"])
        XCTAssertEqual(payments.map { $0.amount?.minorUnits }, [5_000_000, 7_500_000])
        XCTAssertEqual(payments.first?.label, "Kick-off")
        // The source quote shows the document as scanned.
        XCTAssertTrue(f.first { $0.kind == .payment }?.source?.quote.contains("O1/12/2026") ?? false)
    }

    func testNetTermsAreRelativeToInvoiceDate() {
        let text = "INVOICE\nInvoice Date: 20 October 2026\nTotal USD 3,000.00\nPayment terms: Net 30 from invoice date."
        let f = DeterministicExtractor().extract(DocumentText(plainText: text))
        var fields = f
        RelativeDateResolver.resolve(&fields)
        guard case .payment(let p)? = fields.first(where: { $0.kind == .payment })?.value else { return XCTFail() }
        XCTAssertEqual(p.due?.resolved?.isoString, "2026-11-19")
        XCTAssertTrue(p.due?.isDerived ?? false)
    }
}

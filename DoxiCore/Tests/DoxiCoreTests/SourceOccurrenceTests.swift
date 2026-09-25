import XCTest
@testable import DoxiCore

/// Source matching must pick the occurrence that actually supports the value.
final class SourceOccurrenceTests: XCTestCase {
    func mapper(_ text: String) -> (LLMFieldMapper, DocumentText) {
        let doc = DocumentText(plainText: text)
        return (LLMFieldMapper(matcher: SourceMatcher(document: doc)), doc)
    }

    func quote(of span: SourceSpan?) -> String { span?.quote ?? "" }

    func testSameAmountTwicePicksTotalContext() {
        // No usable quote: the value must be located by context.
        let text = "Delay attracts a penalty of up to INR 80,000.\nThe total project fee is INR 80,000 payable on completion."
        let (m, _) = mapper(text)
        var r = LLMExtractionResponse()
        r.totalAmount = .init(amount: LooseString("80000"), currency: "INR", sourceQuote: "not in document", page: nil)
        let f = m.map(r).first!
        XCTAssertTrue(quote(of: f.source).contains("total project fee"), quote(of: f.source))
    }

    func testIdenticalQuoteOnTwoPagesUsesPageHintAndNotesAmbiguity() {
        let text = "Payment of Rs. 40,000 is due on signing.\u{0C}Annexure\nPayment of Rs. 40,000 is due on signing."
        let (m, _) = mapper(text)
        var p = LLMExtractionResponse.Payment()
        p.amount = LooseString("40000")
        p.sourceQuote = "Payment of Rs. 40,000 is due on signing."
        p.page = LooseString("2")
        var r = LLMExtractionResponse()
        r.payments = [p]
        let f = m.map(r).first!
        XCTAssertEqual(f.source?.pageIndex, 1)
        // Page hint breaks the tie, so no ambiguity note.
        XCTAssertFalse(f.notes.contains { $0.contains("appears") })

        p.page = nil
        r.payments = [p]
        let g = m.map(r).first!
        XCTAssertEqual(g.source?.pageIndex, 0)
        XCTAssertTrue(g.notes.contains { $0.contains("appears 2 times") }, "\(g.notes)")
    }

    func testQuoteOccurrenceContainingValueWins() {
        // The short quote matches two installment lines; only one has the date the model reported.
        let text = "The installment of Rs. 40,000 shall be paid on 15/10/2026.\nThe installment of Rs. 40,000 shall be paid on 15/11/2026."
        let doc = DocumentText(plainText: text)
        let matcher = SourceMatcher(document: doc)
        let value = FieldValue.payment(PaymentValue(amount: Money(minorUnits: 4_000_000), due: DateValue(date: CalendarDate(iso: "2026-11-15")), label: "x"))
        let match = matcher.locate(quote: "The installment of Rs. 40,000 shall be paid on", value: value, kind: .payment)!
        // Neither exact hit contains the date itself (it is outside the quote), so verification
        // looks at the surrounding text; the second line is the one that supports the value.
        let span = matcher.span(for: match.range, quality: match.quality)!
        XCTAssertEqual(span.range.location, (text as NSString).range(of: "The installment", options: .backwards).location)
    }

    func testSameCompanyNameRepeatedIsSupportedAnywhere() {
        let text = "This agreement is between ABC Technologies and Harshit Rana.\nABC Technologies shall pay the fees."
        let (m, _) = mapper(text)
        var r = LLMExtractionResponse()
        r.parties = [.init(name: "ABC Technologies", role: "Client", sourceQuote: "between ABC Technologies and Harshit Rana", page: 1)]
        let f = m.map(r).first!
        XCTAssertEqual(f.valueVerifiedInSource, true)
        XCTAssertTrue(f.source?.quote.hasPrefix("between ABC Technologies") ?? false)
    }

    func testOCRErrorsStillLocateTheRightLine() {
        let text = "Invoice total Rs. 29,500\nPayrnent due within l5 days of the invoice date.\nThank you for your business."
        let doc = DocumentText(plainText: text)
        let match = SourceMatcher(document: doc).locate(quote: "Payment due within 15 days of the invoice date")
        XCTAssertEqual(match?.quality, .fuzzy)
        let span = match.flatMap { doc.span(for: TextRange($0.range), match: $0.quality) }
        XCTAssertTrue(span?.quote.hasPrefix("Payrnent") ?? false, span?.quote ?? "nil")
    }

    func testDeterministicFieldsPointAtTheirOwnOccurrence() {
        let text = """
        SERVICE AGREEMENT
        The total fee is ₹80,000.
        The first installment of ₹40,000 shall be paid on 15/10/2026.
        The second installment of ₹40,000 shall be paid on 15/11/2026.
        """
        let fields = DeterministicExtractor().extract(DocumentText(plainText: text))
        let payments = fields.filter { $0.kind == .payment }
        XCTAssertEqual(payments.count, 2)
        XCTAssertTrue(payments[0].source!.quote.contains("15/10/2026"))
        XCTAssertTrue(payments[1].source!.quote.contains("15/11/2026"))
    }
}

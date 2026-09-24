import XCTest
@testable import DoxiCore

final class SourceMatcherTests: XCTestCase {
    let doc = Fixtures.doc(Fixtures.freelanceContract)
    lazy var matcher = SourceMatcher(document: doc)

    func testExactQuote() {
        let m = matcher.locate(quote: "The total project fee shall be INR 80,000")
        XCTAssertEqual(m?.quality, .exact)
    }

    func testNormalizedQuoteWithDifferentWhitespaceAndQuotes() {
        let m = matcher.locate(quote: "the TOTAL project   fee shall be INR 80,000 (Rupees Eighty Thousand Only).")
        XCTAssertEqual(m?.quality, .normalized)
        let span = m.flatMap { matcher.span(for: $0.range, quality: $0.quality) }
        XCTAssertTrue(span?.quote.hasPrefix("The total project fee") ?? false, span?.quote ?? "nil")
    }

    func testFuzzyQuoteWithOCRNoise() {
        let m = matcher.locate(quote: "Either partv may terminate this Agreernent by giving thirty days prior written notice")
        XCTAssertEqual(m?.quality, .fuzzy)
    }

    func testUnknownQuoteIsNotMatched() {
        XCTAssertNil(matcher.locate(quote: "The client shall pay a bonus of fifty thousand rupees upon launch"))
    }

    func testPreferQuoteOnHintedPage() {
        let d = DocumentText(plainText: "Payment due on signing.\u{0C}Payment due on signing.")
        let m = SourceMatcher(document: d)
        let found = m.locate(quote: "Payment due on signing", page: 1)
        XCTAssertEqual(found.flatMap { m.span(for: $0.range, quality: $0.quality) }?.pageIndex, 1)
    }

    func testValueVerification() {
        let m = matcher.locate(quote: "The first installment of Rs. 40,000/- shall be paid on 15/10/2026.")!
        let ok = PaymentValue(amount: Money(minorUnits: 4_000_000), due: DateValue(date: CalendarDate(year: 2026, month: 10, day: 15)), label: "x")
        XCTAssertEqual(matcher.verify(.payment(ok), in: m.range), .verified)
        let wrong = PaymentValue(amount: Money(minorUnits: 5_000_000), due: nil, label: "x")
        XCTAssertEqual(matcher.verify(.payment(wrong), in: m.range), .notFound)
    }

    func testSpanMapsToPageAndBoxes() {
        let d = DocumentText(pages: [
            PageText(index: 0, source: .ocr, lines: [TextLine(text: "Page one", box: NormalizedRect(x: 0, y: 0.9, width: 1, height: 0.05), confidence: 0.9)]),
            PageText(index: 1, source: .ocr, lines: [
                TextLine(text: "Total fee INR 80,000", box: NormalizedRect(x: 0.1, y: 0.5, width: 0.8, height: 0.04), confidence: 0.4),
            ]),
        ])
        let m = SourceMatcher(document: d)
        let found = m.locate(quote: "INR 80,000")!
        let span = m.span(for: found.range, quality: found.quality)!
        XCTAssertEqual(span.pageIndex, 1)
        XCTAssertEqual(span.quote, "INR 80,000")
        XCTAssertEqual(span.boxes.count, 1)
        XCTAssertEqual(span.boxes[0].x, 0.1 + 0.8 * 10.0 / 20.0, accuracy: 0.0001)
        XCTAssertEqual(span.ocrConfidence, 0.4)
    }

    func testRotationRoundTrip() {
        let r = NormalizedRect(x: 0.1, y: 0.2, width: 0.3, height: 0.05)
        for deg in [0, 90, 180, 270] {
            let back = r.rotated(clockwiseDegrees: deg).unrotated(fromClockwiseDegrees: deg)
            XCTAssertEqual(back.x, r.x, accuracy: 1e-9)
            XCTAssertEqual(back.y, r.y, accuracy: 1e-9)
            XCTAssertEqual(back.width, r.width, accuracy: 1e-9)
        }
        // Top-left corner of a page viewed rotated 90° clockwise is the view's top-right.
        let corner = NormalizedRect(x: 0.9, y: 0.9, width: 0.1, height: 0.1).unrotated(fromClockwiseDegrees: 90)
        XCTAssertEqual(corner.x, 0, accuracy: 1e-9)
        XCTAssertEqual(corner.y, 0.9, accuracy: 1e-9)
    }
}

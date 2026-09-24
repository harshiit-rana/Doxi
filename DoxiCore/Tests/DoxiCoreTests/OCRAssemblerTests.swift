import XCTest
@testable import DoxiCore

final class OCRAssemblerTests: XCTestCase {
    func testJoinsRowFragmentsAndKeepsReadingOrder() {
        let lines = OCRLineAssembler.assemble([
            OCRObservation(text: "₹ 29,500.00", box: NormalizedRect(x: 0.7, y: 0.30, width: 0.2, height: 0.03), confidence: 0.8),
            OCRObservation(text: "TAX INVOICE", box: NormalizedRect(x: 0.3, y: 0.90, width: 0.4, height: 0.04), confidence: 0.99),
            OCRObservation(text: "Grand Total", box: NormalizedRect(x: 0.1, y: 0.305, width: 0.2, height: 0.03), confidence: 0.95),
        ])
        XCTAssertEqual(lines.map(\.text), ["TAX INVOICE", "Grand Total  ₹ 29,500.00"])
        XCTAssertEqual(lines[1].confidence, 0.8)
        XCTAssertEqual(lines[1].parts?.count, 2)
    }

    func testHighlightUsesFragmentBoxes() {
        let lines = OCRLineAssembler.assemble([
            OCRObservation(text: "Grand Total", box: NormalizedRect(x: 0.1, y: 0.3, width: 0.2, height: 0.03), confidence: 0.95),
            OCRObservation(text: "₹ 29,500.00", box: NormalizedRect(x: 0.7, y: 0.3, width: 0.2, height: 0.03), confidence: 0.9),
        ])
        let page = PageText(index: 0, source: .ocr, lines: lines)
        let doc = DocumentText(pages: [page])
        let match = SourceMatcher(document: doc).locate(quote: "₹ 29,500.00")!
        let span = doc.span(for: TextRange(match.range), match: .exact)!
        XCTAssertEqual(span.boxes.count, 1)
        XCTAssertEqual(span.boxes[0].x, 0.7, accuracy: 0.001)
        XCTAssertEqual(span.boxes[0].width, 0.2, accuracy: 0.001)
    }

    func testTwoColumnsOnDifferentRowsStaySeparate() {
        let lines = OCRLineAssembler.assemble([
            OCRObservation(text: "Line one", box: NormalizedRect(x: 0.1, y: 0.8, width: 0.3, height: 0.02), confidence: 1),
            OCRObservation(text: "Line two", box: NormalizedRect(x: 0.1, y: 0.76, width: 0.3, height: 0.02), confidence: 1),
        ])
        XCTAssertEqual(lines.count, 2)
    }
}

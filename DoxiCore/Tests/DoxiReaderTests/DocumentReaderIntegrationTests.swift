#if canImport(PDFKit) && canImport(Vision) && canImport(CoreText)
import CoreGraphics
import CoreText
import DoxiCore
@testable import DoxiReader
import PDFKit
import XCTest

/// End-to-end checks of the on-device reading path with real PDFKit and Vision:
/// PDFs are generated with text at known positions, read, extracted, and the
/// highlight rectangles are compared with where the text was actually drawn.
final class DocumentReaderIntegrationTests: XCTestCase {
    static let pageSize = CGSize(width: 595, height: 842)

    struct Line { var text: String; var y: CGFloat }
    struct Drawn { var text: String; var page: Int; var rect: CGRect }

    static let page1: [Line] = [
        Line(text: "FREELANCE SERVICES AGREEMENT", y: 780),
        Line(text: "This Agreement is made between ABC Technologies Private Limited", y: 740),
        Line(text: "(the Client) and Harshit Rana (the Freelancer).", y: 722),
        Line(text: "This Agreement is effective from 15 September 2026.", y: 690),
        Line(text: "The total project fee shall be INR 80,000.", y: 660),
    ]
    static let page2: [Line] = [
        Line(text: "Payment Schedule", y: 780),
        Line(text: "The first installment of Rs. 40,000 shall be paid on 15/10/2026.", y: 740),
        Line(text: "The second installment of Rs. 40,000 shall be paid on 15/11/2026.", y: 710),
        Line(text: "Either party may terminate with 30 days written notice.", y: 680),
        Line(text: "The total project fee shall be INR 80,000.", y: 650),
    ]

    static let font = CTFontCreateWithName("Helvetica" as CFString, 13, nil)

    static func ctLine(_ text: String) -> CTLine {
        CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: [NSAttributedString.Key(kCTFontAttributeName as String): font]))
    }

    /// Draws lines in "upright" coordinates; returns their rects in the same space.
    static func draw(_ lines: [Line], in ctx: CGContext, page: Int) -> [Drawn] {
        lines.map { line in
            let ct = ctLine(line.text)
            var ascent: CGFloat = 0, descent: CGFloat = 0, leading: CGFloat = 0
            let width = CGFloat(CTLineGetTypographicBounds(ct, &ascent, &descent, &leading))
            ctx.textPosition = CGPoint(x: 50, y: line.y)
            CTLineDraw(ct, ctx)
            return Drawn(text: line.text, page: page, rect: CGRect(x: 50, y: line.y - descent, width: width, height: ascent + descent))
        }
    }

    /// Text-based PDF.
    static func textPDF(_ pages: [[Line]]) -> (Data, [Drawn]) {
        let data = NSMutableData()
        var box = CGRect(origin: .zero, size: pageSize)
        let ctx = CGContext(consumer: CGDataConsumer(data: data)!, mediaBox: &box, nil)!
        var drawn: [Drawn] = []
        for (i, lines) in pages.enumerated() {
            ctx.beginPDFPage(nil)
            drawn += draw(lines, in: ctx, page: i)
            ctx.endPDFPage()
        }
        ctx.closePDF()
        return (data as Data, drawn)
    }

    /// Image-only PDF ("scan"). `sideways` stores the content rotated 90° counter-clockwise
    /// on a portrait page, as a phone photo taken sideways would be.
    static func scannedPDF(_ pages: [[Line]], sideways: Bool = false, scale: CGFloat = 2.5) -> (Data, [Drawn]) {
        let data = NSMutableData()
        var box = CGRect(origin: .zero, size: pageSize)
        let pdf = CGContext(consumer: CGDataConsumer(data: data)!, mediaBox: &box, nil)!
        var drawn: [Drawn] = []
        for (i, lines) in pages.enumerated() {
            let w = Int(pageSize.width * scale), h = Int(pageSize.height * scale)
            let bmp = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue)!
            bmp.setFillColor(gray: 1, alpha: 1)
            bmp.fill(CGRect(x: 0, y: 0, width: w, height: h))
            bmp.setFillColor(gray: 0, alpha: 1)
            bmp.scaleBy(x: scale, y: scale)
            var pageDrawn: [Drawn]
            if sideways {
                // Upright content is landscape (842 x 595); map it onto the portrait page rotated CCW.
                let t = CGAffineTransform(a: 0, b: 1, c: -1, d: 0, tx: pageSize.width, ty: 0)
                bmp.concatenate(t)
                let landscape = lines.map { Line(text: $0.text, y: $0.y - 250) }
                pageDrawn = draw(landscape, in: bmp, page: i).map { d in
                    var d = d
                    d.rect = d.rect.applying(t)
                    return d
                }
            } else {
                pageDrawn = draw(lines, in: bmp, page: i)
            }
            drawn += pageDrawn
            pdf.beginPDFPage(nil)
            pdf.draw(bmp.makeImage()!, in: box)
            pdf.endPDFPage()
        }
        pdf.closePDF()
        return (data as Data, drawn)
    }

    func read(_ data: Data) -> (PDFDocument, [DocumentReader.PageResult]) {
        let pdf = PDFDocument(data: data)!
        return (pdf, DocumentReader().read(pdf))
    }

    /// Share of the drawn rect covered by the union of highlight rects.
    func coverage(_ rects: [CGRect], of target: CGRect) -> CGFloat {
        let inter = rects.map { $0.intersection(target) }.filter { !$0.isNull }.reduce(0) { $0 + $1.width * $1.height }
        return inter / (target.width * target.height)
    }

    func highlight(_ field: ExtractedFieldDraft, pdf: PDFDocument, pages: [PageText]) -> [CGRect] {
        guard let span = field.source, let page = pdf.page(at: span.pageIndex) else { return [] }
        return HighlightGeometry.rects(for: span, on: page, lines: pages.first { $0.index == span.pageIndex }?.lines)
    }

    // MARK: Text PDF

    func testTextPDFExtractionAndExactHighlight() async throws {
        let (data, drawn) = Self.textPDF([Self.page1, Self.page2])
        let (pdf, results) = read(data)
        XCTAssertEqual(results.map(\.text.source), [.pdfText, .pdfText])
        let pages = results.map(\.text)
        let outcome = await ExtractionPipeline().run(DocumentText(pages: pages))

        let total = try XCTUnwrap(outcome.fields.first { $0.kind == .totalAmount })
        XCTAssertEqual(total.value.primaryAmount?.minorUnits, 8_000_000)
        XCTAssertEqual(total.source?.textSource, .pdfText)
        let totalLine = drawn.first { $0.text.hasPrefix("The total") && $0.page == total.source?.pageIndex }!
        XCTAssertGreaterThan(coverage(highlight(total, pdf: pdf, pages: pages), of: totalLine.rect), 0.5)

        let payments = outcome.fields.filter { $0.kind == .payment }
        XCTAssertEqual(payments.map { $0.value.primaryDate?.isoString }, ["2026-10-15", "2026-11-15"])
        for p in payments {
            XCTAssertEqual(p.source?.pageIndex, 1)
            let date = p.value.primaryDate!.numericString
            let line = drawn.first { $0.page == 1 && $0.text.contains(date) }!
            let rects = highlight(p, pdf: pdf, pages: pages)
            XCTAssertGreaterThan(coverage(rects, of: line.rect), 0.3, "highlight for \(date) should cover its own line")
            let other = drawn.first { $0.page == 1 && $0.text.contains("installment") && !$0.text.contains(date) }!
            XCTAssertLessThan(coverage(rects, of: other.rect), 0.05, "highlight must not cover the other installment")
        }
    }

    // MARK: Scanned PDF

    func testScannedPDFUsesOCRBoxesOnTheRightPage() async throws {
        let (data, drawn) = Self.scannedPDF([Self.page1, Self.page2])
        let start = Date()
        let (pdf, results) = read(data)
        print("OCR: 2 scanned pages in \(String(format: "%.2f", Date().timeIntervalSince(start)))s")
        XCTAssertEqual(results.map(\.text.source), [.ocr, .ocr])
        XCTAssertTrue(results.allSatisfy { $0.suggestedRotation == nil })
        let pages = results.map(\.text)
        let doc = DocumentText(pages: pages)
        XCTAssertTrue(doc.fullText.contains("80,000"), doc.fullText)
        let outcome = await ExtractionPipeline().run(doc)

        let payments = outcome.fields.filter { $0.kind == .payment }
        XCTAssertEqual(Set(payments.compactMap { $0.value.primaryDate?.isoString }), ["2026-10-15", "2026-11-15"], "\(outcome.fields.map(\.displayValue))")
        for p in payments {
            XCTAssertEqual(p.source?.textSource, .ocr)
            let date = p.value.primaryDate!.numericString
            let line = drawn.first { $0.page == 1 && $0.text.contains(date) }!
            XCTAssertGreaterThan(coverage(highlight(p, pdf: pdf, pages: pages), of: line.rect), 0.3, "OCR highlight for \(date)")
        }
    }

    func testSidewaysScanIsDetectedAndBoxesMapToPageSpace() async throws {
        let (data, drawn) = Self.scannedPDF([Self.page2], sideways: true)
        let (pdf, results) = read(data)
        let result = try XCTUnwrap(results.first)
        XCTAssertEqual(result.text.source, .ocr)
        XCTAssertNotNil(result.suggestedRotation, "the reader should detect the page is sideways")
        let doc = DocumentText(pages: [result.text])
        XCTAssertTrue(doc.fullText.contains("installment"), doc.fullText)
        let outcome = await ExtractionPipeline().run(doc)
        let payment = try XCTUnwrap(outcome.fields.first { $0.kind == .payment && $0.value.primaryDate?.isoString == "2026-10-15" })
        let line = drawn.first { $0.text.contains("15/10/2026") }!
        XCTAssertGreaterThan(coverage(highlight(payment, pdf: pdf, pages: [result.text]), of: line.rect), 0.3)
    }

    // MARK: Failure cases

    func testBlankPageProducesWarningNotText() {
        let (data, _) = Self.scannedPDF([[]])
        let (_, results) = read(data)
        XCTAssertEqual(results.first?.text.lines.count, 0)
        XCTAssertEqual(results.first?.text.source, TextSource.none)
        XCTAssertNotNil(results.first?.warning)
    }

    func testCorruptedAndEmptyFilesAreRejected() throws {
        let dir = FileManager.default.temporaryDirectory
        let garbage = dir.appendingPathComponent("garbage-\(UUID()).pdf")
        try Data("%PDF-1.4 this is not really a pdf".utf8).write(to: garbage)
        XCTAssertNil(DocumentReader().read(fileURL: garbage))
        let empty = dir.appendingPathComponent("empty-\(UUID()).pdf")
        try Data().write(to: empty)
        XCTAssertNil(DocumentReader().read(fileURL: empty))
    }

    // MARK: Performance (reported in the test log)

    func testLargeTextPDFReadAndExtractTiming() async {
        let pages = (0..<60).map { _ in Self.page1 + Self.page2.map { Line(text: $0.text, y: $0.y - 300) } }
        let (data, _) = Self.textPDF(pages)
        let t0 = Date()
        let (_, results) = read(data)
        let t1 = Date()
        let outcome = await ExtractionPipeline().run(DocumentText(pages: results.map(\.text)))
        let t2 = Date()
        print(String(format: "Performance: 60-page text PDF read %.2fs, extraction %.2fs, %d fields", t1.timeIntervalSince(t0), t2.timeIntervalSince(t1), outcome.fields.count))
        XCTAssertEqual(results.count, 60)
        XCTAssertLessThan(t2.timeIntervalSince(t0), 60)
    }
}
#endif

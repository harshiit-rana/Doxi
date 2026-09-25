#if canImport(PDFKit)
import CoreGraphics
import DoxiCore
import Foundation
import PDFKit

/// Converts a source span into rectangles in PDF page space for highlighting.
/// Text PDFs use the PDF's own glyph bounds (exact); scanned pages use the OCR
/// boxes, which are normalized to the page's crop box.
public enum HighlightGeometry {
    public static func rects(for span: SourceSpan, on page: PDFPage, lines: [TextLine]?) -> [CGRect] {
        var rects: [CGRect] = []
        if span.textSource == .pdfText, let lines {
            let pageText = PageText(index: span.pageIndex, source: .pdfText, lines: lines)
            for seg in pageText.segments(for: span.range) {
                guard let base = lines[seg.line].sourceRange else { continue }
                let range = NSRange(location: base.location + seg.local.location, length: seg.local.length)
                if let selection = page.selection(for: range) {
                    rects += selection.selectionsByLine().map { $0.bounds(for: page) }.filter { $0.width > 0 && $0.height > 0 }
                }
            }
        }
        if rects.isEmpty {
            let crop = page.bounds(for: .cropBox)
            rects = span.boxes.map { b in
                CGRect(x: crop.minX + b.x * crop.width, y: crop.minY + b.y * crop.height,
                       width: b.width * crop.width, height: b.height * crop.height)
            }
        }
        return rects
    }
}
#endif

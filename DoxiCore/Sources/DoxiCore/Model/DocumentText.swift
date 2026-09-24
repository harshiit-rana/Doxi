import Foundation

/// Where a page's text came from.
public enum TextSource: String, Codable, Sendable {
    /// Embedded text of a text-based PDF (PDFKit).
    case pdfText
    /// Vision OCR on a rendered page image.
    case ocr
    /// No text could be read from the page.
    case none
}

/// A range in UTF-16 code units, matching `NSRange` / PDFKit semantics.
public struct TextRange: Codable, Hashable, Sendable {
    public var location: Int
    public var length: Int

    public init(location: Int, length: Int) {
        self.location = location
        self.length = length
    }

    public init(_ range: NSRange) {
        self.init(location: range.location, length: range.length)
    }

    public var nsRange: NSRange { NSRange(location: location, length: length) }
    public var upperBound: Int { location + length }

    public func intersection(_ other: TextRange) -> TextRange? {
        let lo = max(location, other.location), hi = min(upperBound, other.upperBound)
        return hi > lo ? TextRange(location: lo, length: hi - lo) : nil
    }
}

/// One line of text on a page together with its location.
public struct TextLine: Codable, Hashable, Sendable {
    public var text: String
    /// Line bounds in normalized, bottom-left-origin page coordinates.
    public var box: NormalizedRect
    /// Recognition confidence 0...1 (1 for embedded PDF text).
    public var confidence: Double
    /// For PDF text: the range of this line inside `PDFPage.string`, so the viewer
    /// can build an exact `PDFSelection`. `nil` for OCR lines.
    public var sourceRange: TextRange?

    public init(text: String, box: NormalizedRect, confidence: Double = 1, sourceRange: TextRange? = nil) {
        self.text = text
        self.box = box
        self.confidence = confidence
        self.sourceRange = sourceRange
    }
}

/// The recognised text of one page.
public struct PageText: Codable, Hashable, Sendable {
    public var index: Int
    public var source: TextSource
    public var lines: [TextLine]
    /// Clockwise rotation (degrees) that was applied to make the page upright before OCR.
    public var appliedRotation: Int

    public init(index: Int, source: TextSource, lines: [TextLine], appliedRotation: Int = 0) {
        self.index = index
        self.source = source
        self.lines = lines
        self.appliedRotation = appliedRotation
    }

    /// Lines joined with `\n`. All page-local ranges refer to this string.
    public var text: String { lines.map(\.text).joined(separator: "\n") }

    /// Page-local range of each line inside `text`.
    public var lineRanges: [TextRange] {
        var out: [TextRange] = []
        var offset = 0
        for line in lines {
            let len = (line.text as NSString).length
            out.append(TextRange(location: offset, length: len))
            offset += len + 1
        }
        return out
    }

    public var averageConfidence: Double {
        guard !lines.isEmpty else { return 0 }
        return lines.map(\.confidence).reduce(0, +) / Double(lines.count)
    }

    /// The pieces of each line covered by a page-local range.
    public func segments(for range: TextRange) -> [(line: Int, local: TextRange)] {
        var out: [(Int, TextRange)] = []
        for (i, lr) in lineRanges.enumerated() {
            if let inter = lr.intersection(range) {
                out.append((i, TextRange(location: inter.location - lr.location, length: inter.length)))
            }
        }
        return out
    }

    /// Approximate boxes for a page-local range: one per covered line, sliced
    /// horizontally in proportion to the characters covered.
    public func boxes(for range: TextRange) -> [NormalizedRect] {
        segments(for: range).map { seg in
            let line = lines[seg.line]
            let len = max(1, (line.text as NSString).length)
            return line.box.horizontalSlice(from: Double(seg.local.location) / Double(len),
                                            to: Double(seg.local.upperBound) / Double(len))
        }
    }

    /// Lowest line confidence within a range.
    public func minimumConfidence(for range: TextRange) -> Double {
        segments(for: range).map { lines[$0.line].confidence }.min() ?? 0
    }
}

/// The text of a whole document. Extraction works on `fullText`; ranges in it
/// map back to pages and boxes through `span(for:)`.
public struct DocumentText: Codable, Hashable, Sendable {
    public var pages: [PageText]
    public static let pageSeparator = "\n\n"

    public init(pages: [PageText]) {
        self.pages = pages.sorted { $0.index < $1.index }
    }

    /// Convenience for plain text (tests, evaluation of `.txt` fixtures). Pages are
    /// split on form feeds; boxes are synthetic line bands.
    public init(plainText: String) {
        let rawPages = plainText.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\u{0C}")
        self.pages = rawPages.enumerated().map { idx, pageText in
            let lines = pageText.components(separatedBy: "\n")
            let count = max(1, lines.count)
            let textLines = lines.enumerated().map { i, t in
                TextLine(text: t, box: NormalizedRect(x: 0.05, y: 1 - Double(i + 1) / Double(count + 1), width: 0.9, height: 0.8 / Double(count + 1)))
            }
            return PageText(index: idx, source: .pdfText, lines: textLines)
        }
    }

    public var fullText: String { pages.map(\.text).joined(separator: DocumentText.pageSeparator) }

    /// Start offset of each page inside `fullText`.
    public var pageOffsets: [Int] {
        var out: [Int] = []
        var offset = 0
        let sep = (DocumentText.pageSeparator as NSString).length
        for page in pages {
            out.append(offset)
            offset += (page.text as NSString).length + sep
        }
        return out
    }

    public var isEmpty: Bool {
        fullText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// Converts a range in `fullText` to a page-anchored source span. Ranges that
    /// cross a page boundary are clipped to the page where they start.
    public func span(for range: TextRange, match: MatchQuality) -> SourceSpan? {
        let offsets = pageOffsets
        guard let pageIdx = offsets.lastIndex(where: { $0 <= range.location }) else { return nil }
        let page = pages[pageIdx]
        let pageLen = (page.text as NSString).length
        let local = TextRange(location: range.location - offsets[pageIdx], length: range.length)
        guard let clipped = local.intersection(TextRange(location: 0, length: pageLen)) else { return nil }
        let quote = (page.text as NSString).substring(with: clipped.nsRange)
        return SourceSpan(pageIndex: page.index, range: clipped, quote: quote,
                          boxes: page.boxes(for: clipped), textSource: page.source, match: match,
                          ocrConfidence: page.source == .ocr ? page.minimumConfidence(for: clipped) : nil)
    }

    public func page(at index: Int) -> PageText? { pages.first { $0.index == index } }

    /// Range of a page inside `fullText`.
    public func fullTextRange(ofPage index: Int) -> TextRange? {
        guard let i = pages.firstIndex(where: { $0.index == index }) else { return nil }
        return TextRange(location: pageOffsets[i], length: (pages[i].text as NSString).length)
    }
}

/// How a source span was located.
public enum MatchQuality: String, Codable, Sendable, Comparable {
    /// Found by a deterministic rule directly in the text.
    case exact
    /// Quote found after normalising whitespace, case and punctuation.
    case normalized
    /// Quote found approximately (OCR noise or paraphrase).
    case fuzzy
    /// The quote was not found, but the value itself was located in the text.
    case valueOnly

    var rank: Int {
        switch self { case .exact: return 0; case .normalized: return 1; case .fuzzy: return 2; case .valueOnly: return 3 }
    }

    public static func < (lhs: MatchQuality, rhs: MatchQuality) -> Bool { lhs.rank < rhs.rank }
}

/// The location in the original document that an extracted fact came from.
public struct SourceSpan: Codable, Hashable, Sendable {
    /// Zero-based page index.
    public var pageIndex: Int
    /// Range within the page text (`PageText.text`).
    public var range: TextRange
    /// The source text itself.
    public var quote: String
    /// Highlight boxes in normalized page coordinates.
    public var boxes: [NormalizedRect]
    public var textSource: TextSource
    public var match: MatchQuality
    /// Minimum OCR confidence of the covered lines (OCR pages only).
    public var ocrConfidence: Double?

    public init(pageIndex: Int, range: TextRange, quote: String, boxes: [NormalizedRect],
                textSource: TextSource, match: MatchQuality, ocrConfidence: Double? = nil) {
        self.pageIndex = pageIndex
        self.range = range
        self.quote = quote
        self.boxes = boxes
        self.textSource = textSource
        self.match = match
        self.ocrConfidence = ocrConfidence
    }

    /// "Page 2" (1-based for display).
    public var pageLabel: String { "Page \(pageIndex + 1)" }
}

#if canImport(PDFKit) && canImport(Vision)
import CoreGraphics
import DoxiCore
import Foundation
import ImageIO
import PDFKit
import Vision

/// Reads the text of a PDF with source locations: embedded text through PDFKit
/// for text-based pages, Vision OCR for scanned pages. Everything runs on-device.
/// Shared by the iOS app and the macOS evaluation tool so both measure the same path.
public struct DocumentReader: Sendable {
    public struct Options: Sendable {
        /// Pages with fewer non-whitespace characters of embedded text are OCR'd.
        public var minimumEmbeddedCharacters = 25
        /// Longest side of the rendered page image used for OCR, in pixels.
        public var ocrLongestSide: CGFloat = 2600
        /// Below this, OCR is retried in other orientations.
        public var weakOCRCharacterCount = 40

        public init() {}
    }

    public struct PageResult: Sendable {
        public var text: PageText
        /// Clockwise rotation (0/90/180/270) that makes the page upright, when OCR
        /// detected the page was stored sideways. The caller may apply it for display.
        public var suggestedRotation: Int?
        public var warning: String?
    }

    public var options: Options

    public init(options: Options = Options()) {
        self.options = options
    }

    /// Reads every page. Never throws; failures become warnings and empty pages.
    public func read(_ pdf: PDFDocument, progress: (@Sendable (Int, Int) -> Void)? = nil) -> [PageResult] {
        var results: [PageResult] = []
        for i in 0..<pdf.pageCount {
            progress?(i, pdf.pageCount)
            guard let page = pdf.page(at: i) else {
                results.append(PageResult(text: PageText(index: i, source: .none, lines: []), warning: "Page \(i + 1) could not be opened."))
                continue
            }
            // Rendered page images are large; release them page by page on long documents.
            results.append(autoreleasepool { read(page: page, index: i) })
        }
        return results
    }

    public func read(page: PDFPage, index: Int) -> PageResult {
        if let embedded = embeddedText(page: page, index: index) {
            return PageResult(text: embedded)
        }
        return ocr(page: page, index: index)
    }

    // MARK: Embedded PDF text

    func embeddedText(page: PDFPage, index: Int) -> PageText? {
        guard let string = page.string else { return nil }
        let ns = string as NSString
        let meaningful = string.unicodeScalars.filter { !CharacterSet.whitespacesAndNewlines.contains($0) }.count
        guard meaningful >= options.minimumEmbeddedCharacters else { return nil }
        let crop = page.bounds(for: .cropBox)
        var lines: [TextLine] = []
        var start = 0
        var i = 0
        func emit(_ end: Int) {
            let range = NSRange(location: start, length: end - start)
            let text = ns.substring(with: range)
            guard !text.trimmingCharacters(in: .whitespaces).isEmpty else { return }
            var box = NormalizedRect(x: 0, y: 0, width: 0, height: 0)
            if let sel = page.selection(for: range) {
                let b = sel.bounds(for: page)
                if crop.width > 0 && crop.height > 0 {
                    box = NormalizedRect(x: Double((b.minX - crop.minX) / crop.width), y: Double((b.minY - crop.minY) / crop.height),
                                         width: Double(b.width / crop.width), height: Double(b.height / crop.height))
                }
            }
            lines.append(TextLine(text: text, box: box, confidence: 1, sourceRange: TextRange(range)))
        }
        while i < ns.length {
            let c = ns.character(at: i)
            if c == 10 || c == 13 {
                emit(i)
                // Treat \r\n as one break.
                if c == 13, i + 1 < ns.length, ns.character(at: i + 1) == 10 { i += 1 }
                start = i + 1
            }
            i += 1
        }
        if start < ns.length { emit(ns.length) }
        return PageText(index: index, source: .pdfText, lines: lines)
    }

    // MARK: OCR

    func ocr(page: PDFPage, index: Int) -> PageResult {
        guard let image = render(page: page) else {
            return PageResult(text: PageText(index: index, source: .none, lines: []), warning: "Page \(index + 1) could not be rendered for text recognition.")
        }
        let stored = ((page.rotation % 360) + 360) % 360
        var orientations = [stored]
        orientations += [0, 90, 180, 270].filter { $0 != stored }

        var best: (lines: [TextLine], rotation: Int, score: Double)?
        var lastError: String?
        for rotation in orientations {
            do {
                let lines = try recognize(image, clockwiseRotation: rotation)
                let chars = lines.reduce(0) { $0 + $1.text.count }
                let conf = lines.isEmpty ? 0 : lines.map(\.confidence).reduce(0, +) / Double(lines.count)
                let score = Double(chars) * conf
                if best == nil || score > best!.score { best = (lines, rotation, score) }
                if rotation == stored && chars >= options.weakOCRCharacterCount && conf >= 0.4 { break }
            } catch {
                lastError = error.localizedDescription
            }
        }
        guard let b = best, !b.lines.isEmpty else {
            return PageResult(text: PageText(index: index, source: .none, lines: []),
                              warning: "Page \(index + 1) appears blank or unreadable" + (lastError.map { " (\($0))" } ?? "") + ".")
        }
        let avg = b.lines.map(\.confidence).reduce(0, +) / Double(b.lines.count)
        return PageResult(text: PageText(index: index, source: .ocr, lines: b.lines, appliedRotation: b.rotation),
                          suggestedRotation: b.rotation != stored ? b.rotation : nil,
                          warning: avg < 0.5 ? "Page \(index + 1) is hard to read; check extracted details carefully." : nil)
    }

    /// Renders the page's crop box in unrotated page space, so recognised boxes
    /// are directly in page coordinates.
    func render(page: PDFPage) -> CGImage? {
        guard let cgPage = page.pageRef else { return nil }
        let crop = page.bounds(for: .cropBox)
        guard crop.width > 0, crop.height > 0 else { return nil }
        let scale = min(4, options.ocrLongestSide / max(crop.width, crop.height))
        let width = Int(crop.width * scale), height = Int(crop.height * scale)
        guard let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return nil }
        ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        ctx.interpolationQuality = .high
        ctx.scaleBy(x: scale, y: scale)
        ctx.translateBy(x: -crop.minX, y: -crop.minY)
        ctx.drawPDFPage(cgPage)
        return ctx.makeImage()
    }

    static func orientation(forClockwiseRotation degrees: Int) -> CGImagePropertyOrientation {
        switch degrees {
        case 90: return .right
        case 180: return .down
        case 270: return .left
        default: return .up
        }
    }

    /// Recognises text treating the image as needing `clockwiseRotation` to be upright;
    /// returned boxes are mapped back to the unrotated image (page) space.
    func recognize(_ image: CGImage, clockwiseRotation: Int) throws -> [TextLine] {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true
        let preferred = ["en-IN", "en-US", "en-GB"]
        if let supported = try? request.supportedRecognitionLanguages() {
            let langs = preferred.filter { supported.contains($0) }
            request.recognitionLanguages = langs.isEmpty ? ["en-US"] : langs
        }
        let handler = VNImageRequestHandler(cgImage: image, orientation: DocumentReader.orientation(forClockwiseRotation: clockwiseRotation), options: [:])
        try handler.perform([request])
        let observations = (request.results ?? []).compactMap { obs -> OCRObservation? in
            guard let candidate = obs.topCandidates(1).first else { return nil }
            let b = obs.boundingBox
            let upright = NormalizedRect(x: Double(b.minX), y: Double(b.minY), width: Double(b.width), height: Double(b.height))
            return OCRObservation(text: candidate.string, box: upright, confidence: Double(candidate.confidence))
        }
        // Assemble rows in upright space (reading order), then map boxes to page space.
        return OCRLineAssembler.assemble(observations).map { line in
            var l = line
            l.box = line.box.unrotated(fromClockwiseDegrees: clockwiseRotation)
            l.parts = line.parts?.map { TextLinePart(range: $0.range, box: $0.box.unrotated(fromClockwiseDegrees: clockwiseRotation)) }
            return l
        }
    }

    /// Convenience for evaluation and tests: reads a PDF or image file.
    public func read(fileURL: URL) -> [PageResult]? {
        if fileURL.pathExtension.lowercased() == "pdf" {
            guard let pdf = PDFDocument(url: fileURL) else { return nil }
            return read(pdf)
        }
        guard let source = CGImageSourceCreateWithURL(fileURL as CFURL, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { return nil }
        let lines = (try? recognize(image, clockwiseRotation: 0)) ?? []
        return [PageResult(text: PageText(index: 0, source: lines.isEmpty ? .none : .ocr, lines: lines))]
    }
}
#endif

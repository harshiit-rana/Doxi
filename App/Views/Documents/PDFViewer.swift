import DoxiCore
import PDFKit
import SwiftUI

/// PDFKit viewer that can jump to and highlight a source span.
struct PDFKitView: UIViewRepresentable {
    let url: URL
    var highlight: SourceSpan?
    /// Stored lines of the highlighted page (exact selection for PDF text).
    var pageLines: [TextLine]?

    func makeUIView(context: Context) -> PDFView {
        let view = PDFView()
        view.autoScales = true
        view.displayMode = .singlePageContinuous
        view.displayDirection = .vertical
        view.document = PDFDocument(url: url)
        view.backgroundColor = .secondarySystemBackground
        return view
    }

    func updateUIView(_ view: PDFView, context: Context) {
        context.coordinator.apply(highlight, lines: pageLines, in: view)
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator {
        private var annotations: [(PDFPage, PDFAnnotation)] = []
        private var applied: SourceSpan?

        func apply(_ span: SourceSpan?, lines: [TextLine]?, in view: PDFView) {
            guard span != applied else { return }
            applied = span
            for (page, annotation) in annotations { page.removeAnnotation(annotation) }
            annotations.removeAll()
            guard let span, let document = view.document, let page = document.page(at: span.pageIndex) else { return }

            var rects: [CGRect] = []
            if span.textSource == .pdfText, let lines {
                // Exact glyph bounds from the PDF's own text layer.
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
                // OCR boxes (normalized, bottom-left origin, relative to the crop box).
                let crop = page.bounds(for: .cropBox)
                rects = span.boxes.map { b in
                    CGRect(x: crop.minX + b.x * crop.width, y: crop.minY + b.y * crop.height,
                           width: b.width * crop.width, height: b.height * crop.height)
                }
            }
            for rect in rects {
                let r = rect.insetBy(dx: -2, dy: -1)
                let annotation = PDFAnnotation(bounds: r, forType: .highlight, withProperties: nil)
                annotation.color = UIColor.systemYellow.withAlphaComponent(0.55)
                annotation.quadrilateralPoints = [
                    NSValue(cgPoint: CGPoint(x: 0, y: r.height)), NSValue(cgPoint: CGPoint(x: r.width, y: r.height)),
                    NSValue(cgPoint: CGPoint(x: 0, y: 0)), NSValue(cgPoint: CGPoint(x: r.width, y: 0)),
                ]
                page.addAnnotation(annotation)
                annotations.append((page, annotation))
            }
            if let first = rects.first {
                let union = rects.dropFirst().reduce(first) { $0.union($1) }
                view.go(to: union.insetBy(dx: -60, dy: -120), on: page)
            } else {
                view.go(to: page)
            }
        }
    }
}

/// Shows the original document with one source highlighted.
struct SourceSheet: View {
    let document: DocumentRecord
    let source: SourceSpan
    var fieldLabel: String?
    @Environment(AppServices.self) private var services
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                PDFKitView(url: services.fileStore.url(for: document.storedFilename), highlight: source,
                           pageLines: document.sortedPages.first { $0.index == source.pageIndex }?.pageText.lines)
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text(source.pageLabel).font(.subheadline.weight(.semibold))
                        Spacer()
                        Text(matchDescription).font(.caption).foregroundStyle(.secondary)
                    }
                    Text("“\(source.quote.collapsedWhitespace)”").font(.callout)
                    if let conf = source.ocrConfidence, conf < 0.5 {
                        Label("This part of the scan was hard to read.", systemImage: "exclamationmark.triangle")
                            .font(.caption).foregroundStyle(.orange)
                    }
                }
                .padding()
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(.bar)
            }
            .navigationTitle(fieldLabel ?? "Source")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        }
    }

    var matchDescription: String {
        switch source.match {
        case .exact: return source.textSource == .ocr ? "Found in scanned text" : "Exact text"
        case .normalized: return "Exact text (formatting differs)"
        case .fuzzy: return "Approximate match"
        case .valueOnly: return "Value found here; quote not found"
        }
    }
}

/// The whole original document.
struct OriginalDocumentView: View {
    let document: DocumentRecord
    @Environment(AppServices.self) private var services

    var body: some View {
        PDFKitView(url: services.fileStore.url(for: document.storedFilename))
            .ignoresSafeArea(edges: .bottom)
            .navigationTitle(document.title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    ShareLink(item: services.fileStore.url(for: document.storedFilename)) {
                        Label("Share", systemImage: "square.and.arrow.up")
                    }
                }
            }
    }
}

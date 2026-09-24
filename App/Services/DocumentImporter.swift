import Foundation
import PDFKit
import SwiftData
import UIKit
import UniformTypeIdentifiers

enum ImportError: LocalizedError {
    case unreadable(String)
    case unsupported(String)
    case emptyPDF(String)
    case locked(String)

    var errorDescription: String? {
        switch self {
        case .unreadable(let name): return "“\(name)” could not be read."
        case .unsupported(let name): return "“\(name)” is not a PDF or image. Doxi can import PDFs and photos of documents."
        case .emptyPDF(let name): return "“\(name)” has no pages."
        case .locked(let name): return "“\(name)” is password protected. Remove the password and import it again."
        }
    }
}

/// Turns incoming files and scans into stored PDFs and library records. Every
/// document is stored as a PDF so the viewer and source highlighting work the
/// same way for scans, photos and PDFs.
@MainActor
struct DocumentImporter {
    let fileStore: FileStore

    func importFile(at url: URL, origin: DocumentOrigin, context: ModelContext) throws -> DocumentRecord {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        let name = url.lastPathComponent
        guard let data = try? Data(contentsOf: url) else { throw ImportError.unreadable(name) }
        let type = UTType(filenameExtension: url.pathExtension.lowercased())
        let pdfData: Data
        if type?.conforms(to: .pdf) == true || data.starts(with: Array("%PDF".utf8)) {
            guard let pdf = PDFDocument(data: data) else { throw ImportError.unreadable(name) }
            if pdf.isLocked { throw ImportError.locked(name) }
            guard pdf.pageCount > 0 else { throw ImportError.emptyPDF(name) }
            pdfData = data
        } else if type?.conforms(to: .image) == true || UIImage(data: data) != nil {
            guard let image = UIImage(data: data) else { throw ImportError.unreadable(name) }
            pdfData = PDFBuilder.pdf(from: [image])
        } else {
            throw ImportError.unsupported(name)
        }
        let stored = try fileStore.write(pdfData)
        let record = DocumentRecord(title: url.deletingPathExtension().lastPathComponent, originalFilename: name,
                                    storedFilename: stored, origin: origin)
        context.insert(record)
        try context.save()
        return record
    }

    func importScan(pages: [UIImage], context: ModelContext) throws -> DocumentRecord {
        let data = PDFBuilder.pdf(from: pages)
        let stored = try fileStore.write(data)
        let title = "Scan " + Date.now.formatted(date: .abbreviated, time: .shortened)
        let record = DocumentRecord(title: title, originalFilename: title + ".pdf", storedFilename: stored, origin: .scan)
        context.insert(record)
        try context.save()
        return record
    }
}

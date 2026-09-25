#if DEBUG
import Foundation
import SwiftData
import UIKit

/// Test-only support, compiled into Debug builds and active only when the app is
/// launched by the UI tests with `-uitest`. It never runs in normal use.
enum UITestSupport {
    static var isActive: Bool { ProcessInfo.processInfo.arguments.contains("-uitest") }
    static var shouldSeed: Bool { ProcessInfo.processInfo.arguments.contains("-uitest-seed") }

    static func freshDefaults() -> UserDefaults {
        let defaults = UserDefaults(suiteName: "doxi.uitest")!
        defaults.removePersistentDomain(forName: "doxi.uitest")
        return defaults
    }

    /// Dates relative to today so the dashboard windows are predictable.
    static func date(_ days: Int) -> String {
        let d = Calendar.current.date(byAdding: .day, value: days, to: .now)!
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "dd/MM/yyyy"
        return f.string(from: d)
    }

    static var contractLines: [String] {
        [
            "FREELANCE SERVICES AGREEMENT",
            "This Agreement is made between ABC Technologies Private Limited",
            "(hereinafter referred to as the \"Client\") and Harshit Rana",
            "(hereinafter referred to as the \"Freelancer\").",
            "This Agreement shall be effective from \(date(-10)) and shall remain in force until \(date(120)).",
            "The total project fee shall be INR 80,000.",
            "The first installment of Rs. 40,000 shall be paid on \(date(20)).",
            "The second installment of Rs. 40,000 shall be paid on \(date(50)).",
            "Either party may terminate by giving thirty (30) days' prior written notice.",
        ]
    }

    static var invoiceLines: [String] {
        [
            "TAX INVOICE",
            "Rana Digital Studio",
            "Invoice No: RDS/26/044",
            "Invoice Date: \(date(-5))",
            "Due Date: \(date(25))",
            "Bill To: Greenleaf Organics",
            "Website maintenance retainer",
            "Grand Total Rs. 29,500",
        ]
    }

    /// A text-based PDF.
    static func textPDF(_ lines: [String]) -> Data {
        let bounds = CGRect(x: 0, y: 0, width: 595, height: 842)
        return UIGraphicsPDFRenderer(bounds: bounds).pdfData { ctx in
            ctx.beginPage()
            draw(lines)
        }
    }

    /// An image-only PDF, like a phone scan: no embedded text, OCR required.
    static func scannedPDF(_ lines: [String]) -> Data {
        let image = UIGraphicsImageRenderer(size: CGSize(width: 1240, height: 1754)).image { ctx in
            UIColor.white.setFill()
            ctx.fill(CGRect(x: 0, y: 0, width: 1240, height: 1754))
            ctx.cgContext.scaleBy(x: 2.08, y: 2.08)
            draw(lines)
        }
        return PDFBuilder.pdf(from: [image])
    }

    static func draw(_ lines: [String]) {
        let attrs: [NSAttributedString.Key: Any] = [.font: UIFont.systemFont(ofSize: 12), .foregroundColor: UIColor.black]
        for (i, line) in lines.enumerated() {
            (line as NSString).draw(in: CGRect(x: 40, y: 50 + CGFloat(i) * 26, width: 520, height: 24), withAttributes: attrs)
        }
    }

    @MainActor
    static func seed(services: AppServices, context: ModelContext) {
        let dir = FileManager.default.temporaryDirectory
        let files: [(String, Data)] = [
            ("client_contract.pdf", textPDF(contractLines)),
            ("whatsapp_invoice_scan.pdf", scannedPDF(invoiceLines)),
        ]
        for (name, data) in files {
            let url = dir.appendingPathComponent(name)
            try? data.write(to: url)
            if let doc = try? services.importer.importFile(at: url, origin: .importFile, context: context) {
                services.process(doc, context: context)
            }
            try? FileManager.default.removeItem(at: url)
        }
    }
}
#endif

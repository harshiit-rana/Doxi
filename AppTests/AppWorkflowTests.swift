import DoxiCore
import SwiftData
import UIKit
import XCTest
@testable import Doxi

@MainActor
final class AppWorkflowTests: XCTestCase {
    var container: ModelContainer!
    var context: ModelContext!
    var settings: AppSettings!

    override func setUp() async throws {
        let schema = Schema(DoxiSchema.models)
        container = try ModelContainer(for: schema, configurations: ModelConfiguration(schema: schema, isStoredInMemoryOnly: true))
        context = container.mainContext
        settings = AppSettings(defaults: .standard)
    }

    func confirmedDocument() async -> DocumentRecord {
        let text = DocumentText(plainText: """
        FREELANCE SERVICES AGREEMENT
        This Agreement is made between ABC Technologies Private Limited (hereinafter referred to as the "Client") and Harshit Rana (hereinafter referred to as the "Freelancer").
        The first installment of Rs. 40,000/- shall be paid on 15/10/2030.
        The second installment of Rs. 40,000/- shall be paid on 15/11/2030.
        """)
        let doc = DocumentRecord(title: "c", originalFilename: "c.pdf", storedFilename: "c.pdf", origin: .importFile)
        context.insert(doc)
        doc.pages = text.pages.map(DocumentPageRecord.init(page:))
        let processor = DocumentProcessor(fileStore: FileStore(root: FileManager.default.temporaryDirectory), settings: settings)
        processor.apply(await ExtractionPipeline().run(text), to: doc, context: context, profile: IdentityProfile(name: "Harshit Rana"))
        return doc
    }

    func testRemindersOnlyForConfirmedOpenObligations() async {
        let doc = await confirmedDocument()
        let service = ObligationService(settings: settings)
        // Before confirmation: no obligations, no reminders.
        XCTAssertTrue(NotificationScheduler.candidates(from: doc.obligations, today: CalendarDate(iso: "2030-09-01")!).isEmpty)
        for f in doc.fields where f.kind == .payment { service.confirm(f, in: doc) }
        service.finalize(doc, context: context)
        let today = CalendarDate(iso: "2030-09-01")!
        XCTAssertEqual(NotificationScheduler.candidates(from: doc.obligations, today: today).count, 2)
        // Completing one payment removes its reminders.
        let first = doc.obligations.min { ($0.dueDateISO ?? "") < ($1.dueDateISO ?? "") }!
        service.markDone(first)
        XCTAssertEqual(first.storedStatus, .received)
        XCTAssertEqual(NotificationScheduler.candidates(from: doc.obligations, today: today).count, 1)
        // Cancelling the other removes the rest.
        let second = doc.obligations.first { $0.id != first.id }!
        service.setStatus(second, .cancelled)
        XCTAssertTrue(NotificationScheduler.candidates(from: doc.obligations, today: today).isEmpty)
    }

    func testEditedAmountIsWhatGetsTracked() async {
        let doc = await confirmedDocument()
        let service = ObligationService(settings: settings)
        let payment = doc.fields.filter { $0.kind == .payment }.min { ($0.value.primaryDate?.isoString ?? "") < ($1.value.primaryDate?.isoString ?? "") }!
        guard case .payment(var p) = payment.value else { return XCTFail() }
        p.amount = Money(minorUnits: 4_500_000)
        service.edit(payment, value: .payment(p), in: doc)
        service.finalize(doc, context: context)
        XCTAssertEqual(doc.obligations.count, 1)
        XCTAssertEqual(doc.obligations[0].amount, Money(minorUnits: 4_500_000))
        XCTAssertTrue(doc.obligations[0].source?.quote.contains("40,000") ?? false)
    }

    func testReExtractionKeepsConfirmedDocumentTracked() async {
        let doc = await confirmedDocument()
        let service = ObligationService(settings: settings)
        for f in doc.fields where f.kind == .payment { service.confirm(f, in: doc) }
        service.finalize(doc, context: context)
        let processor = DocumentProcessor(fileStore: FileStore(root: FileManager.default.temporaryDirectory), settings: settings)
        processor.apply(await ExtractionPipeline().run(doc.documentText), to: doc, context: context, profile: nil)
        XCTAssertEqual(doc.status, .confirmed)
        XCTAssertEqual(doc.fields.filter { $0.kind == .payment && $0.verification == .confirmed }.count, 2)
        XCTAssertEqual(doc.fields.filter { $0.kind == .payment }.count, 2, "re-extraction must not duplicate confirmed details")
        XCTAssertFalse(NotificationScheduler.candidates(from: doc.obligations, today: CalendarDate(iso: "2030-09-01")!).isEmpty)
    }

    func testUndeterminedIdentityLeavesDirectionUnknown() async {
        let doc = await confirmedDocument()
        let service = ObligationService(settings: settings)
        service.setIdentity(doc, partyName: nil) // "Neither / Other"
        for f in doc.fields where f.kind == .payment { service.confirm(f, in: doc) }
        service.finalize(doc, context: context)
        XCTAssertTrue(doc.obligations.allSatisfy { $0.direction == .notMine })
    }

    func testShareInboxImportsAndCleansUp() throws {
        let inbox = FileManager.default.temporaryDirectory.appendingPathComponent("inbox-\(UUID())")
        try FileManager.default.createDirectory(at: inbox, withIntermediateDirectories: true)
        let pdf = PDFBuilder.pdf(from: [UIImage(systemName: "doc")!])
        try pdf.write(to: inbox.appendingPathComponent("1727200000000_client contract.pdf"))
        try Data("not a document".utf8).write(to: inbox.appendingPathComponent("1727200000001_notes.txt"))
        let importer = DocumentImporter(fileStore: FileStore(root: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)))
        let result = ShareInbox.importPending(importer: importer, context: context, inbox: inbox)
        XCTAssertEqual(result.imported.map(\.originalFilename), ["client contract.pdf"])
        XCTAssertEqual(result.imported.first?.origin, .share)
        XCTAssertEqual(result.errors.count, 1)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: inbox.path), [], "inbox must be emptied")
    }

    func testCorruptedAndUnsupportedImportsFailGracefully() throws {
        let dir = FileManager.default.temporaryDirectory
        let importer = DocumentImporter(fileStore: FileStore(root: dir.appendingPathComponent(UUID().uuidString)))
        let bad = dir.appendingPathComponent("broken.pdf")
        try Data("%PDF-1.4 garbage".utf8).write(to: bad)
        XCTAssertThrowsError(try importer.importFile(at: bad, origin: .importFile, context: context))
        let txt = dir.appendingPathComponent("notes.txt")
        try Data("hello".utf8).write(to: txt)
        XCTAssertThrowsError(try importer.importFile(at: txt, origin: .importFile, context: context))
        XCTAssertTrue(try context.fetch(FetchDescriptor<DocumentRecord>()).isEmpty)
    }

    func testDocumentProcessedBeforeProfileIsMatchedLater() async {
        let text = DocumentText(plainText: "FREELANCE AGREEMENT\nThis Agreement is made between ABC Technologies (hereinafter referred to as the \"Client\") and Harshit Rana (hereinafter referred to as the \"Freelancer\").")
        let doc = DocumentRecord(title: "x", originalFilename: "x.pdf", storedFilename: "x.pdf", origin: .share)
        context.insert(doc)
        let processor = DocumentProcessor(fileStore: FileStore(root: FileManager.default.temporaryDirectory), settings: settings)
        processor.apply(await ExtractionPipeline().run(text), to: doc, context: context, profile: nil)
        XCTAssertEqual(doc.identityDecision, .undetermined)
        processor.matchIdentity(doc, profile: IdentityProfile(name: "Harshit Rana"))
        XCTAssertEqual(doc.identityDecision, .automatic)
        XCTAssertEqual(doc.userPartyName, "Harshit Rana")
    }
}

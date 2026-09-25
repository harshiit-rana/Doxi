import DoxiCore
import SwiftData
import UIKit
import XCTest
@testable import Doxi

/// Persistence round-trips and the review → obligation flow against an
/// in-memory SwiftData store (the extraction logic itself is tested in DoxiCore).
@MainActor
final class AppModelTests: XCTestCase {
    var container: ModelContainer!
    var context: ModelContext!

    override func setUp() async throws {
        let schema = Schema(DoxiSchema.models)
        container = try ModelContainer(for: schema, configurations: ModelConfiguration(schema: schema, isStoredInMemoryOnly: true))
        context = container.mainContext
    }

    let contract = """
    FREELANCE SERVICES AGREEMENT
    This Agreement is made between ABC Technologies Private Limited (hereinafter referred to as the "Client") and Harshit Rana (hereinafter referred to as the "Freelancer").
    This Agreement shall be effective from 15 September 2026 and shall remain in force until 15 December 2026.
    The first installment of Rs. 40,000/- shall be paid on 15/10/2026.
    The second installment of Rs. 40,000/- shall be paid on 15/11/2026.
    """

    func makeDocument() async -> DocumentRecord {
        let doc = DocumentRecord(title: "contract", originalFilename: "contract.pdf", storedFilename: "x.pdf", origin: .importFile)
        context.insert(doc)
        let text = DocumentText(plainText: contract)
        doc.pages = text.pages.map(DocumentPageRecord.init(page:))
        doc.fullText = text.fullText
        let outcome = await ExtractionPipeline().run(text)
        let processor = DocumentProcessor(fileStore: FileStore(root: FileManager.default.temporaryDirectory), settings: AppSettings(defaults: UserDefaults(suiteName: "test")!))
        processor.apply(outcome, to: doc, context: context, profile: IdentityProfile(name: "Harshit Rana"))
        return doc
    }

    func testFieldRecordRoundTrip() async {
        let doc = await makeDocument()
        let payment = doc.fields.first { $0.kind == .payment }
        XCTAssertNotNil(payment?.source)
        XCTAssertEqual(payment?.value.primaryAmount, Money(minorUnits: 4_000_000))
        XCTAssertEqual(doc.documentText.fullText, DocumentText(plainText: contract).fullText)
    }

    func testIdentityMatchedAutomaticallyAndTitleUpdated() async {
        let doc = await makeDocument()
        XCTAssertEqual(doc.userPartyName, "Harshit Rana")
        XCTAssertEqual(doc.identityDecision, .automatic)
        XCTAssertEqual(doc.title, "ABC Technologies Private Limited — Freelance Agreement")
        XCTAssertEqual(doc.status, .needsReview)
    }

    func testFinalizeCreatesObligationsOnlyFromConfirmedFields() async {
        let doc = await makeDocument()
        let service = ObligationService(settings: AppSettings(defaults: UserDefaults(suiteName: "test")!))
        let payments = doc.fields.filter { $0.kind == .payment }.sorted { ($0.value.primaryDate ?? CalendarDate(iso: "9999-01-01")!) < ($1.value.primaryDate ?? CalendarDate(iso: "9999-01-01")!) }
        service.confirm(payments[0], in: doc)
        service.finalize(doc, context: context)
        XCTAssertEqual(doc.obligations.filter(\.isPayment).count, 1)
        XCTAssertEqual(doc.obligations.first?.direction, .owedToMe)

        // Marking received never happens automatically; do it and check the status.
        let ob = doc.obligations.first!
        XCTAssertEqual(ob.status(today: CalendarDate(iso: "2026-12-01")!), .overdue)
        service.markDone(ob)
        XCTAssertEqual(ob.storedStatus, .received)
    }

    func testRecurringObligationAdvances() {
        let draft = ObligationDraft(category: .payment, title: "Rent", detail: "", amount: Money(minorUnits: 2_500_000),
                                    dueDate: CalendarDate(iso: "2026-07-05"), dueDateExplanation: nil,
                                    recurrence: Recurrence(frequency: .monthly), responsibleParty: nil, counterparty: nil,
                                    direction: .iOwe, directionReason: nil, status: .pending, sourceFieldID: nil, source: nil)
        let ob = ObligationRecord(draft: draft, reminderOffsets: [3])
        context.insert(ob)
        ObligationService(settings: AppSettings(defaults: UserDefaults(suiteName: "test")!)).markDone(ob)
        XCTAssertEqual(ob.dueDate?.isoString, "2026-08-05")
        XCTAssertEqual(ob.storedStatus, .pending)
        XCTAssertEqual(ob.history.count, 1)
    }
}

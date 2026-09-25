import DoxiCore
import DoxiReader
import Foundation
import Observation
import PDFKit
import SwiftData

/// Runs the processing pipeline for a document:
/// page text (PDF text or OCR) → extraction → source matching → confidence →
/// identity matching → ready for review. Failures never lose the document; the
/// user can always open it and add details manually.
@MainActor
@Observable
final class DocumentProcessor {
    private let fileStore: FileStore
    private let settings: AppSettings
    /// Documents currently being processed.
    private(set) var inFlight: Set<UUID> = []
    /// Documents whose text is currently with a cloud provider.
    private(set) var cloudInFlight: Set<UUID> = []
    /// Page reading progress (page being read, total pages) for documents being read.
    private(set) var readingProgress: [UUID: (page: Int, total: Int)] = [:]

    init(fileStore: FileStore, settings: AppSettings) {
        self.fileStore = fileStore
        self.settings = settings
    }

    struct ReadOutput: Sendable {
        var pages: [PageText]
        var warnings: [String]
        var rotatedPDF: Data?
        var failure: String?
    }

    // MARK: Full processing

    func process(_ doc: DocumentRecord, context: ModelContext, profile: IdentityProfile?) async {
        guard !inFlight.contains(doc.id) else { return }
        inFlight.insert(doc.id)
        defer { inFlight.remove(doc.id) }

        doc.status = .readingText
        doc.processingMessage = nil
        try? context.save()

        let url = fileStore.url(for: doc.storedFilename)
        let docID = doc.id
        let report: @Sendable (Int, Int) -> Void = { page, total in
            Task { @MainActor [weak self] in
                guard let self, self.inFlight.contains(docID) else { return }
                self.readingProgress[docID] = (page + 1, total)
            }
        }
        defer { readingProgress[docID] = nil }
        let read = await Task.detached(priority: .userInitiated) { () -> ReadOutput in
            guard let pdf = PDFDocument(url: url) else {
                return ReadOutput(pages: [], warnings: [], rotatedPDF: nil, failure: "The file could not be opened as a PDF.")
            }
            if pdf.isLocked {
                return ReadOutput(pages: [], warnings: [], rotatedPDF: nil, failure: "This PDF is password protected.")
            }
            guard pdf.pageCount > 0 else {
                return ReadOutput(pages: [], warnings: [], rotatedPDF: nil, failure: "The PDF has no pages.")
            }
            let results = DocumentReader().read(pdf, progress: report)
            var rotated = false
            for (i, r) in results.enumerated() {
                if let rotation = r.suggestedRotation, let page = pdf.page(at: i) {
                    page.rotation = rotation
                    rotated = true
                }
            }
            return ReadOutput(pages: results.map(\.text), warnings: results.compactMap(\.warning),
                              rotatedPDF: rotated ? pdf.dataRepresentation() : nil, failure: nil)
        }.value

        readingProgress[docID] = nil
        if let failure = read.failure {
            doc.status = .failed
            doc.processingMessage = failure
            try? context.save()
            return
        }
        if let data = read.rotatedPDF {
            try? fileStore.overwrite(data, storedFilename: doc.storedFilename)
        }
        for page in doc.pages { context.delete(page) }
        doc.pages = read.pages.map(DocumentPageRecord.init(page:))
        doc.pageCount = read.pages.count
        let text = DocumentText(pages: read.pages)
        doc.fullText = text.fullText
        doc.textAmounts = SearchableDocument.amounts(in: doc.fullText).map { Int($0) }
        let sources = Set(read.pages.map(\.source))
        doc.textSourceSummary = sources == [.pdfText] ? "PDF text" : sources == [.ocr] ? "Scanned (OCR)" : sources == [.none] ? "No readable text" : "PDF text and OCR"
        doc.warnings = read.warnings
        try? context.save()

        var provider: (any ExtractionProvider)?
        if settings.cloudExtractionEnabled && settings.cloudForNewDocuments, let key = KeychainStore.get(KeychainStore.anthropicAccount) {
            provider = AnthropicExtractionProvider(apiKey: key, model: settings.cloudModel)
        } else if settings.useOnDeviceModel {
            provider = OnDeviceModel.makeProvider()
        }
        await extract(doc, text: text, provider: provider, context: context, profile: profile)
    }

    /// Explicit, user-initiated cloud extraction for one document.
    func runCloudExtraction(_ doc: DocumentRecord, context: ModelContext, profile: IdentityProfile?) async {
        guard let key = KeychainStore.get(KeychainStore.anthropicAccount), !key.isEmpty else {
            doc.processingMessage = ExtractionProviderError.missingAPIKey.errorDescription
            try? context.save()
            return
        }
        guard !inFlight.contains(doc.id) else { return }
        inFlight.insert(doc.id)
        defer { inFlight.remove(doc.id) }
        let provider = AnthropicExtractionProvider(apiKey: key, model: settings.cloudModel)
        await extract(doc, text: doc.documentText, provider: provider, context: context, profile: profile)
    }

    private func extract(_ doc: DocumentRecord, text: DocumentText, provider: (any ExtractionProvider)?,
                         context: ModelContext, profile: IdentityProfile?) async {
        doc.status = .extracting
        try? context.save()
        if provider?.sendsDataOffDevice == true { cloudInFlight.insert(doc.id) }
        let outcome = await ExtractionPipeline(provider: provider).run(text)
        cloudInFlight.remove(doc.id)
        apply(outcome, to: doc, context: context, profile: profile)
    }

    // MARK: Applying results

    /// Replaces unreviewed fields with the new results, keeping everything the user
    /// confirmed, edited or added.
    func apply(_ outcome: ExtractionOutcome, to doc: DocumentRecord, context: ModelContext, profile: IdentityProfile?) {
        let kept = doc.fields.filter { $0.verification.isAccepted || $0.origin == .user || $0.verification == .rejected }
        for field in doc.fields where !kept.contains(where: { $0.id == field.id }) {
            context.delete(field)
        }
        var records = kept
        var index = (kept.map(\.sortIndex).max() ?? 0) + 1
        for draft in outcome.fields {
            if kept.contains(where: { $0.kind == draft.kind && FieldMerger.equivalent($0.value, draft.value) }) { continue }
            records.append(ExtractedFieldRecord(draft: draft, sortIndex: index))
            index += 1
        }
        doc.fields = records

        if outcome.sentOffDevice && outcome.providerError == nil { doc.sentToCloud = true }
        if outcome.providerError == nil, let name = outcome.providerName { doc.extractionProviderName = name }
        doc.warnings = Array(Set(doc.warnings + outcome.warnings)).sorted()
        doc.processingMessage = outcome.providerError?.errorDescription

        if let typeField = records.first(where: { $0.kind == .documentType && $0.verification != .rejected }),
           case .documentType(let t) = typeField.value {
            doc.documentType = t
        }
        matchIdentity(doc, profile: profile)
        updateTitle(doc)
        // A document the user already confirmed stays tracked (its obligations and
        // reminders keep working); new unchecked details show up as "to check".
        doc.status = doc.confirmedAt != nil ? .confirmed : .needsReview
        try? context.save()
    }

    /// Decides which party is the user when the profile matches exactly one party.
    func matchIdentity(_ doc: DocumentRecord, profile: IdentityProfile?) {
        guard doc.identityDecision != .userChosen else { return }
        let parties = doc.partyNames
        guard let profile, case .matched(let index, _, _) = PartyMatcher.match(parties: parties, profile: profile) else {
            doc.userPartyName = nil
            doc.identityDecision = .undetermined
            return
        }
        doc.userPartyName = parties[index]
        doc.userIsNeither = false
        doc.identityDecision = .automatic
    }

    /// "ABC Technologies — Freelance Agreement" once the counterparty is known.
    func updateTitle(_ doc: DocumentRecord) {
        let base = (doc.originalFilename as NSString).deletingPathExtension
        let isDefault = doc.title == base || doc.title.hasPrefix("Scan ")
        guard isDefault else { return }
        let typeName = doc.documentType?.displayName
        let other = doc.partyNames.first { name in doc.userPartyName.map { PartyMatcher.similarity(name, $0) < PartyMatcher.matchThreshold } ?? true }
        switch (other, typeName) {
        case let (party?, type?): doc.title = "\(party) — \(type)"
        case let (nil, type?): doc.title = type
        default: break
        }
    }
}

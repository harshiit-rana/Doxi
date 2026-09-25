import DoxiCore
import Foundation
import SwiftData

enum ProcessingStatus: String, Codable {
    case queued, readingText, extracting, needsReview, confirmed, failed

    var displayName: String {
        switch self {
        case .queued: return "Waiting"
        case .readingText: return "Reading text"
        case .extracting: return "Finding details"
        case .needsReview: return "Needs review"
        case .confirmed: return "Confirmed"
        case .failed: return "Could not process"
        }
    }

    var isWorking: Bool { self == .queued || self == .readingText || self == .extracting }
}

enum DocumentOrigin: String, Codable {
    case scan, importFile, share
}

enum IdentityDecision: String, Codable {
    /// Not decided; the app must ask.
    case undetermined
    /// Matched the profile unambiguously (shown to the user, who can change it).
    case automatic
    /// Chosen by the user.
    case userChosen
}

@Model
final class DocumentRecord {
    @Attribute(.unique) var id: UUID
    var title: String
    var originalFilename: String
    /// File name inside `FileStore.documentsDirectory`.
    var storedFilename: String
    var documentTypeRaw: String?
    var originRaw: String
    var createdAt: Date
    var modifiedAt: Date
    var processingStatusRaw: String
    var processingMessage: String?
    var warnings: [String]
    var pageCount: Int
    /// Full text used for search (all pages).
    var fullText: String
    var textSourceSummary: String
    /// Name of the AI provider whose output was used, if any.
    var extractionProviderName: String?
    /// True once document text has been sent to a cloud service.
    var sentToCloud: Bool
    var userPartyName: String?
    var userIsNeither: Bool
    var identityDecisionRaw: String
    var confirmedAt: Date?
    /// Amounts written in the text (minor units) for search.
    var textAmounts: [Int]
    /// Precomputed search normalisation of `fullText` (see `TextNormalizer.searchKey`).
    var searchKey: String = ""

    @Relationship(deleteRule: .cascade, inverse: \DocumentPageRecord.document) var pages: [DocumentPageRecord] = []
    @Relationship(deleteRule: .cascade, inverse: \ExtractedFieldRecord.document) var fields: [ExtractedFieldRecord] = []
    @Relationship(deleteRule: .cascade, inverse: \ObligationRecord.document) var obligations: [ObligationRecord] = []

    init(title: String, originalFilename: String, storedFilename: String, origin: DocumentOrigin) {
        self.id = UUID()
        self.title = title
        self.originalFilename = originalFilename
        self.storedFilename = storedFilename
        self.documentTypeRaw = nil
        self.originRaw = origin.rawValue
        self.createdAt = .now
        self.modifiedAt = .now
        self.processingStatusRaw = ProcessingStatus.queued.rawValue
        self.processingMessage = nil
        self.warnings = []
        self.pageCount = 0
        self.fullText = ""
        self.textSourceSummary = ""
        self.extractionProviderName = nil
        self.sentToCloud = false
        self.userPartyName = nil
        self.userIsNeither = false
        self.identityDecisionRaw = IdentityDecision.undetermined.rawValue
        self.confirmedAt = nil
        self.textAmounts = []
    }

    var status: ProcessingStatus {
        get { ProcessingStatus(rawValue: processingStatusRaw) ?? .failed }
        set { processingStatusRaw = newValue.rawValue; modifiedAt = .now }
    }

    var documentType: DocumentType? {
        get { documentTypeRaw.flatMap(DocumentType.init(rawValue:)) }
        set { documentTypeRaw = newValue?.rawValue }
    }

    var identityDecision: IdentityDecision {
        get { IdentityDecision(rawValue: identityDecisionRaw) ?? .undetermined }
        set { identityDecisionRaw = newValue.rawValue }
    }

    var origin: DocumentOrigin { DocumentOrigin(rawValue: originRaw) ?? .importFile }

    var sortedPages: [DocumentPageRecord] { pages.sorted { $0.index < $1.index } }

    var sortedFields: [ExtractedFieldRecord] {
        fields.sorted { ($0.kind.sortRank, $0.sortIndex) < ($1.kind.sortRank, $1.sortIndex) }
    }

    /// The document text with source locations, rebuilt from stored pages.
    var documentText: DocumentText { DocumentText(pages: sortedPages.map(\.pageText)) }

    var partyNames: [String] {
        fields.filter { $0.kind == .party && $0.verification != .rejected }.compactMap { f in
            if case .party(let p) = f.value { return p.name }
            return nil
        }
    }

    var pendingFieldCount: Int { fields.filter { $0.verification == .pending }.count }

    /// Needs the user's attention before it is fully tracked.
    var needsReview: Bool { status == .needsReview || (status == .confirmed && pendingFieldCount > 0) }
}

@Model
final class DocumentPageRecord {
    var index: Int
    var textSourceRaw: String
    @Attribute(.externalStorage) var linesData: Data
    var appliedRotation: Int
    var averageConfidence: Double
    var document: DocumentRecord?

    init(page: PageText) {
        self.index = page.index
        self.textSourceRaw = page.source.rawValue
        self.linesData = (try? JSONEncoder().encode(page.lines)) ?? Data()
        self.appliedRotation = page.appliedRotation
        self.averageConfidence = page.averageConfidence
    }

    var pageText: PageText {
        let lines = (try? JSONDecoder().decode([TextLine].self, from: linesData)) ?? []
        return PageText(index: index, source: TextSource(rawValue: textSourceRaw) ?? .none, lines: lines, appliedRotation: appliedRotation)
    }
}

@Model
final class ExtractedFieldRecord {
    @Attribute(.unique) var id: UUID
    var kindRaw: String
    var valueData: Data
    /// Cached display value (list rendering and search).
    var displayValue: String
    var originRaw: String
    var confidenceRaw: String
    var verificationRaw: String
    var sourceData: Data?
    /// Further supporting spans (JSON [SourceSpan]), e.g. an invoice's due-date line.
    var additionalSourcesData: Data?
    var notes: [String]
    var conflictGroup: String?
    var ruleStrengthRaw: String?
    var valueVerifiedInSource: Bool?
    var sortIndex: Int
    /// For payments: the user's choice of direction, overriding the inferred one.
    var directionOverrideRaw: String?
    var document: DocumentRecord?

    init(draft: ExtractedFieldDraft, sortIndex: Int) {
        self.id = draft.id
        self.kindRaw = draft.kind.rawValue
        self.valueData = Data()
        self.displayValue = ""
        self.originRaw = draft.origin.rawValue
        self.confidenceRaw = draft.confidence.rawValue
        self.verificationRaw = draft.verification.rawValue
        self.sourceData = nil
        self.additionalSourcesData = draft.additionalSources.flatMap { try? JSONEncoder().encode($0) }
        self.notes = draft.notes
        self.conflictGroup = draft.conflictGroup
        self.ruleStrengthRaw = draft.ruleStrength?.rawValue
        self.valueVerifiedInSource = draft.valueVerifiedInSource
        self.sortIndex = sortIndex
        self.directionOverrideRaw = nil
        self.value = draft.value
        self.source = draft.source
    }

    var kind: FieldKind { FieldKind(rawValue: kindRaw) ?? .clause }

    var value: FieldValue {
        get { (try? JSONDecoder().decode(FieldValue.self, from: valueData)) ?? .text(displayValue) }
        set {
            valueData = (try? JSONEncoder().encode(newValue)) ?? Data()
            displayValue = newValue.displayString
        }
    }

    var source: SourceSpan? {
        get { sourceData.flatMap { try? JSONDecoder().decode(SourceSpan.self, from: $0) } }
        set { sourceData = newValue.flatMap { try? JSONEncoder().encode($0) } }
    }

    var additionalSources: [SourceSpan] {
        additionalSourcesData.flatMap { try? JSONDecoder().decode([SourceSpan].self, from: $0) } ?? []
    }

    var origin: FieldOrigin {
        get { FieldOrigin(rawValue: originRaw) ?? .deterministic }
        set { originRaw = newValue.rawValue }
    }

    var confidence: Confidence {
        get { Confidence(rawValue: confidenceRaw) ?? .unverified }
        set { confidenceRaw = newValue.rawValue }
    }

    var verification: VerificationStatus {
        get { VerificationStatus(rawValue: verificationRaw) ?? .pending }
        set { verificationRaw = newValue.rawValue }
    }

    var directionOverride: FinancialDirection? {
        get { directionOverrideRaw.flatMap(FinancialDirection.init(rawValue:)) }
        set { directionOverrideRaw = newValue?.rawValue }
    }

    var draft: ExtractedFieldDraft {
        ExtractedFieldDraft(id: id, kind: kind, value: value, origin: origin, source: source, confidence: confidence,
                            verification: verification, notes: notes, conflictGroup: conflictGroup,
                            ruleStrength: ruleStrengthRaw.flatMap(RuleStrength.init(rawValue:)), valueVerifiedInSource: valueVerifiedInSource,
                            additionalSources: additionalSources.isEmpty ? nil : additionalSources)
    }
}

@Model
final class ObligationRecord {
    @Attribute(.unique) var id: UUID
    var categoryRaw: String
    var title: String
    var detail: String
    var amountMinor: Int?
    var currency: String?
    /// ISO yyyy-MM-dd; string form sorts correctly and avoids timezone shifts.
    var dueDateISO: String?
    var dueDateExplanation: String?
    /// First occurrence for recurring obligations.
    var anchorDateISO: String?
    var recurrenceData: Data?
    var responsibleParty: String?
    var counterparty: String?
    var directionRaw: String
    var directionReason: String?
    var statusRaw: String
    var sourceFieldID: UUID?
    var sourceData: Data?
    var remindersEnabled: Bool
    var reminderOffsets: [Int]
    var completedAt: Date?
    var createdAt: Date
    var history: [String]
    var document: DocumentRecord?

    init(draft: ObligationDraft, reminderOffsets: [Int]) {
        self.id = UUID()
        self.categoryRaw = draft.category.rawValue
        self.title = draft.title
        self.detail = draft.detail
        self.amountMinor = draft.amount.map { Int($0.minorUnits) }
        self.currency = draft.amount?.currency
        self.dueDateISO = draft.dueDate?.isoString
        self.dueDateExplanation = draft.dueDateExplanation
        self.anchorDateISO = draft.dueDate?.isoString
        self.recurrenceData = draft.recurrence.flatMap { try? JSONEncoder().encode($0) }
        self.responsibleParty = draft.responsibleParty
        self.counterparty = draft.counterparty
        self.directionRaw = draft.direction.rawValue
        self.directionReason = draft.directionReason
        self.statusRaw = draft.status.rawValue
        self.sourceFieldID = draft.sourceFieldID
        self.sourceData = draft.source.flatMap { try? JSONEncoder().encode($0) }
        self.remindersEnabled = draft.dueDate != nil
        self.reminderOffsets = reminderOffsets
        self.completedAt = nil
        self.createdAt = .now
        self.history = []
    }

    var category: ObligationCategory { ObligationCategory(rawValue: categoryRaw) ?? .other }

    var amount: Money? {
        guard let amountMinor else { return nil }
        return Money(minorUnits: Int64(amountMinor), currency: currency ?? "INR")
    }

    var dueDate: CalendarDate? {
        get { dueDateISO.flatMap(CalendarDate.init(iso:)) }
        set { dueDateISO = newValue?.isoString }
    }

    var anchorDate: CalendarDate? { anchorDateISO.flatMap(CalendarDate.init(iso:)) ?? dueDate }

    var recurrence: Recurrence? {
        get { recurrenceData.flatMap { try? JSONDecoder().decode(Recurrence.self, from: $0) } }
        set { recurrenceData = newValue.flatMap { try? JSONEncoder().encode($0) } }
    }

    var direction: FinancialDirection {
        get { FinancialDirection(rawValue: directionRaw) ?? .unknown }
        set { directionRaw = newValue.rawValue }
    }

    var storedStatus: ObligationStatus {
        get { ObligationStatus(rawValue: statusRaw) ?? .pending }
        set { statusRaw = newValue.rawValue }
    }

    func status(today: CalendarDate = .today()) -> ObligationStatus {
        ObligationStatus.effective(stored: storedStatus, due: dueDate, today: today)
    }

    var source: SourceSpan? { sourceData.flatMap { try? JSONDecoder().decode(SourceSpan.self, from: $0) } }

    var isPayment: Bool { category == .payment }
}

@Model
final class UserProfileRecord {
    var name: String
    var businessName: String
    var aliases: [String]
    var gstin: String?
    var updatedAt: Date

    init(name: String = "", businessName: String = "", aliases: [String] = [], gstin: String? = nil) {
        self.name = name
        self.businessName = businessName
        self.aliases = aliases
        self.gstin = gstin
        self.updatedAt = .now
    }

    var identity: IdentityProfile {
        IdentityProfile(name: name, businessName: businessName, aliases: aliases, gstin: gstin)
    }
}

enum DoxiSchema {
    static let models: [any PersistentModel.Type] = [
        DocumentRecord.self, DocumentPageRecord.self, ExtractedFieldRecord.self, ObligationRecord.self, UserProfileRecord.self,
    ]
}

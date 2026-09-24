import DoxiCore
import SwiftData
import SwiftUI

/// The structured view of one document: status, parties, dates, money,
/// payments, renewal, notice, obligations — each value linked to its source.
struct DocumentDetailView: View {
    @Bindable var document: DocumentRecord
    @Environment(AppServices.self) private var services
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    @State private var sourceItem: SourceItem?
    @State private var renaming = false
    @State private var newTitle = ""
    @State private var confirmDelete = false

    var body: some View {
        List {
            headerSection
            if document.status == .needsReview || document.status == .failed || document.pendingFieldCount > 0 {
                Section {
                    NavigationLink {
                        ReviewView(document: document)
                    } label: {
                        Label(reviewLabel, systemImage: "checklist")
                            .foregroundStyle(.tint)
                    }
                }
            }
            if !document.status.isWorking {
                fieldSections
                obligationsSection
            }
            Section {
                NavigationLink {
                    OriginalDocumentView(document: document)
                } label: {
                    Label("View original document", systemImage: "doc.richtext")
                }
                LabeledContent("Pages", value: "\(document.pageCount)")
                LabeledContent("Text", value: document.textSourceSummary.isEmpty ? "—" : document.textSourceSummary)
                LabeledContent("Extraction", value: extractionDescription)
                LabeledContent("Added", value: document.createdAt.formatted(date: .abbreviated, time: .shortened))
            } header: {
                Text("Document")
            } footer: {
                Text(document.sentToCloud
                     ? "This document's text was sent to \(document.extractionProviderName ?? "a cloud AI service") for extraction. The file itself stays on this device."
                     : "This document was processed on this device.")
            }
            Section {
                Button("Rename") { newTitle = document.title; renaming = true }
                Button("Run extraction again") { services.process(document, context: context) }
                    .disabled(services.processor.inFlight.contains(document.id))
                Button("Delete document", role: .destructive) { confirmDelete = true }
            }
        }
        .navigationTitle(document.title)
        .navigationBarTitleDisplayMode(.inline)
        .sheet(item: $sourceItem) { item in
            SourceSheet(document: document, source: item.source, fieldLabel: item.label)
        }
        .alert("Rename document", isPresented: $renaming) {
            TextField("Title", text: $newTitle)
            Button("Save") {
                let t = newTitle.trimmingCharacters(in: .whitespaces)
                if !t.isEmpty { document.title = t; try? context.save() }
            }
            Button("Cancel", role: .cancel) {}
        }
        .confirmationDialog("Delete this document?", isPresented: $confirmDelete, titleVisibility: .visible) {
            Button("Delete", role: .destructive) {
                services.delete(document, context: context)
                dismiss()
            }
        } message: {
            Text("The file, extracted details, obligations and reminders will be removed from this device.")
        }
    }

    var reviewLabel: String {
        let n = document.pendingFieldCount
        return n == 0 ? "Review extracted details" : "Review \(n) extracted detail\(n == 1 ? "" : "s")"
    }

    var extractionDescription: String {
        if let name = document.extractionProviderName { return "On-device rules + \(name)" }
        return "On-device rules"
    }

    // MARK: Header

    @ViewBuilder var headerSection: some View {
        Section {
            VStack(alignment: .leading, spacing: 6) {
                Text(document.title).font(.title3.weight(.semibold))
                HStack {
                    if let type = document.documentType { Text(type.displayName).foregroundStyle(.secondary) }
                    Spacer()
                    statusLabel
                }
                .font(.subheadline)
            }
            if services.processor.cloudInFlight.contains(document.id) {
                Label("Sending document text to Anthropic for extraction…", systemImage: "icloud.and.arrow.up")
                    .font(.footnote).foregroundStyle(.secondary)
            } else if document.status.isWorking {
                HStack { ProgressView(); Text(document.status.displayName + "…").foregroundStyle(.secondary) }
            }
            if document.status == .failed {
                VStack(alignment: .leading, spacing: 8) {
                    Label(document.processingMessage ?? "This document could not be processed.", systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.red)
                    Text("You can still view the original and add details manually in Review.").font(.footnote).foregroundStyle(.secondary)
                    Button("Try again") { services.process(document, context: context) }
                }
            } else if let message = document.processingMessage {
                Label(message, systemImage: "info.circle").font(.footnote).foregroundStyle(.secondary)
            }
            ForEach(document.warnings, id: \.self) { w in
                Label(w, systemImage: "exclamationmark.triangle").font(.footnote).foregroundStyle(.orange)
            }
        }
    }

    @ViewBuilder var statusLabel: some View {
        switch document.status {
        case .confirmed where document.pendingFieldCount == 0:
            Label("Confirmed", systemImage: "checkmark.seal.fill").foregroundStyle(.green)
        default:
            ProcessingBadge(status: document.status)
        }
    }

    // MARK: Fields

    func visible(_ kinds: FieldKind...) -> [ExtractedFieldRecord] {
        document.sortedFields.filter { kinds.contains($0.kind) && $0.verification != .rejected }
    }

    @ViewBuilder var fieldSections: some View {
        let parties = visible(.party)
        if !parties.isEmpty {
            Section("Parties") {
                ForEach(parties) { f in
                    DetailFieldRow(field: f, isUser: isUser(f), onSource: open)
                }
                if document.identityDecision == .undetermined && !document.userIsNeither {
                    Label("Choose which party is you in Review.", systemImage: "person.crop.circle.badge.questionmark")
                        .font(.footnote).foregroundStyle(.orange)
                }
            }
        }
        let dates = visible(.effectiveDate, .endDate)
        if !dates.isEmpty {
            Section("Dates") { ForEach(dates) { DetailFieldRow(field: $0, onSource: open) } }
        }
        let money = visible(.totalAmount, .paymentFrequency)
        let payments = visible(.payment)
        if !money.isEmpty || !payments.isEmpty {
            Section("Money") {
                ForEach(money) { DetailFieldRow(field: $0, onSource: open) }
                ForEach(payments) { DetailFieldRow(field: $0, onSource: open) }
            }
        }
        Section("Renewal & notice") {
            let terms = visible(.renewal, .noticePeriod)
            if terms.isEmpty {
                Text("No renewal or notice terms detected").foregroundStyle(.secondary)
            }
            ForEach(terms) { DetailFieldRow(field: $0, onSource: open) }
        }
        let duties = visible(.obligation)
        if !duties.isEmpty {
            Section("Deadlines & deliverables") { ForEach(duties) { DetailFieldRow(field: $0, onSource: open) } }
        }
        let clauses = visible(.clause)
        if !clauses.isEmpty {
            Section {
                ForEach(clauses) { DetailFieldRow(field: $0, onSource: open) }
            } header: {
                Text("Important clauses")
            } footer: {
                Text("Clauses are identified to help you find them. This is not legal advice.")
            }
        }
        let ids = visible(.identifier)
        if !ids.isEmpty {
            Section("Identifiers") { ForEach(ids) { DetailFieldRow(field: $0, onSource: open) } }
        }
    }

    func isUser(_ f: ExtractedFieldRecord) -> Bool {
        guard let user = document.userPartyName, case .party(let p) = f.value else { return false }
        return PartyMatcher.similarity(p.name, user) >= PartyMatcher.matchThreshold
    }

    func open(_ f: ExtractedFieldRecord) {
        if let s = f.source { sourceItem = SourceItem(source: s, label: f.kind.displayName) }
    }

    // MARK: Obligations

    @ViewBuilder var obligationsSection: some View {
        let obligations = document.obligations.sorted { ($0.dueDateISO ?? "9999") < ($1.dueDateISO ?? "9999") }
        if !obligations.isEmpty {
            Section("Obligations") {
                ForEach(obligations) { ob in
                    NavigationLink { ObligationDetailView(obligation: ob) } label: { ObligationRow(obligation: ob, showDocument: false) }
                }
            }
        } else if document.status == .confirmed {
            Section("Obligations") {
                Text("No dated obligations were created from the confirmed details.").foregroundStyle(.secondary)
            }
        }
    }
}

struct SourceItem: Identifiable {
    let id = UUID()
    let source: SourceSpan
    let label: String
}

/// A read-only field row in the document detail screen.
struct DetailFieldRow: View {
    let field: ExtractedFieldRecord
    var isUser = false
    var onSource: (ExtractedFieldRecord) -> Void

    var body: some View {
        Button {
            onSource(field)
        } label: {
            VStack(alignment: .leading, spacing: 4) {
                HStack(alignment: .firstTextBaseline) {
                    Text(label).font(.subheadline).foregroundStyle(.secondary)
                    Spacer()
                    if field.verification.isAccepted {
                        VerificationBadge(status: field.verification)
                    } else {
                        ConfidenceBadge(confidence: field.confidence)
                    }
                }
                HStack {
                    Text(value).foregroundStyle(.primary)
                    if isUser { Text("You").font(.caption.weight(.semibold)).foregroundStyle(.tint) }
                }
                if let source = field.source {
                    SourceQuoteView(source: source)
                } else {
                    Text(field.origin == .user ? "Added by you" : "No source found in the document")
                        .font(.caption).foregroundStyle(field.origin == .user ? Color.secondary : Color.red)
                }
            }
        }
        .buttonStyle(.plain)
        .disabled(field.source == nil)
        .accessibilityHint(field.source == nil ? "" : "Shows the source in the document")
    }

    var label: String {
        switch field.value {
        case .payment(let p): return p.label
        case .clause(let c): return c.category.displayName
        case .party(let p): return p.role ?? "Party"
        default: return field.kind.displayName
        }
    }

    var value: String {
        switch field.value {
        case .clause(let c): return c.summary
        case .party(let p): return p.name
        default: return field.displayValue
        }
    }
}

import DoxiCore
import SwiftData
import SwiftUI

/// Verify → confirm. The user checks every extracted detail against its source,
/// edits or rejects it, says which party they are, and then confirms. Only
/// accepted details become obligations.
struct ReviewView: View {
    @Bindable var document: DocumentRecord
    @Environment(AppServices.self) private var services
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    @State private var sourceItem: SourceItem?
    @State private var editing: EditTarget?
    @State private var confirmCloud = false
    @State private var finishPrompt = false
    @State private var showRejected = false

    struct EditTarget: Identifiable {
        let id = UUID()
        let kind: FieldKind
        let field: ExtractedFieldRecord?
    }

    static let groups: [(String, [FieldKind])] = [
        ("Document", [.documentType, .title]),
        ("Parties", [.party]),
        ("Dates", [.effectiveDate, .endDate]),
        ("Money", [.totalAmount, .payment, .paymentFrequency]),
        ("Renewal & notice", [.renewal, .noticePeriod]),
        ("Deadlines & deliverables", [.obligation]),
        ("Important clauses", [.clause]),
        ("Identifiers", [.identifier]),
    ]

    var body: some View {
        List {
            introSection
            identitySection
            ForEach(Self.groups, id: \.0) { group in
                let title = group.0
                let kinds = group.1
                let fields = document.sortedFields.filter { kinds.contains($0.kind) && $0.verification != .rejected }
                if !fields.isEmpty {
                    Section {
                        ForEach(fields) { field in
                            FieldReviewRow(field: field, document: document,
                                           onSource: { f in if let s = f.source { sourceItem = SourceItem(source: s, label: f.kind.displayName) } },
                                           onEdit: { f in editing = EditTarget(kind: f.kind, field: f) })
                        }
                    } header: {
                        Text(title)
                    } footer: {
                        if kinds.contains(.clause) { Text("Doxi points out clauses; it does not interpret them or give legal advice.") }
                    }
                }
            }
            addSection
            rejectedSection
        }
        .navigationTitle("Review")
        .navigationBarTitleDisplayMode(.inline)
        .safeAreaInset(edge: .bottom) { confirmBar }
        .sheet(item: $sourceItem) { item in SourceSheet(document: document, source: item.source, fieldLabel: item.label) }
        .sheet(item: $editing) { target in
            FieldEditorView(kind: target.kind, initial: target.field?.value, parties: document.partyNames) { value in
                if let field = target.field {
                    services.obligations.edit(field, value: value, in: document)
                } else {
                    services.obligations.addManualField(kind: target.kind, value: value, to: document, context: context)
                    if target.kind == .party { services.processor.matchIdentity(document, profile: services.profile(in: context)) }
                }
                try? context.save()
            }
        }
        .confirmationDialog("Send this document's text to Anthropic?", isPresented: $confirmCloud, titleVisibility: .visible) {
            Button("Send text for AI extraction") { services.runCloudExtraction(document, context: context) }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("The recognised text (not the file) is sent to Anthropic's Claude API to find parties, payments and obligations. Every result is checked against the document before you see it. Details you already confirmed are kept.")
        }
        .alert("Finish review?", isPresented: $finishPrompt) {
            Button("Confirm and track") { finish() }
            Button("Keep reviewing", role: .cancel) {}
        } message: {
            Text(finishMessage)
        }
    }

    // MARK: Sections

    @ViewBuilder var introSection: some View {
        Section {
            VStack(alignment: .leading, spacing: 6) {
                Text("Check each detail against the document. Tap a quote to see it highlighted in the original.")
                    .font(.subheadline)
                Text(document.sentToCloud
                     ? "Extracted with on-device rules and \(document.extractionProviderName ?? "cloud AI"). Document text was sent to the cloud service."
                     : "Extracted on this device\(document.extractionProviderName.map { " (rules + \($0))" } ?? " with rules").")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            if services.processor.cloudInFlight.contains(document.id) {
                HStack { ProgressView(); Text("Anthropic is processing the document text…").font(.footnote) }
            } else if services.processor.inFlight.contains(document.id) {
                HStack { ProgressView(); Text("Processing…").font(.footnote) }
            } else if services.settings.cloudExtractionEnabled && !document.sentToCloud && !document.fullText.isEmpty {
                Button {
                    confirmCloud = true
                } label: {
                    Label("Improve with Claude (cloud)", systemImage: "sparkles")
                }
            }
            if let message = document.processingMessage {
                Label(message, systemImage: "info.circle").font(.footnote).foregroundStyle(.orange)
            }
            if document.fullText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !document.status.isWorking {
                Label("No text could be read from this document. Add the details you need below.", systemImage: "text.badge.xmark")
                    .font(.footnote).foregroundStyle(.orange)
            }
        }
    }

    @ViewBuilder var identitySection: some View {
        let parties = document.partyNames
        if !parties.isEmpty {
            Section {
                Picker("You are", selection: Binding<String>(
                    get: { document.userIsNeither ? "__neither__" : (document.userPartyName ?? "") },
                    set: { value in
                        services.obligations.setIdentity(document, partyName: value == "__neither__" ? nil : value)
                        try? context.save()
                    })) {
                    if document.userPartyName == nil && !document.userIsNeither { Text("Choose…").tag("") }
                    ForEach(parties, id: \.self) { Text($0).tag($0) }
                    Text("Neither / Other").tag("__neither__")
                }
            } header: {
                Text("Who are you in this document?")
            } footer: {
                switch document.identityDecision {
                case .automatic: Text("Matched to your profile. Change it if this is wrong.")
                case .userChosen: Text("Used to decide which payments are owed to you and which you owe.")
                case .undetermined: Text("Doxi couldn't tell which party is you, so it won't guess. Choose one to see what is owed to you and what you owe.")
                }
            }
        }
    }

    @ViewBuilder var addSection: some View {
        Section {
            Menu {
                ForEach([FieldKind.party, .effectiveDate, .endDate, .totalAmount, .payment, .noticePeriod, .renewal, .obligation, .documentType], id: \.self) { kind in
                    Button(kind.displayName) { editing = EditTarget(kind: kind, field: nil) }
                }
            } label: {
                Label("Add a missing detail", systemImage: "plus.circle")
            }
        }
    }

    @ViewBuilder var rejectedSection: some View {
        let rejected = document.sortedFields.filter { $0.verification == .rejected }
        if !rejected.isEmpty {
            Section {
                DisclosureGroup("Rejected (\(rejected.count))", isExpanded: $showRejected) {
                    ForEach(rejected) { f in
                        HStack {
                            VStack(alignment: .leading) {
                                Text(f.kind.displayName).font(.caption).foregroundStyle(.secondary)
                                Text(f.displayValue).strikethrough().foregroundStyle(.secondary)
                            }
                            Spacer()
                            Button("Restore") { f.verification = .pending; try? context.save() }.buttonStyle(.borderless)
                        }
                    }
                }
            }
        }
    }

    // MARK: Confirm

    var pending: [ExtractedFieldRecord] { document.fields.filter { $0.verification == .pending } }
    var pendingHigh: [ExtractedFieldRecord] { pending.filter { $0.confidence == .high && $0.conflictGroup == nil } }

    var confirmBar: some View {
        VStack(spacing: 8) {
            if !pendingHigh.isEmpty {
                Button {
                    for f in pendingHigh { services.obligations.confirm(f, in: document) }
                    try? context.save()
                } label: {
                    Text("Accept \(pendingHigh.count) high-confidence detail\(pendingHigh.count == 1 ? "" : "s")").frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
            }
            Button {
                if pending.isEmpty && !needsIdentity { finish() } else { finishPrompt = true }
            } label: {
                Text(document.status == .confirmed ? "Update obligations" : "Confirm and track").bold().frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .disabled(services.processor.inFlight.contains(document.id))
        }
        .padding()
        .background(.bar)
    }

    var needsIdentity: Bool {
        let hasPayments = document.fields.contains { $0.kind == .payment && $0.verification.isAccepted }
        return hasPayments && document.userPartyName == nil && !document.userIsNeither
    }

    var finishMessage: String {
        var parts: [String] = []
        if !pending.isEmpty {
            parts.append("\(pending.count) detail\(pending.count == 1 ? " is" : "s are") still unchecked and won't be used for obligations or reminders.")
        }
        if needsIdentity {
            parts.append("You haven't said which party you are, so payment directions (owed to me / I owe) will be left unset.")
        }
        return parts.joined(separator: " ")
    }

    func finish() {
        services.finalize(document, context: context)
        dismiss()
    }
}

/// One extracted detail with its confidence, source and review actions.
struct FieldReviewRow: View {
    let field: ExtractedFieldRecord
    let document: DocumentRecord
    var onSource: (ExtractedFieldRecord) -> Void
    var onEdit: (ExtractedFieldRecord) -> Void
    @Environment(AppServices.self) private var services
    @Environment(\.modelContext) private var context

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Text(title).font(.subheadline).foregroundStyle(.secondary)
                Spacer()
                if field.verification.isAccepted {
                    VerificationBadge(status: field.verification)
                } else {
                    ConfidenceBadge(confidence: field.confidence)
                }
            }
            Text(valueText).font(.body.weight(.medium))
            if field.conflictGroup != nil && field.verification == .pending {
                Label("Different values were found. Confirm the correct one.", systemImage: "arrow.left.arrow.right")
                    .font(.caption).foregroundStyle(.orange)
            }
            if case .payment(let p) = field.value { directionPicker(p) }
            if let source = field.source {
                Button { onSource(field) } label: { SourceQuoteView(source: source) }
                    .buttonStyle(.plain)
            } else if field.origin != .user {
                Label("Not found in the document text", systemImage: "questionmark.diamond").font(.caption).foregroundStyle(.red)
            }
            ForEach(field.notes.filter { $0 != "Edited by you." && $0 != "Added by you." }, id: \.self) { note in
                Text(note).font(.caption).foregroundStyle(.secondary)
            }
            HStack(spacing: 12) {
                if field.verification == .pending {
                    Button { services.obligations.confirm(field, in: document); try? context.save() } label: {
                        Label("Confirm", systemImage: "checkmark")
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.green)
                } else {
                    Button { field.verification = .pending; try? context.save() } label: { Label("Undo", systemImage: "arrow.uturn.backward") }
                        .buttonStyle(.bordered)
                }
                Button { onEdit(field) } label: { Label("Edit", systemImage: "pencil") }
                    .buttonStyle(.bordered)
                Button(role: .destructive) { services.obligations.reject(field, in: document); try? context.save() } label: {
                    Label("Reject", systemImage: "xmark")
                }
                .buttonStyle(.bordered)
            }
            .controlSize(.small)
            .labelStyle(.titleAndIcon)
        }
        .padding(.vertical, 4)
    }

    var title: String {
        switch field.value {
        case .payment(let p): return p.label
        case .clause(let c): return c.category.displayName
        case .party(let p): return p.role.map { "Party · \($0)" } ?? "Party"
        default: return field.kind.displayName
        }
    }

    var valueText: String {
        switch field.value {
        case .clause(let c): return c.summary
        case .party(let p): return p.name
        default: return field.displayValue
        }
    }

    @ViewBuilder func directionPicker(_ p: PaymentValue) -> some View {
        let inferred = DirectionResolver.resolve(payer: p.payer, payee: p.payee, userParty: document.userPartyName,
                                                 userIsNeither: document.userIsNeither,
                                                 parties: document.fields.filter { $0.kind == .party && $0.verification != .rejected }.compactMap { f in
                                                     if case .party(let party) = f.value { return DirectionResolver.Party(name: party.name, role: party.role) }
                                                     return nil
                                                 })
        let current = field.directionOverride ?? inferred.direction
        VStack(alignment: .leading, spacing: 2) {
            Menu {
                ForEach([FinancialDirection.owedToMe, .iOwe, .notMine], id: \.self) { d in
                    Button { field.directionOverride = d; try? context.save() } label: { Label(d.displayName, systemImage: d.symbol) }
                }
                if field.directionOverride != nil {
                    Button("Use inferred direction") { field.directionOverride = nil; try? context.save() }
                }
            } label: {
                Label(current.displayName, systemImage: current.symbol).font(.subheadline)
            }
            Text(field.directionOverride != nil ? "Set by you." : inferred.reason).font(.caption2).foregroundStyle(.secondary)
        }
    }
}

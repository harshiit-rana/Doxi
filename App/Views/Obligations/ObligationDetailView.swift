import DoxiCore
import SwiftData
import SwiftUI

struct ObligationDetailView: View {
    @Bindable var obligation: ObligationRecord
    @Environment(AppServices.self) private var services
    @Environment(\.modelContext) private var context
    @State private var sourceItem: SourceItem?

    var body: some View {
        let status = obligation.status()
        List {
            Section {
                VStack(alignment: .leading, spacing: 8) {
                    Label(obligation.category.displayName, systemImage: obligation.category.symbol)
                        .font(.subheadline).foregroundStyle(.secondary)
                    Text(obligation.title).font(.title3.weight(.semibold))
                    ObligationStatusBadge(status: status)
                }
                if let amount = obligation.amount { LabeledContent("Amount", value: amount.formatted) }
                if let due = obligation.dueDate {
                    LabeledContent("Due", value: due.longString)
                    if let explanation = obligation.dueDateExplanation {
                        Text("Derived: \(explanation)").font(.footnote).foregroundStyle(.secondary)
                    }
                } else {
                    LabeledContent("Due", value: "No date")
                }
                if let rec = obligation.recurrence {
                    LabeledContent("Repeats", value: rec.displayName)
                    if let end = rec.endDate { LabeledContent("Until", value: end.longString) }
                }
                if let who = obligation.counterparty { LabeledContent("With", value: who) }
                if let responsible = obligation.responsibleParty { LabeledContent("Responsible", value: responsible) }
            }

            if obligation.isPayment {
                Section {
                    Picker("Direction", selection: Binding(get: { obligation.direction }, set: { obligation.direction = $0; obligation.directionReason = "Set by you."; save() })) {
                        ForEach(FinancialDirection.allCases, id: \.self) { Text($0.displayName).tag($0) }
                    }
                } footer: {
                    Text(obligation.directionReason ?? "")
                }
            }

            Section {
                if status.isOpen {
                    Button {
                        services.obligations.markDone(obligation)
                        save()
                    } label: {
                        Label(doneLabel, systemImage: "checkmark.circle")
                    }
                    Menu {
                        Button("Cancelled") { services.obligations.setStatus(obligation, .cancelled); save() }
                        Button("Dismiss (not relevant)") { services.obligations.setStatus(obligation, .dismissed); save() }
                    } label: {
                        Label("Mark as…", systemImage: "ellipsis.circle")
                    }
                } else {
                    Button { services.obligations.reopen(obligation); save() } label: {
                        Label("Reopen", systemImage: "arrow.uturn.backward.circle")
                    }
                }
            } footer: {
                if obligation.isPayment && status == .overdue {
                    Text("Doxi never marks payments as received on its own. Mark it when the money arrives.")
                }
            }

            Section("Reminders") {
                Toggle("Remind me", isOn: Binding(get: { obligation.remindersEnabled }, set: { obligation.remindersEnabled = $0; save() }))
                    .disabled(obligation.dueDate == nil)
                if obligation.remindersEnabled {
                    ForEach(AppSettings.availableOffsets, id: \.self) { days in
                        Toggle(AppSettings.offsetLabel(days), isOn: Binding(
                            get: { obligation.reminderOffsets.contains(days) },
                            set: { on in
                                if on { obligation.reminderOffsets.append(days) } else { obligation.reminderOffsets.removeAll { $0 == days } }
                                save()
                            }))
                    }
                }
                if services.notifications.isDenied {
                    Label("Notifications are turned off for Doxi, so reminders can't alert you.", systemImage: "bell.slash")
                        .font(.footnote).foregroundStyle(.orange)
                    Button("Open Settings") {
                        if let url = URL(string: UIApplication.openNotificationSettingsURLString) { UIApplication.shared.open(url) }
                    }
                }
            }

            if let source = obligation.source, let doc = obligation.document {
                Section("Source") {
                    Button { sourceItem = SourceItem(source: source, label: obligation.title) } label: { SourceQuoteView(source: source) }
                        .buttonStyle(.plain)
                    NavigationLink("Open \(doc.title)") { DocumentDetailView(document: doc) }
                }
            }

            if !obligation.history.isEmpty {
                Section("History") {
                    ForEach(obligation.history.reversed(), id: \.self) { Text($0).font(.footnote) }
                }
            }
        }
        .navigationTitle(obligation.category.displayName)
        .navigationBarTitleDisplayMode(.inline)
        .navigationDestination(item: $sourceItem) { item in
            if let doc = obligation.document { SourceView(document: doc, source: item.source, fieldLabel: item.label) }
        }
    }

    var doneLabel: String {
        if obligation.isPayment { return obligation.direction == .owedToMe ? "Mark as received" : "Mark as paid" }
        return "Mark as completed"
    }

    func save() {
        try? context.save()
        services.rescheduleReminders(context: context)
    }
}

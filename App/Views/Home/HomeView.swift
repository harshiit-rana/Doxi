import DoxiCore
import SwiftData
import SwiftUI

/// Dashboard: what's coming up, money owed each way, and what needs review.
struct HomeView: View {
    @Environment(AppServices.self) private var services
    @Environment(\.modelContext) private var context
    @Query private var obligations: [ObligationRecord]
    @Query(sort: \DocumentRecord.modifiedAt, order: .reverse) private var documents: [DocumentRecord]
    @State private var horizon = 30
    @State private var capture: CaptureAction?
    @State private var path = NavigationPath()

    var today: CalendarDate { .today() }

    /// Obligations of confirmed documents only.
    var tracked: [ObligationRecord] {
        obligations.filter { $0.document?.confirmedAt != nil }
            .sorted { ($0.dueDateISO ?? "9999") < ($1.dueDateISO ?? "9999") }
    }

    var overdue: [ObligationRecord] { tracked.filter { $0.status(today: today) == .overdue } }

    var upcoming: [ObligationRecord] {
        let limit = today.adding(days: horizon)
        return tracked.filter { ob in
            guard let due = ob.dueDate else { return false }
            let s = ob.status(today: today)
            return s.isOpen && s != .overdue && due <= limit
        }
    }

    var totals: MoneySummary.Totals {
        MoneySummary.totals(tracked.compactMap { ob in
            guard ob.isPayment, let amount = ob.amount else { return nil }
            return MoneySummary.Item(amount: amount, direction: ob.direction, status: ob.status(today: today))
        })
    }

    var needsReview: [DocumentRecord] { documents.filter(\.needsReview) }
    var working: [DocumentRecord] { documents.filter { $0.status.isWorking } }

    var body: some View {
        NavigationStack(path: $path) {
            List {
                if let banner = services.banner {
                    Section {
                        HStack {
                            Text(banner).font(.footnote)
                            Spacer()
                            Button("Dismiss") { services.banner = nil }.font(.footnote)
                        }
                    }
                }
                if services.notifications.isDenied && !tracked.isEmpty {
                    Section {
                        Label("Notifications are off, so reminders won't alert you.", systemImage: "bell.slash")
                            .font(.footnote)
                        Button("Turn on in Settings") {
                            if let url = URL(string: UIApplication.openNotificationSettingsURLString) { UIApplication.shared.open(url) }
                        }
                        .font(.footnote)
                    }
                }
                if !working.isEmpty {
                    Section("Processing") {
                        ForEach(working) { doc in
                            NavigationLink(value: doc.id) {
                                HStack { Text(doc.title).lineLimit(1); Spacer(); ProcessingBadge(status: doc.status) }
                            }
                        }
                    }
                }
                if !needsReview.isEmpty {
                    Section {
                        ForEach(needsReview) { doc in
                            NavigationLink(value: doc.id) {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(doc.title).lineLimit(1)
                                    Text("\(doc.pendingFieldCount) detail\(doc.pendingFieldCount == 1 ? "" : "s") to check")
                                        .font(.caption).foregroundStyle(.secondary)
                                }
                            }
                        }
                    } header: {
                        Text(needsReview.count == 1 ? "1 document needs review" : "\(needsReview.count) documents need review")
                    }
                }
                if !overdue.isEmpty {
                    Section("Overdue") {
                        ForEach(overdue) { ob in
                            NavigationLink { ObligationDetailView(obligation: ob) } label: { ObligationRow(obligation: ob) }
                        }
                    }
                }
                Section {
                    if upcoming.isEmpty {
                        Text(tracked.isEmpty ? "Confirmed payments, renewals and deadlines will appear here." : "Nothing due in the next \(horizon) days.")
                            .foregroundStyle(.secondary)
                    }
                    ForEach(upcoming) { ob in
                        NavigationLink { ObligationDetailView(obligation: ob) } label: { ObligationRow(obligation: ob) }
                    }
                } header: {
                    HStack {
                        Text("Upcoming")
                        Spacer()
                        Picker("Horizon", selection: $horizon) {
                            Text("30 days").tag(30)
                            Text("90 days").tag(90)
                        }
                        .pickerStyle(.segmented)
                        .fixedSize()
                        .textCase(nil)
                    }
                }
                moneySection
                if documents.isEmpty {
                    Section {
                        VStack(alignment: .leading, spacing: 12) {
                            Text("Add your first document").font(.headline)
                            Text("Scan a paper contract or import a PDF or photo. Doxi reads it on your device, finds parties, dates, amounts and deadlines, and shows you where each came from.")
                                .font(.subheadline).foregroundStyle(.secondary)
                            AddDocumentMenu(action: $capture).buttonStyle(.borderedProminent)
                        }
                        .padding(.vertical, 6)
                    }
                }
            }
            .navigationTitle("Doxi")
            .navigationDestination(for: UUID.self) { id in DocumentDetailLoaderInline(documentID: id) }
            .toolbar { ToolbarItem(placement: .primaryAction) { AddDocumentMenu(action: $capture) } }
            .documentCapture($capture) { doc in path.append(doc.id) }
            .refreshable { services.rescheduleReminders(context: context) }
        }
    }

    @ViewBuilder var moneySection: some View {
        let t = totals
        if !t.owedToMe.isEmpty || !t.iOwe.isEmpty || t.unassignedCount > 0 {
            Section {
                MoneyTotalRow(title: "Owed to me", amounts: t.owedToMe, symbol: FinancialDirection.owedToMe.symbol, tint: .green)
                    .accessibilityIdentifier("owedToMe")
                MoneyTotalRow(title: "I owe", amounts: t.iOwe, symbol: FinancialDirection.iOwe.symbol, tint: .orange)
                    .accessibilityIdentifier("iOwe")
                if t.unassignedCount > 0 {
                    Text("\(t.unassignedCount) open payment\(t.unassignedCount == 1 ? " has" : "s have") no direction yet and \(t.unassignedCount == 1 ? "is" : "are") not counted.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
            } header: {
                Text("Money")
            } footer: {
                Text("From confirmed, unpaid payments.")
            }
        }
    }
}

struct MoneyTotalRow: View {
    let title: String
    let amounts: [String: Int64]
    let symbol: String
    let tint: Color

    var body: some View {
        HStack {
            Label(title, systemImage: symbol).foregroundStyle(tint)
            Spacer()
            VStack(alignment: .trailing) {
                if amounts.isEmpty {
                    Text(Money(minorUnits: 0).formatted).font(.title3.monospacedDigit()).foregroundStyle(.secondary)
                }
                ForEach(amounts.keys.sorted(), id: \.self) { currency in
                    Text(Money(minorUnits: amounts[currency] ?? 0, currency: currency).formatted)
                        .font(.title3.weight(.semibold).monospacedDigit())
                }
            }
        }
        .accessibilityElement(children: .combine)
    }
}

import DoxiCore
import SwiftUI

/// Edits (or creates) the value of one field. Dates use the Indian DD/MM/YYYY
/// convention in display; amounts are entered in rupees unless another currency is chosen.
struct FieldEditorView: View {
    let kind: FieldKind
    let initial: FieldValue?
    let parties: [String]
    var onSave: (FieldValue) -> Void
    @Environment(\.dismiss) private var dismiss

    // Editing state for every value shape; only the fields relevant to `kind` are shown.
    @State private var text = ""
    @State private var role = ""
    @State private var documentType = DocumentType.contract
    @State private var hasDate = true
    @State private var date = Date()
    @State private var relativeNote: String?
    @State private var amountText = ""
    @State private var currency = "INR"
    @State private var durationValue = 30
    @State private var durationUnit = DurationUnit.days
    @State private var automatic: Int = 0 // 0 unknown, 1 yes, 2 no
    @State private var recurrence: RecurrenceFrequency?
    /// End of an existing recurrence (kept when the frequency is unchanged).
    @State private var recurrenceEnd: CalendarDate?
    @State private var payer = ""
    @State private var payee = ""
    @State private var category = ObligationCategory.deliverable
    @State private var clauseCategory = ClauseCategory.payment
    @State private var identifierType = IdentifierType.gstin

    var body: some View {
        NavigationStack {
            Form { editor }
                .navigationTitle(initial == nil ? "Add \(kind.displayName.lowercased())" : "Edit \(kind.displayName.lowercased())")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Save") {
                            if let v = makeValue() { onSave(v); dismiss() }
                        }
                        .disabled(makeValue() == nil)
                    }
                }
                .onAppear(perform: load)
        }
    }

    // MARK: Editors

    @ViewBuilder var editor: some View {
        switch kind {
        case .documentType:
            Picker("Type", selection: $documentType) {
                ForEach(DocumentType.allCases, id: \.self) { Text($0.displayName).tag($0) }
            }
        case .title:
            TextField("Title", text: $text)
        case .party:
            TextField("Name", text: $text).textContentType(.organizationName)
            TextField("Role (e.g. Client, Freelancer)", text: $role)
        case .effectiveDate, .endDate:
            dateEditor(label: "Date")
        case .totalAmount:
            amountEditor
        case .noticePeriod:
            durationEditor
        case .renewal:
            Picker("Renews automatically", selection: $automatic) {
                Text("Not stated").tag(0)
                Text("Yes").tag(1)
                Text("No").tag(2)
            }
            Toggle("Has renewal term", isOn: Binding(get: { durationValue > 0 }, set: { durationValue = $0 ? max(1, durationValue) : 0 }))
            if durationValue > 0 { durationEditor }
            TextField("Summary", text: $text, axis: .vertical)
        case .payment:
            TextField("Label (e.g. Installment 1)", text: $text)
            amountEditor
            Section("Due") {
                Toggle("Has a due date", isOn: $hasDate)
                if hasDate { dateEditor(label: "Due date") }
                Picker("Repeats", selection: $recurrence) {
                    Text("Does not repeat").tag(RecurrenceFrequency?.none)
                    ForEach(RecurrenceFrequency.allCases, id: \.self) { Text($0.displayName).tag(Optional($0)) }
                }
            }
            Section("Parties") {
                partyField("Paid by", selection: $payer)
                partyField("Paid to", selection: $payee)
            }
        case .paymentFrequency:
            Picker("Frequency", selection: Binding(get: { recurrence ?? .monthly }, set: { recurrence = $0 })) {
                ForEach(RecurrenceFrequency.allCases, id: \.self) { Text($0.displayName).tag($0) }
            }
        case .obligation:
            TextField("What needs to happen", text: $text, axis: .vertical)
            partyField("Responsible", selection: $payer)
            Picker("Type", selection: $category) {
                ForEach(ObligationCategory.allCases.filter { $0 != .payment }, id: \.self) { Text($0.displayName).tag($0) }
            }
            Toggle("Has a due date", isOn: $hasDate)
            if hasDate { dateEditor(label: "Due date") }
            Picker("Repeats", selection: $recurrence) {
                Text("Does not repeat").tag(RecurrenceFrequency?.none)
                ForEach(RecurrenceFrequency.allCases, id: \.self) { Text($0.displayName).tag(Optional($0)) }
            }
        case .clause:
            Picker("Category", selection: $clauseCategory) {
                ForEach(ClauseCategory.allCases, id: \.self) { Text($0.displayName).tag($0) }
            }
            TextField("Text", text: $text, axis: .vertical)
        case .identifier:
            Picker("Type", selection: $identifierType) {
                Text("GSTIN").tag(IdentifierType.gstin)
                Text("PAN").tag(IdentifierType.pan)
            }
            TextField("Value", text: $text).textInputAutocapitalization(.characters)
        }
    }

    @ViewBuilder func dateEditor(label: String) -> some View {
        DatePicker(label, selection: $date, displayedComponents: .date)
            .environment(\.locale, Locale(identifier: "en_IN"))
        if let relativeNote {
            Text(relativeNote).font(.footnote).foregroundStyle(.secondary)
        }
    }

    @ViewBuilder var amountEditor: some View {
        HStack {
            Picker("Currency", selection: $currency) {
                ForEach(["INR", "USD", "EUR", "GBP"], id: \.self) { Text($0).tag($0) }
            }
            .labelsHidden()
            .fixedSize()
            TextField("Amount", text: $amountText).keyboardType(.decimalPad)
        }
        if let money = parsedAmount {
            Text(money.formatted).font(.footnote).foregroundStyle(.secondary)
        } else if !amountText.isEmpty {
            Text("Enter a number, e.g. 80000 or 1.5 lakh").font(.footnote).foregroundStyle(.red)
        }
    }

    @ViewBuilder var durationEditor: some View {
        Stepper(value: $durationValue, in: 1...3650) {
            Text("\(durationValue)")
        }
        Picker("Unit", selection: $durationUnit) {
            Text("Days").tag(DurationUnit.days)
            Text("Weeks").tag(DurationUnit.weeks)
            Text("Months").tag(DurationUnit.months)
            Text("Years").tag(DurationUnit.years)
        }
        .pickerStyle(.segmented)
    }

    @ViewBuilder func partyField(_ label: String, selection: Binding<String>) -> some View {
        if parties.isEmpty {
            TextField(label, text: selection)
        } else {
            Picker(label, selection: selection) {
                Text("Not stated").tag("")
                ForEach(parties, id: \.self) { Text($0).tag($0) }
                if !selection.wrappedValue.isEmpty && !parties.contains(selection.wrappedValue) {
                    Text(selection.wrappedValue).tag(selection.wrappedValue)
                }
            }
        }
    }

    var parsedAmount: Money? { AmountParser.parseLoose(amountText, defaultCurrency: currency).map { Money(minorUnits: $0.minorUnits, currency: currency) } }
    var calendarDate: CalendarDate { CalendarDate(date) }

    // MARK: Load & build

    func setDate(_ d: DateValue?) {
        if let resolved = d?.resolved {
            date = resolved.foundationDate
            hasDate = true
        } else {
            hasDate = d != nil ? false : (initial == nil)
        }
        if let rel = d?.relative {
            relativeNote = "The document says: \(rel.phrase)." + (rel.baseDate == nil ? " Pick the actual date." : "")
        }
    }

    func load() {
        guard let initial else {
            hasDate = kind != .payment ? true : false
            return
        }
        switch initial {
        case .text(let s): text = s
        case .documentType(let t): documentType = t
        case .party(let p): text = p.name; role = p.role ?? ""
        case .date(let d): setDate(d)
        case .money(let m): amountText = "\(m.majorValue)"; currency = m.currency
        case .duration(let d): durationValue = d.value; durationUnit = d.unit
        case .renewal(let r):
            automatic = r.automatic == nil ? 0 : (r.automatic! ? 1 : 2)
            if let t = r.term { durationValue = t.value; durationUnit = t.unit } else { durationValue = 0 }
            text = r.summary
        case .payment(let p):
            text = p.label
            if let a = p.amount { amountText = "\(a.majorValue)"; currency = a.currency }
            setDate(p.due)
            recurrence = p.recurrence?.frequency
            recurrenceEnd = p.recurrence?.endDate
            payer = p.payer ?? ""
            payee = p.payee ?? ""
        case .frequency(let f): recurrence = f
        case .obligation(let o):
            text = o.summary
            payer = o.responsibleParty ?? ""
            category = o.category == .payment ? .other : o.category
            setDate(o.due)
            recurrence = o.recurrence?.frequency
        case .clause(let c): clauseCategory = c.category; text = c.summary
        case .identifier(let i): identifierType = i.type == .aadhaar ? .pan : i.type; text = i.value
        }
    }

    func makeValue() -> FieldValue? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        switch kind {
        case .documentType: return .documentType(documentType)
        case .title: return trimmed.isEmpty ? nil : .text(trimmed)
        case .party:
            guard !trimmed.isEmpty else { return nil }
            let r = role.trimmingCharacters(in: .whitespaces)
            return .party(PartyValue(name: trimmed, role: r.isEmpty ? nil : r))
        case .effectiveDate, .endDate: return .date(DateValue(date: calendarDate))
        case .totalAmount: return parsedAmount.map { .money($0) }
        case .noticePeriod: return .duration(Duration(value: durationValue, unit: durationUnit))
        case .renewal:
            let auto: Bool? = automatic == 0 ? nil : automatic == 1
            let term = durationValue > 0 ? Duration(value: durationValue, unit: durationUnit) : nil
            return .renewal(RenewalValue(automatic: auto, term: term, summary: trimmed.isEmpty ? "Renewal terms" : trimmed))
        case .payment:
            guard let amount = parsedAmount else { return nil }
            let due = hasDate ? DateValue(date: calendarDate) : nil
            return .payment(PaymentValue(amount: amount, due: due, label: trimmed.isEmpty ? "Payment" : trimmed,
                                         recurrence: recurrence.map { Recurrence(frequency: $0, endDate: recurrenceEnd) },
                                         payer: payer.isEmpty ? nil : payer, payee: payee.isEmpty ? nil : payee))
        case .paymentFrequency: return .frequency(recurrence ?? .monthly)
        case .obligation:
            guard !trimmed.isEmpty else { return nil }
            return .obligation(ObligationValue(summary: trimmed, responsibleParty: payer.isEmpty ? nil : payer,
                                               due: hasDate ? DateValue(date: calendarDate) : nil,
                                               recurrence: recurrence.map { Recurrence(frequency: $0) }, category: category))
        case .clause: return .clause(ClauseValue(category: clauseCategory, summary: trimmed))
        case .identifier: return trimmed.isEmpty ? nil : .identifier(IdentifierValue(type: identifierType, value: trimmed.uppercased()))
        }
    }
}

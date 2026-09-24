import DoxiCore
import Foundation
import SwiftData

/// Review actions and obligation lifecycle. Obligations are only ever created
/// from fields the user accepted, and payments are never marked received
/// automatically.
@MainActor
struct ObligationService {
    let settings: AppSettings

    // MARK: Field review

    func confirm(_ field: ExtractedFieldRecord, in doc: DocumentRecord) {
        field.verification = .confirmed
        // Choosing one value of a conflict rejects the alternatives.
        if let group = field.conflictGroup {
            for other in doc.fields where other.id != field.id && other.conflictGroup == group && other.verification == .pending {
                other.verification = .rejected
            }
        }
        doc.modifiedAt = .now
        refreshDerivedDates(doc)
    }

    func reject(_ field: ExtractedFieldRecord, in doc: DocumentRecord) {
        field.verification = .rejected
        doc.modifiedAt = .now
        refreshDerivedDates(doc)
    }

    func edit(_ field: ExtractedFieldRecord, value: FieldValue, in doc: DocumentRecord) {
        field.value = value
        field.verification = .edited
        field.confidence = .high
        if !field.notes.contains("Edited by you.") { field.notes.append("Edited by you.") }
        doc.modifiedAt = .now
        refreshDerivedDates(doc)
    }

    func addManualField(kind: FieldKind, value: FieldValue, to doc: DocumentRecord, context: ModelContext) {
        let draft = ExtractedFieldDraft(kind: kind, value: value, origin: .user, source: nil, confidence: .high,
                                        verification: .confirmed, notes: ["Added by you."])
        let record = ExtractedFieldRecord(draft: draft, sortIndex: (doc.fields.map(\.sortIndex).max() ?? 0) + 1)
        doc.fields.append(record)
        doc.modifiedAt = .now
        refreshDerivedDates(doc)
    }

    /// Re-derives relative dates of unreviewed fields after dates were confirmed or edited.
    func refreshDerivedDates(_ doc: DocumentRecord) {
        var drafts = doc.fields.map(\.draft)
        RelativeDateResolver.resolve(&drafts)
        for draft in drafts {
            guard let record = doc.fields.first(where: { $0.id == draft.id }), record.verification == .pending,
                  record.value != draft.value else { continue }
            record.value = draft.value
            let (confidence, notes) = ConfidenceScorer.score(draft)
            record.confidence = confidence
            record.notes = Array(Set(record.notes + notes)).sorted()
        }
    }

    func setIdentity(_ doc: DocumentRecord, partyName: String?) {
        doc.userPartyName = partyName
        doc.userIsNeither = partyName == nil
        doc.identityDecision = .userChosen
        doc.modifiedAt = .now
    }

    // MARK: Confirmation → obligations

    /// Creates obligations from accepted fields. Obligations already completed or
    /// changed by the user are kept; open auto-created ones are rebuilt.
    func finalize(_ doc: DocumentRecord, context: ModelContext) {
        let drafts = doc.fields.map(\.draft)
        // Same party list the review screen uses to show the inferred direction.
        let parties: [DirectionResolver.Party] = doc.fields.filter { $0.kind == .party && $0.verification != .rejected }.compactMap { f in
            if case .party(let p) = f.value { return DirectionResolver.Party(name: p.name, role: p.role) }
            return nil
        }
        let ctx = ObligationContext(parties: parties, userParty: doc.userPartyName, userIsNeither: doc.userIsNeither)
        var built = ObligationBuilder.build(from: drafts, context: ctx)
        for i in built.indices {
            if let fieldID = built[i].sourceFieldID, let field = doc.fields.first(where: { $0.id == fieldID }),
               let override = field.directionOverride, built[i].category == .payment {
                built[i].direction = override
                built[i].directionReason = "Set by you."
            }
        }

        let preserved = doc.obligations.filter { !$0.storedStatus.isOpen || !$0.history.isEmpty }
        for ob in doc.obligations where !preserved.contains(where: { $0.id == ob.id }) {
            context.delete(ob)
        }
        var result = preserved
        for draft in built {
            let duplicate = preserved.contains { $0.sourceFieldID == draft.sourceFieldID && $0.categoryRaw == draft.category.rawValue }
            if duplicate { continue }
            result.append(ObligationRecord(draft: draft, reminderOffsets: settings.reminderOffsets))
        }
        doc.obligations = result
        doc.status = .confirmed
        doc.confirmedAt = .now
        try? context.save()
    }

    // MARK: Obligation actions

    /// Marks a payment received (owed to me) or an obligation completed. Recurring
    /// obligations move to their next occurrence.
    func markDone(_ ob: ObligationRecord) {
        let today = CalendarDate.today()
        let doneStatus: ObligationStatus = ob.isPayment && ob.direction == .owedToMe ? .received : .completed
        let verb = doneStatus == .received ? "Received" : ob.isPayment ? "Paid" : "Completed"
        let dueText = ob.dueDate.map { " (due \($0.numericString))" } ?? ""
        ob.history.append("\(verb) on \(today.numericString)\(dueText)")
        if let rec = ob.recurrence, let due = ob.dueDate, let anchor = ob.anchorDate,
           let next = RecurrenceEngine.next(after: due, start: anchor, recurrence: rec) {
            ob.dueDate = next
            ob.storedStatus = .pending
        } else {
            ob.storedStatus = doneStatus
            ob.completedAt = .now
        }
    }

    func setStatus(_ ob: ObligationRecord, _ status: ObligationStatus) {
        ob.history.append("\(status.displayName) on \(CalendarDate.today().numericString)")
        ob.storedStatus = status
        ob.completedAt = status.isOpen ? nil : .now
    }

    func reopen(_ ob: ObligationRecord) {
        ob.history.append("Reopened on \(CalendarDate.today().numericString)")
        ob.storedStatus = ob.isPayment ? .pending : .upcoming
        ob.completedAt = nil
    }
}

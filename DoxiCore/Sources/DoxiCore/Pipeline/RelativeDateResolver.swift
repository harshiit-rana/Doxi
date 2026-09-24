import Foundation

/// Fills in the base date of relative dates ("30 days after signing") from the
/// document's effective/end date, so the derived date and its base are shown.
public enum RelativeDateResolver {
    public static func resolve(_ fields: inout [ExtractedFieldDraft]) {
        let effective = bestDate(of: .effectiveDate, in: fields)
        let end = bestDate(of: .endDate, in: fields)

        func base(for anchor: DateAnchor) -> (CalendarDate, String?)? {
            switch anchor {
            case .effectiveDate: return effective.map { ($0, nil) }
            case .signing: return effective.map { ($0, "The signing date was taken to be the effective date (\($0.numericString)). Check this.") }
            case .invoiceDate: return effective.map { ($0, nil) }
            case .endDate: return end.map { ($0, nil) }
            case .other: return nil
            }
        }

        func resolved(_ d: DateValue?, notes: inout [String]) -> DateValue? {
            guard var d, var rel = d.relative else { return d }
            guard let (b, note) = base(for: rel.anchor) else {
                rel.baseDate = nil
                d.relative = rel
                d.date = nil
                return d
            }
            rel.baseDate = b
            d.relative = rel
            d.date = nil
            if let note, !notes.contains(note) { notes.append(note) }
            return d
        }

        for i in fields.indices {
            var notes = fields[i].notes
            switch fields[i].value {
            case .date(let d):
                // An end date derived from the effective date must not use itself.
                if fields[i].kind == .effectiveDate { continue }
                fields[i].value = .date(resolved(d, notes: &notes) ?? d)
            case .payment(var p):
                p.due = resolved(p.due, notes: &notes)
                if var r = p.recurrence, r.endDate == nil, let end { r.endDate = end; p.recurrence = r }
                fields[i].value = .payment(p)
            case .obligation(var o):
                o.due = resolved(o.due, notes: &notes)
                fields[i].value = .obligation(o)
            default:
                break
            }
            fields[i].notes = notes
        }
    }

    /// The accepted or most trusted date of a kind.
    static func bestDate(of kind: FieldKind, in fields: [ExtractedFieldDraft]) -> CalendarDate? {
        let candidates = fields.filter { $0.kind == kind && $0.verification != .rejected }
        let ordered = candidates.sorted { a, b in
            if a.verification.isAccepted != b.verification.isAccepted { return a.verification.isAccepted }
            return a.confidence > b.confidence
        }
        for f in ordered {
            if case .date(let d) = f.value, let r = d.date ?? (kind == .endDate ? d.relative?.derivedDate : nil) { return r }
        }
        return nil
    }
}

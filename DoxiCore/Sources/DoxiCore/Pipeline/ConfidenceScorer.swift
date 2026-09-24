import Foundation

/// Assigns a confidence level from how a field was found, never from the
/// model's own claims.
public enum ConfidenceScorer {
    public static func score(_ field: ExtractedFieldDraft) -> (Confidence, [String]) {
        var notes: [String] = []
        guard let source = field.source else {
            if field.origin == .user { return (.high, []) }
            return (.unverified, ["No matching text was found in the document."])
        }
        var c: Confidence
        switch field.origin {
        case .user:
            return (.high, [])
        case .both:
            c = .high
        case .deterministic:
            c = field.ruleStrength == .strong ? .high : .medium
        case .llm:
            switch (source.match, field.valueVerifiedInSource) {
            case (_, false?): c = .low
            case (.valueOnly, _): c = .low
            case (.fuzzy, _): c = .low
            case (.exact, _), (.normalized, _): c = .medium
            }
        }
        if let ocr = source.ocrConfidence, ocr < 0.5 {
            c = c.lowered
            notes.append("The source text was hard to read in the scan.")
        }
        if case .date(let d) = field.value, d.ambiguousFormat, field.origin != .both {
            c = c.lowered
            notes.append("The numeric date could be read as DD/MM or MM/DD.")
        }
        if let rel = relativeSpec(field.value), rel.baseDate == nil {
            c = min(c, .medium)
            notes.append("This date depends on \(rel.anchorText), which is not known yet.")
        }
        if field.conflictGroup != nil {
            c = min(c, .medium)
            notes.append("A different value was also found for this field. Choose the correct one.")
        }
        return (c, notes)
    }

    static func relativeSpec(_ v: FieldValue) -> RelativeDateSpec? {
        switch v {
        case .date(let d): return d.relative
        case .payment(let p): return p.due?.relative
        case .obligation(let o): return o.due?.relative
        default: return nil
        }
    }

    /// Scores in place, appending explanatory notes.
    public static func apply(_ fields: inout [ExtractedFieldDraft]) {
        for i in fields.indices {
            let (c, notes) = score(fields[i])
            fields[i].confidence = c
            for n in notes where !fields[i].notes.contains(n) { fields[i].notes.append(n) }
        }
    }
}

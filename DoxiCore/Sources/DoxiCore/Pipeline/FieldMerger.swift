import Foundation

/// Merges rule-based and model-based fields. Agreement raises confidence;
/// disagreement on single-valued fields is surfaced as a conflict for the user.
public enum FieldMerger {
    public static func equivalent(_ a: FieldValue, _ b: FieldValue) -> Bool {
        switch (a, b) {
        case let (.documentType(x), .documentType(y)): return x == y
        case let (.text(x), .text(y)):
            let tx = Set(TextNormalizer.tokens(x)), ty = Set(TextNormalizer.tokens(y))
            return !tx.isEmpty && Double(tx.intersection(ty).count) / Double(tx.union(ty).count) >= 0.6
        case let (.party(x), .party(y)): return PartyMatcher.similarity(x.name, y.name) >= PartyMatcher.matchThreshold
        case let (.date(x), .date(y)):
            if let dx = x.resolved, let dy = y.resolved { return dx == dy }
            if let rx = x.relative, let ry = y.relative { return rx.offset.approximateDays == ry.offset.approximateDays && rx.after == ry.after }
            return false
        case let (.money(x), .money(y)): return x.minorUnits == y.minorUnits
        case let (.duration(x), .duration(y)): return x.approximateDays == y.approximateDays
        case let (.renewal(x), .renewal(y)): return x.automatic == y.automatic
        case let (.payment(x), .payment(y)):
            guard x.amount?.minorUnits == y.amount?.minorUnits else { return false }
            let dx = x.due?.resolved, dy = y.due?.resolved
            if let dx, let dy { return dx == dy }
            if let rx = x.due?.relative, let ry = y.due?.relative { return rx.offset.approximateDays == ry.offset.approximateDays }
            return x.due == nil || y.due == nil
        case let (.frequency(x), .frequency(y)): return x == y
        case let (.obligation(x), .obligation(y)):
            guard x.due?.resolved == y.due?.resolved else { return false }
            let tx = Set(TextNormalizer.tokens(x.summary)), ty = Set(TextNormalizer.tokens(y.summary))
            return !tx.isEmpty && Double(tx.intersection(ty).count) / Double(min(tx.count, ty.count)) >= 0.4
        case let (.clause(x), .clause(y)): return x.category == y.category
        case let (.identifier(x), .identifier(y)): return x.value == y.value
        default: return false
        }
    }

    /// Adds details the model found that the rules did not (roles, payer/payee, due dates).
    static func enrich(_ base: FieldValue, with other: FieldValue) -> FieldValue {
        switch (base, other) {
        case let (.party(x), .party(y)):
            return .party(PartyValue(name: x.name, role: x.role ?? y.role))
        case let (.payment(x), .payment(y)):
            var p = x
            p.payer = p.payer ?? y.payer
            p.payee = p.payee ?? y.payee
            p.due = p.due ?? y.due
            p.recurrence = p.recurrence ?? y.recurrence
            if p.label == "Payment", y.label != "Payment" { p.label = y.label }
            return .payment(p)
        case let (.renewal(x), .renewal(y)):
            return .renewal(RenewalValue(automatic: x.automatic ?? y.automatic, term: x.term ?? y.term, summary: x.summary))
        case let (.obligation(x), .obligation(y)):
            var o = x
            o.responsibleParty = o.responsibleParty ?? y.responsibleParty
            o.recurrence = o.recurrence ?? y.recurrence
            return .obligation(o)
        default:
            return base
        }
    }

    public static func merge(deterministic: [ExtractedFieldDraft], llm: [ExtractedFieldDraft]) -> [ExtractedFieldDraft] {
        var result = deterministic
        var mergedIDs = Set<UUID>()
        for l in llm {
            if let i = result.indices.first(where: { result[$0].kind == l.kind && result[$0].origin == .deterministic
                                                    && !mergedIDs.contains(result[$0].id) && equivalent(result[$0].value, l.value) }) {
                result[i].origin = .both
                result[i].value = enrich(result[i].value, with: l.value)
                if result[i].source == nil { result[i].source = l.source }
                mergedIDs.insert(result[i].id)
                continue
            }
            // Duplicate model items (same kind and value) are dropped.
            if result.contains(where: { $0.kind == l.kind && $0.origin == .llm && equivalent($0.value, l.value) }) { continue }
            result.append(l)
        }
        resolveSingleValued(&result)
        return result
    }

    static func resolveSingleValued(_ fields: inout [ExtractedFieldDraft]) {
        for kind in FieldKind.allCases where kind.isSingleValued {
            let indices = fields.indices.filter { fields[$0].kind == kind }
            guard indices.count > 1 else { continue }
            switch kind {
            case .documentType:
                // A generic "contract" from the rules yields to a more specific type.
                if let generic = indices.first(where: { fields[$0].origin == .deterministic && fields[$0].value == .documentType(.contract) }) {
                    fields.remove(at: generic)
                    continue
                }
            case .title:
                // Keep the title as written in the document.
                if let det = indices.first(where: { fields[$0].origin != .llm }) {
                    for i in indices.reversed() where i != det && fields[i].origin == .llm { fields.remove(at: i) }
                    continue
                }
            default:
                break
            }
            let group = kind.rawValue
            for i in fields.indices where fields[i].kind == kind { fields[i].conflictGroup = group }
        }
    }
}

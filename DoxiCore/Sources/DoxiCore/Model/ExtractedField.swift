import Foundation

public enum FieldKind: String, Codable, CaseIterable, Sendable {
    case documentType
    case title
    case party
    case effectiveDate
    case endDate
    case renewal
    case noticePeriod
    case totalAmount
    case payment
    case paymentFrequency
    case obligation
    case clause
    case identifier

    public var displayName: String {
        switch self {
        case .documentType: return "Document type"
        case .title: return "Title"
        case .party: return "Party"
        case .effectiveDate: return "Effective date"
        case .endDate: return "End date"
        case .renewal: return "Renewal"
        case .noticePeriod: return "Notice period"
        case .totalAmount: return "Total amount"
        case .payment: return "Payment"
        case .paymentFrequency: return "Payment frequency"
        case .obligation: return "Obligation"
        case .clause: return "Important clause"
        case .identifier: return "Identifier"
        }
    }

    /// Kinds for which a document should have at most one value.
    public var isSingleValued: Bool {
        switch self {
        case .documentType, .title, .effectiveDate, .endDate, .renewal, .noticePeriod, .totalAmount, .paymentFrequency:
            return true
        case .party, .payment, .obligation, .clause, .identifier:
            return false
        }
    }

    /// Order used when presenting fields for review.
    public var sortRank: Int { FieldKind.allCases.firstIndex(of: self) ?? 0 }
}

/// The normalized value of an extracted field.
public enum FieldValue: Codable, Hashable, Sendable {
    case text(String)
    case documentType(DocumentType)
    case party(PartyValue)
    case date(DateValue)
    case money(Money)
    case duration(Duration)
    case renewal(RenewalValue)
    case payment(PaymentValue)
    case frequency(RecurrenceFrequency)
    case obligation(ObligationValue)
    case clause(ClauseValue)
    case identifier(IdentifierValue)

    /// Human-readable value.
    public var displayString: String {
        switch self {
        case .text(let s): return s
        case .documentType(let t): return t.displayName
        case .party(let p): return p.role.map { "\(p.name) (\($0))" } ?? p.name
        case .date(let d): return d.formatted
        case .money(let m): return m.formatted
        case .duration(let d): return d.formatted
        case .renewal(let r):
            var parts: [String] = []
            if let auto = r.automatic { parts.append(auto ? "Automatic renewal" : "Renewal is not automatic") }
            if let term = r.term { parts.append("for \(term.formatted)") }
            return parts.isEmpty ? r.summary : parts.joined(separator: " ")
        case .payment(let p):
            var s = p.amount?.formatted ?? "Amount not stated"
            if let due = p.due { s += " — due \(due.formatted)" }
            if let r = p.recurrence { s += " — \(r.displayName.lowercased())" }
            return s
        case .frequency(let f): return f.displayName
        case .obligation(let o):
            var s = o.summary
            if let due = o.due { s += " — by \(due.formatted)" }
            return s
        case .clause(let c): return c.category.displayName
        case .identifier(let i): return "\(i.type.displayName): \(i.value)"
        }
    }

    /// Text used for search indexing.
    public var searchableText: String {
        switch self {
        case .payment(let p):
            return [displayString, p.label, p.payer ?? "", p.payee ?? ""].joined(separator: " ")
        case .obligation(let o):
            return [displayString, o.responsibleParty ?? ""].joined(separator: " ")
        case .clause(let c): return c.category.displayName + " " + c.summary
        case .renewal(let r): return displayString + " " + r.summary
        default: return displayString
        }
    }

    /// The primary date of the value, if any.
    public var primaryDate: CalendarDate? {
        switch self {
        case .date(let d): return d.resolved
        case .payment(let p): return p.due?.resolved
        case .obligation(let o): return o.due?.resolved
        default: return nil
        }
    }

    /// The primary amount of the value, if any.
    public var primaryAmount: Money? {
        switch self {
        case .money(let m): return m
        case .payment(let p): return p.amount
        default: return nil
        }
    }
}

public enum Confidence: String, Codable, CaseIterable, Sendable, Comparable {
    case high, medium, low, unverified

    var rank: Int {
        switch self { case .high: return 3; case .medium: return 2; case .low: return 1; case .unverified: return 0 }
    }

    public static func < (lhs: Confidence, rhs: Confidence) -> Bool { lhs.rank < rhs.rank }

    public var lowered: Confidence {
        switch self { case .high: return .medium; case .medium: return .low; case .low, .unverified: return self }
    }

    public var displayName: String {
        switch self {
        case .high: return "High confidence"
        case .medium: return "Medium confidence"
        case .low: return "Low confidence"
        case .unverified: return "Unverified"
        }
    }
}

public enum VerificationStatus: String, Codable, Sendable {
    /// Extracted, not yet reviewed.
    case pending
    /// Reviewed and accepted unchanged.
    case confirmed
    /// Reviewed and corrected by the user.
    case edited
    /// Rejected by the user.
    case rejected

    public var isAccepted: Bool { self == .confirmed || self == .edited }
}

public enum FieldOrigin: String, Codable, Sendable {
    case deterministic
    case llm
    /// Found by both the rules and the language model with the same value.
    case both
    case user

    public var displayName: String {
        switch self {
        case .deterministic: return "On-device rules"
        case .llm: return "AI extraction"
        case .both: return "Rules + AI agree"
        case .user: return "Added by you"
        }
    }
}

/// Strength of the deterministic rule that produced a field.
public enum RuleStrength: String, Codable, Sendable {
    /// Explicit label or unambiguous pattern ("Notice period: 30 days", a GSTIN).
    case strong
    /// Keyword proximity heuristic.
    case weak
}

/// An extracted fact before it is persisted.
public struct ExtractedFieldDraft: Codable, Hashable, Identifiable, Sendable {
    public var id: UUID
    public var kind: FieldKind
    public var value: FieldValue
    public var origin: FieldOrigin
    public var source: SourceSpan?
    public var confidence: Confidence
    public var verification: VerificationStatus
    /// Why the confidence is what it is. Shown to the user.
    public var notes: [String]
    /// Fields sharing a conflict group disagree with each other.
    public var conflictGroup: String?
    /// Deterministic rule strength; `nil` for model-produced fields.
    public var ruleStrength: RuleStrength?
    /// For model output: whether the value itself was found inside the source quote.
    public var valueVerifiedInSource: Bool?

    public init(id: UUID = UUID(), kind: FieldKind, value: FieldValue, origin: FieldOrigin, source: SourceSpan?,
                confidence: Confidence = .unverified, verification: VerificationStatus = .pending, notes: [String] = [],
                conflictGroup: String? = nil, ruleStrength: RuleStrength? = nil, valueVerifiedInSource: Bool? = nil) {
        self.id = id
        self.kind = kind
        self.value = value
        self.origin = origin
        self.source = source
        self.confidence = confidence
        self.verification = verification
        self.notes = notes
        self.conflictGroup = conflictGroup
        self.ruleStrength = ruleStrength
        self.valueVerifiedInSource = valueVerifiedInSource
    }

    public var displayValue: String { value.displayString }
}

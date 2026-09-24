import Foundation

public enum DocumentType: String, Codable, CaseIterable, Sendable {
    case freelanceAgreement
    case serviceAgreement
    case contract
    case nda
    case invoice
    case quotation
    case vendorAgreement
    case rentalAgreement
    case paymentSchedule
    case purchaseOrder
    case businessLetter
    case other

    public var displayName: String {
        switch self {
        case .freelanceAgreement: return "Freelance Agreement"
        case .serviceAgreement: return "Service Agreement"
        case .contract: return "Contract"
        case .nda: return "Non-Disclosure Agreement"
        case .invoice: return "Invoice"
        case .quotation: return "Quotation"
        case .vendorAgreement: return "Vendor Agreement"
        case .rentalAgreement: return "Rent / Lease Agreement"
        case .paymentSchedule: return "Payment Schedule"
        case .purchaseOrder: return "Purchase Order"
        case .businessLetter: return "Business Letter"
        case .other: return "Other Document"
        }
    }

    /// Parses loose labels such as "freelance_agreement", "NDA", "Tax Invoice".
    public init?(loose: String) {
        let key = loose.lowercased().replacingOccurrences(of: "_", with: " ").replacingOccurrences(of: "-", with: " ")
        if let exact = DocumentType.allCases.first(where: { $0.rawValue.lowercased() == key.replacingOccurrences(of: " ", with: "") }) {
            self = exact
            return
        }
        let table: [(String, DocumentType)] = [
            ("non disclosure", .nda), ("nda", .nda), ("confidentiality agreement", .nda),
            ("freelance", .freelanceAgreement), ("invoice", .invoice), ("bill", .invoice),
            ("quotation", .quotation), ("quote", .quotation), ("estimate", .quotation), ("proposal", .quotation),
            ("vendor", .vendorAgreement), ("supply", .vendorAgreement),
            ("rent", .rentalAgreement), ("lease", .rentalAgreement), ("leave and licen", .rentalAgreement),
            ("payment schedule", .paymentSchedule), ("purchase order", .purchaseOrder),
            ("letter", .businessLetter), ("service", .serviceAgreement), ("consult", .serviceAgreement),
            ("agreement", .contract), ("contract", .contract), ("other", .other),
        ]
        guard let hit = table.first(where: { key.contains($0.0) }) else { return nil }
        self = hit.1
    }

    public var isAgreement: Bool {
        switch self {
        case .freelanceAgreement, .serviceAgreement, .contract, .nda, .vendorAgreement, .rentalAgreement: return true
        default: return false
        }
    }
}

public enum DurationUnit: String, Codable, Sendable {
    case days, weeks, months, years
}

public struct Duration: Codable, Hashable, Sendable {
    public var value: Int
    public var unit: DurationUnit

    public init(value: Int, unit: DurationUnit) {
        self.value = value
        self.unit = unit
    }

    public var approximateDays: Int {
        switch unit {
        case .days: return value
        case .weeks: return value * 7
        case .months: return value * 30
        case .years: return value * 365
        }
    }

    public var formatted: String {
        let singular: String
        switch unit {
        case .days: singular = "day"
        case .weeks: singular = "week"
        case .months: singular = "month"
        case .years: singular = "year"
        }
        return "\(value) \(singular)\(value == 1 ? "" : "s")"
    }

    /// Applies the duration to a date in the given direction.
    public func apply(to date: CalendarDate, forward: Bool = true) -> CalendarDate {
        let sign = forward ? 1 : -1
        switch unit {
        case .days: return date.adding(days: sign * value)
        case .weeks: return date.adding(days: sign * value * 7)
        case .months: return date.adding(months: sign * value)
        case .years: return date.adding(years: sign * value)
        }
    }
}

public enum RecurrenceFrequency: String, Codable, CaseIterable, Sendable {
    case weekly, monthly, quarterly, halfYearly, yearly

    public var displayName: String {
        switch self {
        case .weekly: return "Weekly"
        case .monthly: return "Monthly"
        case .quarterly: return "Quarterly"
        case .halfYearly: return "Every 6 months"
        case .yearly: return "Yearly"
        }
    }

    public init?(loose: String) {
        let s = loose.lowercased()
        if s.contains("week") { self = .weekly }
        else if s.contains("quarter") { self = .quarterly }
        else if s.contains("half") || s.contains("semi") || s.contains("6 month") || s.contains("six month") { self = .halfYearly }
        else if s.contains("month") || s == "pm" || s == "p.m." { self = .monthly }
        else if s.contains("year") || s.contains("annual") || s.contains("annum") { self = .yearly }
        else { return nil }
    }
}

/// A repeating schedule anchored on a first occurrence.
public struct Recurrence: Codable, Hashable, Sendable {
    public var frequency: RecurrenceFrequency
    public var interval: Int
    /// Last date on which an occurrence may fall (inclusive).
    public var endDate: CalendarDate?

    public init(frequency: RecurrenceFrequency, interval: Int = 1, endDate: CalendarDate? = nil) {
        self.frequency = frequency
        self.interval = max(1, interval)
        self.endDate = endDate
    }

    public var displayName: String {
        interval == 1 ? frequency.displayName : "\(frequency.displayName) ×\(interval)"
    }
}

/// What a relative date is measured from.
public enum DateAnchor: String, Codable, Sendable {
    case effectiveDate
    case signing
    case invoiceDate
    case endDate
    case other

    public var displayName: String {
        switch self {
        case .effectiveDate: return "effective date"
        case .signing: return "signing"
        case .invoiceDate: return "invoice date"
        case .endDate: return "end date"
        case .other: return "reference event"
        }
    }
}

/// A date expressed relative to another event, e.g. "30 days after signing".
public struct RelativeDateSpec: Codable, Hashable, Sendable {
    public var offset: Duration
    public var after: Bool
    public var anchor: DateAnchor
    /// The words used in the document for the anchor ("the date of this Agreement").
    public var anchorText: String
    /// The base date used to derive the concrete date, when known.
    public var baseDate: CalendarDate?
    /// True for contract terms ("a period of 11 months from 1 July"): the term ends on
    /// the day before the anniversary.
    public var isTermLength: Bool?

    public init(offset: Duration, after: Bool, anchor: DateAnchor, anchorText: String, baseDate: CalendarDate? = nil, isTermLength: Bool? = nil) {
        self.offset = offset
        self.after = after
        self.anchor = anchor
        self.anchorText = anchorText
        self.baseDate = baseDate
        self.isTermLength = isTermLength
    }

    public var derivedDate: CalendarDate? {
        baseDate.map { base in
            let d = offset.apply(to: base, forward: after)
            return isTermLength == true ? d.adding(days: -1) : d
        }
    }

    public var phrase: String {
        if isTermLength == true { return "end of a \(offset.formatted) term from \(anchorText)" }
        return "\(offset.formatted) \(after ? "after" : "before") \(anchorText)"
    }
}

/// A date that is either stated in the document or derived from a relative phrase.
public struct DateValue: Codable, Hashable, Sendable {
    public var date: CalendarDate?
    public var relative: RelativeDateSpec?
    /// True when the numeric format could be read as either DD/MM or MM/DD.
    public var ambiguousFormat: Bool

    public init(date: CalendarDate?, relative: RelativeDateSpec? = nil, ambiguousFormat: Bool = false) {
        self.date = date
        self.relative = relative
        self.ambiguousFormat = ambiguousFormat
    }

    public static func relative(_ spec: RelativeDateSpec) -> DateValue {
        DateValue(date: spec.derivedDate, relative: spec)
    }

    /// The concrete date: stated, or derived from the base date.
    public var resolved: CalendarDate? { date ?? relative?.derivedDate }

    public var formatted: String {
        if let rel = relative {
            if let derived = rel.derivedDate, let base = rel.baseDate {
                return "\(derived.numericString) (\(rel.phrase): base \(base.numericString))"
            }
            return rel.phrase.prefix(1).uppercased() + rel.phrase.dropFirst() + " (base date unknown)"
        }
        return date?.numericString ?? "—"
    }
}

public enum FinancialDirection: String, Codable, CaseIterable, Sendable {
    case owedToMe
    case iOwe
    /// The user is not a party to this payment.
    case notMine
    case unknown

    public var displayName: String {
        switch self {
        case .owedToMe: return "Owed to me"
        case .iOwe: return "I owe"
        case .notMine: return "Not my payment"
        case .unknown: return "Direction not set"
        }
    }
}

public struct PaymentValue: Codable, Hashable, Sendable {
    public var amount: Money?
    public var due: DateValue?
    public var label: String
    public var recurrence: Recurrence?
    public var payer: String?
    public var payee: String?

    public init(amount: Money?, due: DateValue?, label: String, recurrence: Recurrence? = nil, payer: String? = nil, payee: String? = nil) {
        self.amount = amount
        self.due = due
        self.label = label
        self.recurrence = recurrence
        self.payer = payer
        self.payee = payee
    }
}

public struct PartyValue: Codable, Hashable, Sendable {
    public var name: String
    public var role: String?

    public init(name: String, role: String? = nil) {
        self.name = name
        self.role = role
    }
}

public struct RenewalValue: Codable, Hashable, Sendable {
    public var automatic: Bool?
    public var term: Duration?
    public var summary: String

    public init(automatic: Bool?, term: Duration?, summary: String) {
        self.automatic = automatic
        self.term = term
        self.summary = summary
    }
}

public enum ObligationCategory: String, Codable, CaseIterable, Sendable {
    case payment, renewal, noticeDeadline, contractEnd, deliverable, deadline, other

    public var displayName: String {
        switch self {
        case .payment: return "Payment"
        case .renewal: return "Renewal"
        case .noticeDeadline: return "Notice deadline"
        case .contractEnd: return "Contract end"
        case .deliverable: return "Deliverable"
        case .deadline: return "Deadline"
        case .other: return "Obligation"
        }
    }

    public init(loose: String) {
        let s = loose.lowercased()
        if s.contains("pay") { self = .payment }
        else if s.contains("renew") { self = .renewal }
        else if s.contains("notice") { self = .noticeDeadline }
        else if s.contains("deliver") || s.contains("milestone") { self = .deliverable }
        else if s.contains("deadline") || s.contains("due") { self = .deadline }
        else { self = .other }
    }
}

public struct ObligationValue: Codable, Hashable, Sendable {
    public var summary: String
    public var responsibleParty: String?
    public var due: DateValue?
    public var recurrence: Recurrence?
    public var category: ObligationCategory

    public init(summary: String, responsibleParty: String?, due: DateValue?, recurrence: Recurrence?, category: ObligationCategory) {
        self.summary = summary
        self.responsibleParty = responsibleParty
        self.due = due
        self.recurrence = recurrence
        self.category = category
    }
}

public enum ClauseCategory: String, Codable, CaseIterable, Sendable {
    case payment, renewal, termination, notice, confidentiality, deliverables, penalties, deadlines

    public var displayName: String {
        switch self {
        case .payment: return "Payment"
        case .renewal: return "Renewal"
        case .termination: return "Termination"
        case .notice: return "Notice period"
        case .confidentiality: return "Confidentiality"
        case .deliverables: return "Deliverables"
        case .penalties: return "Penalties / late fees"
        case .deadlines: return "Deadlines"
        }
    }

    public init?(loose: String) {
        let s = loose.lowercased()
        if s.contains("pay") || s.contains("fee") { self = .payment }
        else if s.contains("renew") { self = .renewal }
        else if s.contains("terminat") { self = .termination }
        else if s.contains("notice") { self = .notice }
        else if s.contains("confiden") || s.contains("non-disclosure") { self = .confidentiality }
        else if s.contains("deliver") || s.contains("scope") { self = .deliverables }
        else if s.contains("penal") || s.contains("late") || s.contains("damages") || s.contains("interest") { self = .penalties }
        else if s.contains("deadline") || s.contains("timeline") || s.contains("schedule") { self = .deadlines }
        else { return nil }
    }
}

public struct ClauseValue: Codable, Hashable, Sendable {
    public var category: ClauseCategory
    public var summary: String

    public init(category: ClauseCategory, summary: String) {
        self.category = category
        self.summary = summary
    }
}

public enum IdentifierType: String, Codable, Sendable {
    case gstin, pan, aadhaar

    public var displayName: String {
        switch self {
        case .gstin: return "GSTIN"
        case .pan: return "PAN"
        case .aadhaar: return "Aadhaar"
        }
    }
}

public struct IdentifierValue: Codable, Hashable, Sendable {
    public var type: IdentifierType
    /// Stored value. Aadhaar numbers are stored masked (last four digits only).
    public var value: String

    public init(type: IdentifierType, value: String) {
        self.type = type
        self.value = value
    }
}

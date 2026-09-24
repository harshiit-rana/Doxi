import Foundation

public enum ObligationStatus: String, Codable, CaseIterable, Sendable {
    case upcoming, pending, completed, received, overdue, cancelled, dismissed

    public var displayName: String {
        switch self {
        case .upcoming: return "Upcoming"
        case .pending: return "Pending"
        case .completed: return "Completed"
        case .received: return "Received"
        case .overdue: return "Overdue"
        case .cancelled: return "Cancelled"
        case .dismissed: return "Dismissed"
        }
    }

    /// Still requires attention (and reminders).
    public var isOpen: Bool { self == .upcoming || self == .pending || self == .overdue }

    /// The status to show today: open items past their due date are overdue.
    /// Nothing is ever marked received or completed automatically.
    public static func effective(stored: ObligationStatus, due: CalendarDate?, today: CalendarDate) -> ObligationStatus {
        guard stored.isOpen, let due else { return stored }
        return due < today ? .overdue : (stored == .overdue ? .pending : stored)
    }
}

/// An obligation proposed from confirmed fields, before persistence.
public struct ObligationDraft: Hashable, Sendable {
    public var category: ObligationCategory
    public var title: String
    public var detail: String
    public var amount: Money?
    public var dueDate: CalendarDate?
    /// How the due date was derived, e.g. "30 days before 15/12/2026 (end date)".
    public var dueDateExplanation: String?
    public var recurrence: Recurrence?
    public var responsibleParty: String?
    public var counterparty: String?
    public var direction: FinancialDirection
    public var directionReason: String?
    public var status: ObligationStatus
    public var sourceFieldID: UUID?
    public var source: SourceSpan?

    public init(category: ObligationCategory, title: String, detail: String, amount: Money? = nil, dueDate: CalendarDate? = nil,
                dueDateExplanation: String? = nil, recurrence: Recurrence? = nil, responsibleParty: String? = nil,
                counterparty: String? = nil, direction: FinancialDirection = .unknown, directionReason: String? = nil,
                status: ObligationStatus, sourceFieldID: UUID? = nil, source: SourceSpan? = nil) {
        self.category = category
        self.title = title
        self.detail = detail
        self.amount = amount
        self.dueDate = dueDate
        self.dueDateExplanation = dueDateExplanation
        self.recurrence = recurrence
        self.responsibleParty = responsibleParty
        self.counterparty = counterparty
        self.direction = direction
        self.directionReason = directionReason
        self.status = status
        self.sourceFieldID = sourceFieldID
        self.source = source
    }
}

public struct ObligationContext: Sendable {
    /// Parties of the document (confirmed).
    public var parties: [DirectionResolver.Party]
    /// The party the user said is them.
    public var userParty: String?
    public var userIsNeither: Bool

    public init(parties: [DirectionResolver.Party], userParty: String?, userIsNeither: Bool) {
        self.parties = parties
        self.userParty = userParty
        self.userIsNeither = userIsNeither
    }
}

/// Builds obligations only from fields the user accepted.
public enum ObligationBuilder {
    public static func build(from fields: [ExtractedFieldDraft], context: ObligationContext) -> [ObligationDraft] {
        let accepted = fields.filter { $0.verification.isAccepted }
        var out: [ObligationDraft] = []

        func first(_ kind: FieldKind) -> ExtractedFieldDraft? { accepted.first { $0.kind == kind } }
        let counterparty = context.userParty.flatMap { user in
            context.parties.first { PartyMatcher.similarity($0.name, user) < PartyMatcher.matchThreshold }?.name
        } ?? (context.userParty == nil ? context.parties.first?.name : nil)

        // Payments
        for f in accepted where f.kind == .payment {
            guard case .payment(let p) = f.value else { continue }
            let dir = DirectionResolver.resolve(payer: p.payer, payee: p.payee, userParty: context.userParty,
                                                userIsNeither: context.userIsNeither, parties: context.parties)
            var explanation: String?
            if let rel = p.due?.relative, let base = rel.baseDate { explanation = "\(rel.phrase) (base \(base.numericString))" }
            let amountText = p.amount?.formatted ?? "Payment"
            out.append(ObligationDraft(
                category: .payment,
                title: p.recurrence != nil ? "\(p.label) \(amountText)" : "\(amountText) \(p.label.lowercased())",
                detail: f.source?.quote.collapsingWhitespace() ?? p.label,
                amount: p.amount, dueDate: p.due?.resolved, dueDateExplanation: explanation, recurrence: p.recurrence,
                responsibleParty: p.payer, counterparty: dir.direction == .owedToMe ? (p.payer ?? counterparty) : (p.payee ?? counterparty),
                direction: dir.direction, directionReason: dir.reason, status: .pending,
                sourceFieldID: f.id, source: f.source))
        }

        // Contract end / renewal / notice
        let endField = first(.endDate)
        let endDate: CalendarDate? = {
            guard let f = endField, case .date(let d) = f.value else { return nil }
            return d.resolved
        }()
        let renewalField = first(.renewal)
        var renewal: RenewalValue?
        if let f = renewalField, case .renewal(let r) = f.value { renewal = r }

        if let endDate, let endField {
            if renewal?.automatic == true {
                let term = renewal?.term.map { " for \($0.formatted)" } ?? ""
                out.append(ObligationDraft(category: .renewal, title: "Contract renews automatically\(term)",
                                           detail: renewal?.summary ?? "", amount: nil, dueDate: endDate, dueDateExplanation: "End of the current term",
                                           recurrence: nil, responsibleParty: nil, counterparty: counterparty, direction: .unknown,
                                           directionReason: nil, status: .upcoming, sourceFieldID: renewalField?.id, source: renewalField?.source ?? endField.source))
            } else if renewal != nil {
                out.append(ObligationDraft(category: .renewal, title: "Contract ends — renewal decision", detail: renewal?.summary ?? "",
                                           amount: nil, dueDate: endDate, dueDateExplanation: nil, recurrence: nil, responsibleParty: nil,
                                           counterparty: counterparty, direction: .unknown, directionReason: nil, status: .upcoming,
                                           sourceFieldID: endField.id, source: endField.source))
            } else {
                out.append(ObligationDraft(category: .contractEnd, title: "Contract ends", detail: endField.source?.quote.collapsingWhitespace() ?? "",
                                           amount: nil, dueDate: endDate, dueDateExplanation: nil, recurrence: nil, responsibleParty: nil,
                                           counterparty: counterparty, direction: .unknown, directionReason: nil, status: .upcoming,
                                           sourceFieldID: endField.id, source: endField.source))
            }
            if let noticeField = first(.noticePeriod), case .duration(let notice) = noticeField.value {
                let deadline = notice.apply(to: endDate, forward: false)
                out.append(ObligationDraft(category: .noticeDeadline, title: "Notice deadline (\(notice.formatted) notice)",
                                           detail: noticeField.source?.quote.collapsingWhitespace() ?? "",
                                           amount: nil, dueDate: deadline,
                                           dueDateExplanation: "\(notice.formatted) before \(endDate.numericString) (end date)",
                                           recurrence: nil, responsibleParty: nil, counterparty: counterparty, direction: .unknown,
                                           directionReason: nil, status: .upcoming, sourceFieldID: noticeField.id, source: noticeField.source))
            }
        }

        // Other obligations
        for f in accepted where f.kind == .obligation {
            guard case .obligation(let o) = f.value else { continue }
            var explanation: String?
            if let rel = o.due?.relative, let base = rel.baseDate { explanation = "\(rel.phrase) (base \(base.numericString))" }
            out.append(ObligationDraft(category: o.category, title: o.summary, detail: f.source?.quote.collapsingWhitespace() ?? "",
                                       amount: nil, dueDate: o.due?.resolved, dueDateExplanation: explanation, recurrence: o.recurrence,
                                       responsibleParty: o.responsibleParty, counterparty: counterparty, direction: .unknown,
                                       directionReason: nil, status: .pending, sourceFieldID: f.id, source: f.source))
        }
        return out
    }
}

/// Occurrence arithmetic for recurring obligations.
public enum RecurrenceEngine {
    /// The n-th occurrence (0 = first) of a schedule anchored on `start`. Monthly
    /// schedules keep the anchor day and clamp to short months (31 Jan → 28 Feb → 31 Mar).
    public static func occurrence(_ n: Int, start: CalendarDate, recurrence: Recurrence) -> CalendarDate {
        let k = n * recurrence.interval
        switch recurrence.frequency {
        case .weekly: return start.adding(days: 7 * k)
        case .monthly: return start.adding(months: k)
        case .quarterly: return start.adding(months: 3 * k)
        case .halfYearly: return start.adding(months: 6 * k)
        case .yearly: return start.adding(months: 12 * k)
        }
    }

    /// Occurrences on or after `from`, up to `limit`, stopping at the end date.
    public static func occurrences(start: CalendarDate, recurrence: Recurrence, from: CalendarDate, limit: Int) -> [CalendarDate] {
        var out: [CalendarDate] = []
        var n = 0
        while out.count < limit && n < 10_000 {
            let d = occurrence(n, start: start, recurrence: recurrence)
            if let end = recurrence.endDate, d > end { break }
            if d >= from { out.append(d) }
            n += 1
        }
        return out
    }

    /// The occurrence after `current`, or nil if the schedule has ended.
    public static func next(after current: CalendarDate, start: CalendarDate, recurrence: Recurrence) -> CalendarDate? {
        occurrences(start: start, recurrence: recurrence, from: current.adding(days: 1), limit: 1).first
    }
}

/// Money totals for the dashboard, from confirmed open payment obligations.
public enum MoneySummary {
    public struct Item: Sendable {
        public var amount: Money
        public var direction: FinancialDirection
        public var status: ObligationStatus
        public init(amount: Money, direction: FinancialDirection, status: ObligationStatus) {
            self.amount = amount
            self.direction = direction
            self.status = status
        }
    }

    public struct Totals: Equatable, Sendable {
        /// Per currency.
        public var owedToMe: [String: Int64] = [:]
        public var iOwe: [String: Int64] = [:]
        /// Open payments whose direction is not set.
        public var unassignedCount = 0
    }

    public static func totals(_ items: [Item]) -> Totals {
        var t = Totals()
        for item in items where item.status.isOpen {
            switch item.direction {
            case .owedToMe: t.owedToMe[item.amount.currency, default: 0] += item.amount.minorUnits
            case .iOwe: t.iOwe[item.amount.currency, default: 0] += item.amount.minorUnits
            case .unknown: t.unassignedCount += 1
            case .notMine: break
            }
        }
        return t
    }
}

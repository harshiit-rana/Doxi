import Foundation

/// On-device, rule-based extraction. Every field it produces carries the exact
/// text range it was read from. It is deliberately conservative: rules that
/// rely on keyword proximity are marked `weak` so they surface as medium
/// confidence and get reviewed.
public struct DeterministicExtractor: Sendable {
    public init() {}

    public func extract(_ document: DocumentText) -> [ExtractedFieldDraft] {
        var context = Context(document: document)
        return context.run()
    }
}

// MARK: - Implementation

private struct Context {
    let document: DocumentText
    let text: String
    let ns: NSString
    let sentences: [NSRange]
    let lines: [NSRange]
    let amounts: [AmountMention]
    let dates: [DateMention]
    let relatives: [RelativeDateMention]
    var out: [ExtractedFieldDraft] = []

    // Results reused across rules.
    var docType: DocumentType?
    var parties: [PartyValue] = []
    var effectiveDate: CalendarDate?
    var endDate: CalendarDate?
    var totalAmountRange: NSRange?

    init(document: DocumentText) {
        self.document = document
        self.text = document.fullText
        self.ns = text as NSString
        self.sentences = SentenceSplitter.ranges(in: text)
        self.lines = SentenceSplitter.lineRanges(in: text)
        self.amounts = AmountParser.mentions(in: text)
        let probe = DateParser.mentions(in: text)
        // Evidence of US ordering: some date is only valid as MM/DD and none only as DD/MM.
        let usEvidence = probe.contains { $0.monthFirst }
        let inEvidence = probe.contains { $0.dayFirstOnly }
        self.dates = DateParser.mentions(in: text, preferMonthFirst: usEvidence && !inEvidence)
        self.relatives = RelativeDateParser.mentions(in: text)
    }

    mutating func run() -> [ExtractedFieldDraft] {
        guard !text.trimmed().isEmpty else { return [] }
        extractDocumentType()
        extractTitle()
        extractParties()
        extractEffectiveDate()
        extractEndDate()
        extractNoticePeriod()
        extractRenewal()
        extractTotalAmount()
        extractPayments()
        extractObligations()
        extractClauses()
        extractIdentifiers()
        return out
    }

    // MARK: Helpers

    func sub(_ r: NSRange) -> String { ns.substring(with: r) }

    func sentence(containing location: Int) -> NSRange? {
        sentences.first { NSLocationInRange(location, $0) }
    }

    /// A readable quote around a value: the whole sentence if short, otherwise a window.
    func quoteRange(value: NSRange, within container: NSRange?) -> NSRange {
        guard let c = container else { return value }
        if c.length <= 280 { return c }
        var start = max(c.location, value.location - 120)
        var end = min(c.location + c.length, value.location + value.length + 120)
        while start > c.location, start < value.location, ns.character(at: start - 1) != 32 { start += 1 }
        while end < c.location + c.length, end > value.location + value.length, ns.character(at: end - 1) != 32 { end -= 1 }
        return NSRange(location: start, length: max(value.length, end - start))
    }

    mutating func add(_ kind: FieldKind, _ value: FieldValue, range: NSRange, strength: RuleStrength, notes: [String] = []) {
        let span = document.span(for: TextRange(range), match: .exact)
        out.append(ExtractedFieldDraft(kind: kind, value: value, origin: .deterministic, source: span,
                                       notes: notes, ruleStrength: strength))
    }

    func amounts(in r: NSRange) -> [AmountMention] { amounts.filter { NSIntersectionRange($0.range, r).length > 0 } }
    func dates(in r: NSRange) -> [DateMention] { dates.filter { NSIntersectionRange($0.range, r).length > 0 } }
    func relatives(in r: NSRange) -> [RelativeDateMention] { relatives.filter { NSIntersectionRange($0.range, r).length > 0 } }

    func matches(_ p: Pattern, in r: NSRange) -> [NSTextCheckingResult] { p.matches(in: text, range: r) }

    // MARK: Document type & title

    mutating func extractDocumentType() {
        guard let result = DocumentClassifier.classify(text) else { return }
        docType = result.type
        let lineRange = lines.first { NSLocationInRange(result.evidence.location, $0) } ?? result.evidence
        add(.documentType, .documentType(result.type), range: lineRange, strength: result.inTitle ? .strong : .weak)
    }

    mutating func extractTitle() {
        guard let firstPage = document.fullTextRange(ofPage: document.pages.first?.index ?? 0) else { return }
        let candidates = lines.filter { NSIntersectionRange($0, firstPage.nsRange).length > 0 }.prefix(8)
        let keyword = Pattern(#"agreement|contract|invoice|quotation|estimate|proposal|non[\s-]?disclosure|\bNDA\b|purchase\s+order|lease|letter|schedule|memorandum|deed"#)
        for r in candidates {
            let s = sub(r).trimmed()
            guard s.count >= 4, s.count <= 90, keyword.firstMatch(in: text, range: r) != nil,
                  !s.lowercased().hasPrefix("this ") else { continue }
            add(.title, .text(s.collapsingWhitespace()), range: r, strength: .strong)
            return
        }
    }

    // MARK: Parties

    static let partyTerminator = #"(?:,|\(|;|\n\n|\bhaving\b|\bresiding\b|\bwhose\b|\bwith\s+(?:its|registered)|\ba\s+(?:company|firm|partnership|proprietor|private|public|limited)|\bincorporated\b|\bregistered\b|\bhereinafter\b|\bs/o\b|\bd/o\b|\bson\s+of\b|\bdaughter\s+of\b|\baged\b)"#
    static let betweenPattern = Pattern(
        #"\b(?:by\s+and\s+)?between\s*:?\s+(?:(?:mr|ms|mrs|dr|shri|smt)\.?\s+)?(.{2,120}?)\s*"# + partyTerminator +
        #"[\s\S]{0,600}?\b(?:and|AND)\s*:?\s+(?-i:(?=(?:M/[Ss]\.?\s*|Mr\.?\s|Ms\.?\s|Mrs\.?\s|Dr\.?\s|Shri\s|Smt\.?\s)?[A-Z0-9]))(?:(?:mr|ms|mrs|dr|shri|smt)\.?\s+)?(.{2,120}?)\s*"# + partyTerminator)
    static let rolePattern = Pattern(#"(?:hereinafter|herein\s*after)\s+(?:jointly\s+)?(?:referred\s+to\s+as|called|known\s+as)\s+(?:the\s+)?["“'‘]?(?:the\s+)?([A-Za-z][A-Za-z ]{1,30}?)["”'’]?\s*(?:\)|,|;|\.|which|and)"#)
    static let labelPattern = Pattern(
        #"^[ \t]*(client|customer|service\s+provider|freelancer|consultant|vendor|contractor|landlord|lessor|licensor|tenant|lessee|licensee|disclosing\s+party|receiving\s+party|bill(?:ed)?\s+to|invoice\s+to|buyer|seller|supplier|party\s+a|party\s+b|first\s+party|second\s+party)(?:\s+name)?[ \t]*[:\-–][ \t]*(.{0,80})$"#,
        anchorsMatchLines: true)

    static func cleanPartyName(_ raw: String) -> String? {
        var s = raw.trimmed().collapsingWhitespace()
        let prefixes = Pattern(#"^(?:M/s\.?|Messrs\.?|Mr\.?|Ms\.?|Mrs\.?|Shri|Smt\.?|Dr\.?)\s*"#)
        if let m = prefixes.firstMatch(in: s) { s = (s as NSString).substring(from: m.range.length) }
        s = s.trimmingCharacters(in: CharacterSet(charactersIn: " \"'“”‘’,.:;-–()"))
        let letters = s.filter(\.isLetter).count
        guard letters >= 2, s.count <= 80 else { return nil }
        let lower = s.lowercased()
        let rejects = ["the parties", "the party", "both parties", "the client", "the company", "the service provider",
                       "the freelancer", "the consultant", "the vendor", "the contractor", "itself", "its successors"]
        if rejects.contains(where: { lower == $0 }) { return nil }
        if DateParser.mentions(in: s).first != nil && letters < 6 { return nil }
        return s
    }

    mutating func addParty(_ name: String, role: String?, range: NSRange, strength: RuleStrength) {
        guard let clean = Context.cleanPartyName(name) else { return }
        let key = TextNormalizer.normalize(clean)
        if let idx = parties.firstIndex(where: { TextNormalizer.normalize($0.name) == key }) {
            if parties[idx].role == nil, let role { parties[idx].role = role }
            return
        }
        let value = PartyValue(name: clean, role: role.map { $0.trimmed().capitalized })
        parties.append(value)
        add(.party, .party(value), range: range, strength: strength)
    }

    mutating func extractParties() {
        let head = NSRange(location: 0, length: min(ns.length, 5000))
        if let m = Context.betweenPattern.firstMatch(in: text, range: head),
           let r1 = m.groupRange(1), let r2 = m.groupRange(2) {
            let role1 = Context.rolePattern.firstMatch(in: text, range: NSRange(location: r1.location, length: min(ns.length - r1.location, max(0, r2.location - r1.location))))?.group(1, in: ns)
            let tailLength = min(ns.length - r2.location, 500)
            let role2 = Context.rolePattern.firstMatch(in: text, range: NSRange(location: r2.location, length: tailLength))?.group(1, in: ns)
            addParty(sub(r1), role: role1, range: r1, strength: .weak)
            addParty(sub(r2), role: role2, range: r2, strength: .weak)
        }
        for m in Context.labelPattern.matches(in: text) {
            guard let roleRange = m.groupRange(1) else { continue }
            let role = sub(roleRange).collapsingWhitespace()
            var nameRange = m.groupRange(2)
            if let r = nameRange, sub(r).trimmed().isEmpty { nameRange = nil }
            if nameRange == nil, let idx = lines.firstIndex(where: { NSLocationInRange(m.range.location, $0) }), idx + 1 < lines.count {
                nameRange = lines[idx + 1]
            }
            guard let nr = nameRange else { continue }
            let normalizedRole: String
            switch role.lowercased() {
            case let r where r.contains("bill") || r.contains("invoice to"): normalizedRole = "Client"
            default: normalizedRole = role
            }
            addParty(sub(nr), role: normalizedRole, range: nr, strength: .strong)
        }
    }

    // MARK: Dates

    static let effectiveKeywords: [(Pattern, Int, Bool)] = [
        // (pattern, priority (lower is better), label-like)
        (Pattern(#"(?:effective|start|commencement)\s+date\s*[:\-–]"#), 0, true),
        (Pattern(#"effective\s+(?:date|from|as\s+of|on)|with\s+effect\s+from|w\.?\s?e\.?\s?f\.?|commenc(?:e|es|ing|ement)|start(?:s|ing)?\s+(?:on|from)"#), 1, false),
        (Pattern(#"(?:made|entered\s+into|executed|signed)\s+(?:and\s+(?:entered\s+into|executed)\s+)?(?:on|at\s+[A-Za-z ]+\s+on|this)|\bdated\b|(?:agreement|contract)\s+date"#), 2, false),
        (Pattern(#"(?:invoice|quotation|quote|bill)\s+date\s*[:\-–]?"#), 3, true),
        (Pattern(#"^\s*date\s*[:\-–]"#, anchorsMatchLines: true), 4, true),
    ]

    mutating func extractEffectiveDate() {
        var best: (priority: Int, date: DateMention, container: NSRange, label: Bool)?
        for (pattern, priority, label) in Context.effectiveKeywords {
            for m in pattern.matches(in: text) {
                guard let container = label ? lines.first(where: { NSLocationInRange(m.range.location, $0) }) : sentence(containing: m.range.location) else { continue }
                // First date at or after the keyword in the same unit; for label lines also allow the next line.
                var candidates = dates(in: container).filter { $0.range.location >= m.range.location }
                if candidates.isEmpty && !label { candidates = dates(in: container) }
                if candidates.isEmpty && label, let idx = lines.firstIndex(of: container), idx + 1 < lines.count {
                    candidates = dates(in: lines[idx + 1])
                }
                guard let d = candidates.first else { continue }
                if best == nil || priority < best!.priority {
                    best = (priority, d, container, label)
                }
                break
            }
            if best != nil && best!.priority <= priority { break }
        }
        guard let b = best else { return }
        effectiveDate = b.date.date
        var notes: [String] = []
        if b.date.ambiguous { notes.append("The date \(b.date.text) could be read as DD/MM or MM/DD; read as \(b.date.date.longString).") }
        add(.effectiveDate, .date(DateValue(date: b.date.date, ambiguousFormat: b.date.ambiguous)),
            range: quoteRange(value: b.date.range, within: b.container), strength: (b.label || b.priority <= 1) ? .strong : .weak, notes: notes)
    }

    static let endKeywords = Pattern(#"(?:end|expiry|expiration|completion|termination)\s+date|expir(?:e|es|ing)\s+on|terminat(?:e|es)\s+on|valid\s+(?:till|until|up\s*to|upto)|\buntil\b|\btill\b|ending\s+on|\bthrough\b|\bto\b"#)
    static let termPattern = Pattern(#"(?:for\s+a\s+(?:period|term)\s+of|term\s+of\s+this\s+(?:agreement|contract)\s+(?:shall\s+be|is)|period\s+of)\s+"# + RelativeDateParser.quantity + #"(days?|weeks?|months?|years?)"#)

    mutating func extractEndDate() {
        for m in Context.endKeywords.matches(in: text) {
            let keyword = sub(m.range).lowercased()
            var isWeakWord = keyword == "to" || keyword == "through" || keyword == "until" || keyword == "till"
            if isWeakWord && keyword != "to" && m.range.location >= 24 {
                let before = sub(NSRange(location: m.range.location - 24, length: 24)).lowercased()
                if before.contains("force") || before.contains("valid") || before.contains("effect") || before.contains("continue") { isWeakWord = false }
            }
            guard let container = sentence(containing: m.range.location) ?? lines.first(where: { NSLocationInRange(m.range.location, $0) }) else { continue }
            let unit = sub(container).lowercased()
            // "to"/"until" only count in sentences about the agreement term.
            if isWeakWord && !(unit.contains("term") || unit.contains("period") || unit.contains("valid") || unit.contains("from") || unit.contains("agreement") || unit.contains("contract")) { continue }
            if unit.contains("invoice") && unit.contains("due") { continue }
            guard let d = dates(in: container).first(where: { $0.range.location > m.range.location }) else { continue }
            if let eff = effectiveDate, d.date <= eff { continue }
            endDate = d.date
            var notes: [String] = []
            if d.ambiguous { notes.append("The date \(d.text) could be read as DD/MM or MM/DD; read as \(d.date.longString).") }
            add(.endDate, .date(DateValue(date: d.date, ambiguousFormat: d.ambiguous)), range: quoteRange(value: d.range, within: container),
                strength: isWeakWord ? .weak : .strong, notes: notes)
            return
        }
        // Derived end date: "for a period of 12 months" from the effective date.
        if let m = Context.termPattern.firstMatch(in: text) {
            let qty = m.group(2, in: ns).flatMap { Int($0) } ?? NumberWords.parseInt(m.group(1, in: ns) ?? "")
            guard let value = qty, value > 0, let unitWord = m.group(3, in: ns) else { return }
            let spec = RelativeDateSpec(offset: Duration(value: value, unit: DurationParser.unit(unitWord)), after: true,
                                        anchor: .effectiveDate, anchorText: "the effective date", baseDate: effectiveDate)
            endDate = spec.derivedDate
            let container = sentence(containing: m.range.location)
            add(.endDate, .date(.relative(spec)), range: quoteRange(value: m.range, within: container), strength: .weak,
                notes: ["Derived from the contract term (\(spec.offset.formatted))."])
        }
    }

    // MARK: Notice & renewal

    static let noticeStrong: [Pattern] = [
        Pattern(RelativeDateParser.quantity + #"(?:business\s+|working\s+|calendar\s+|clear\s+)?(days?|weeks?|months?)'?\s+(?:prior\s+|advance\s+|previous\s+)?(?:written\s+)?(?:prior\s+)?notice"#),
        Pattern(#"notice\s+period\s*(?:of|shall\s+be|is|[:\-–])\s*"# + RelativeDateParser.quantity + #"(?:business\s+|working\s+|calendar\s+)?(days?|weeks?|months?)"#),
        Pattern(#"(?:written\s+)?notice\s+of\s+(?:at\s+least\s+|not\s+less\s+than\s+)?"# + RelativeDateParser.quantity + #"(?:business\s+|working\s+|calendar\s+)?(days?|weeks?|months?)"#),
    ]

    mutating func extractNoticePeriod() {
        var best: (range: NSRange, duration: Duration, container: NSRange?, termination: Bool)?
        for p in Context.noticeStrong {
            for m in p.matches(in: text) {
                let qty = m.group(2, in: ns).flatMap { Int($0) } ?? NumberWords.parseInt(m.group(1, in: ns) ?? "")
                guard let v = qty, v > 0, let unitWord = m.group(3, in: ns) else { continue }
                let container = sentence(containing: m.range.location)
                let aboutTermination = container.map { sub($0).lowercased() }.map { $0.contains("terminat") || $0.contains("renew") || $0.contains("notice period") } ?? false
                if best == nil || (aboutTermination && !best!.termination) {
                    best = (m.range, Duration(value: v, unit: DurationParser.unit(unitWord)), container, aboutTermination)
                }
            }
        }
        guard let b = best else { return }
        add(.noticePeriod, .duration(b.duration), range: quoteRange(value: b.range, within: b.container), strength: .strong)
    }

    static let renewalPattern = Pattern(#"renew|renewal|automatically\s+(?:be\s+)?extended|extended\s+automatically"#)
    static let autoYes = Pattern(#"automatic(?:ally)?\s+(?:be\s+)?(?:renew|extend)|auto[\s-]?renew|(?:renew|extend)(?:ed|s)?\s+automatically|shall\s+(?:stand\s+)?renew(?:ed)?\s+for|deemed\s+(?:to\s+(?:be|have\s+been)\s+)?renewed|renew\s+on\s+the\s+same\s+terms"#)
    static let autoNo = Pattern(#"may\s+be\s+renewed|renew(?:ed|al)?\s+(?:only\s+)?(?:by|upon|with|subject\s+to|on)\s+(?:the\s+)?(?:mutual|written|a\s+fresh|fresh|new)|not\s+(?:be\s+)?(?:automatically\s+)?renew|no\s+automatic|mutually\s+agreed|mutual\s+(?:written\s+)?(?:consent|agreement)"#)

    mutating func extractRenewal() {
        var candidates: [(range: NSRange, automatic: Bool?)] = []
        for s in sentences where Context.renewalPattern.firstMatch(in: text, range: s) != nil {
            let yes = Context.autoYes.firstMatch(in: text, range: s) != nil
            let no = Context.autoNo.firstMatch(in: text, range: s) != nil
            candidates.append((s, yes && !no ? true : (no ? false : nil)))
        }
        guard let best = candidates.first(where: { $0.automatic != nil }) ?? candidates.first else { return }
        let sentenceText = sub(best.range).collapsingWhitespace()
        let term = DurationParser.mentions(in: sub(best.range)).map(\.duration).first { $0.unit == .years || $0.unit == .months }
        let summary = sentenceText.count > 220 ? String(sentenceText.prefix(217)) + "…" : sentenceText
        add(.renewal, .renewal(RenewalValue(automatic: best.automatic, term: term, summary: summary)),
            range: quoteRange(value: best.range, within: best.range), strength: best.automatic == nil ? .weak : .strong)
    }

    // MARK: Money

    static let penaltyContext = Pattern(#"late\s+(?:fee|payment\s+(?:fee|charge))|penalt|interest\s+(?:@|at|of)|liquidated|deduct|fine\s+of|compensation\s+of|damages"#)
    static let totalStrong = Pattern(#"grand\s+total|total\s+(?:amount|payable|contract\s+value|project\s+(?:fee|cost|value)|fee|fees|consideration|price|cost|value|invoice\s+value)|contract\s+value|project\s+value|amount\s+payable|net\s+payable|balance\s+due|amount\s+due|total\s+due|^\s*total\s*[:\-–]?"#, anchorsMatchLines: true)
    static let totalWeak = Pattern(#"\bfees?\b|consideration|remuneration|compensation|\bvalue\s+of\s+(?:this|the)\b|\bcost\b"#)
    static let subtotal = Pattern(#"sub[\s-]?total|taxable\s+value|\b[cis]gst\b|\btax\b"#)

    mutating func extractTotalAmount() {
        var best: (score: Int, mention: AmountMention, container: NSRange)?
        for mention in amounts {
            guard let container = lines.first(where: { NSLocationInRange(mention.range.location, $0) }).flatMap({ line -> NSRange? in
                // Use the line for tabular documents, otherwise the sentence.
                line.length < 90 ? line : sentence(containing: mention.range.location)
            }) else { continue }
            if Context.penaltyContext.firstMatch(in: text, range: container) != nil { continue }
            if Context.subtotal.firstMatch(in: text, range: container) != nil && Context.totalStrong.matches(in: text, range: container).allSatisfy({ sub($0.range).lowercased().contains("sub") }) { continue }
            var score = 0
            if let k = Context.totalStrong.matches(in: text, range: container).first(where: { !sub($0.range).lowercased().contains("sub") }), k.range.location <= mention.range.location + mention.range.length {
                score = 3
                let kw = sub(k.range).lowercased()
                if kw.contains("grand") || kw.contains("amount due") || kw.contains("balance due") || kw.contains("total amount") || kw.contains("contract value") { score = 4 }
                // The amount directly following a "total" keyword is the total, not an instalment.
                if mention.range.location - (k.range.location + k.range.length) > 80 { score -= 1 }
            } else if Context.totalWeak.firstMatch(in: text, range: container) != nil {
                score = 1
            }
            guard score > 0 else { continue }
            if let b = best {
                if score > b.score || (score == b.score && mention.money.minorUnits > b.mention.money.minorUnits) {
                    best = (score, mention, container)
                }
            } else {
                best = (score, mention, container)
            }
        }
        guard let b = best else { return }
        totalAmountRange = b.mention.range
        add(.totalAmount, .money(b.mention.money), range: quoteRange(value: b.mention.range, within: b.container),
            strength: b.score >= 3 ? .strong : .weak)
    }

    static let paymentContext = Pattern(#"\bpa(?:y|id|yable|yment)|instal+ment|advance|milestone|\bdue\b|balance|remaining|tranche|\brent\b|deposit|retainer|on\s+signing|upon\s+(?:signing|completion|delivery)"#)
    static let dueLabel = Pattern(#"(?:payment\s+)?due\s+(?:date|on|by)|pay(?:able)?\s+(?:by|on\s+or\s+before|before)|due\s*[:\-–]"#)
    static let monthlyPattern = Pattern(#"per\s+(?:calendar\s+)?month|\bmonthly\b|every\s+(?:calendar\s+)?month|each\s+(?:calendar\s+)?month|\bp\.\s?m\.|\bpm\b|a\s+month\b"#)
    static let yearlyPattern = Pattern(#"per\s+(?:annum|year)|\bannual(?:ly)?\b|\byearly\b|every\s+year|\bp\.\s?a\.|each\s+year"#)
    static let quarterlyPattern = Pattern(#"\bquarterly\b|per\s+quarter|every\s+quarter|each\s+quarter"#)
    static let weeklyPattern = Pattern(#"\bweekly\b|per\s+week|every\s+week"#)
    static let dayOfMonth = Pattern(#"(\d{1,2})(?:st|nd|rd|th)?\s+(?:day\s+)?of\s+(?:each|every|the)\s+(?:calendar\s+|english\s+)?month"#)
    static let ordinalLabel = Pattern(#"\b(first|1st|second|2nd|third|3rd|fourth|4th|fifth|5th|final|last)\s+(?:instal+ment|tranche|milestone|payment|part)|(?:instal+ment|tranche|milestone)\s*(?:no\.?\s*|#\s*)?(\d)"#)

    func recurrence(in r: NSRange) -> RecurrenceFrequency? {
        if Context.monthlyPattern.firstMatch(in: text, range: r) != nil { return .monthly }
        if Context.quarterlyPattern.firstMatch(in: text, range: r) != nil { return .quarterly }
        if Context.yearlyPattern.firstMatch(in: text, range: r) != nil { return .yearly }
        if Context.weeklyPattern.firstMatch(in: text, range: r) != nil { return .weekly }
        return nil
    }

    func paymentLabel(in r: NSRange, recurring: Bool) -> String {
        let s = sub(r).lowercased()
        if let m = Context.ordinalLabel.firstMatch(in: text, range: r) {
            let word = (m.group(1, in: ns) ?? m.group(2, in: ns) ?? "").lowercased()
            let map = ["first": "1", "1st": "1", "second": "2", "2nd": "2", "third": "3", "3rd": "3", "fourth": "4", "4th": "4", "fifth": "5", "5th": "5"]
            if word == "final" || word == "last" { return "Final payment" }
            if let n = map[word] ?? (Int(word) != nil ? word : nil) { return "Installment \(n)" }
        }
        if s.contains("rent") { return recurring ? "Rent" : "Rent payment" }
        if s.contains("deposit") { return "Security deposit" }
        if s.contains("advance") || s.contains("on signing") || s.contains("upon signing") { return "Advance payment" }
        if s.contains("balance") || s.contains("remaining") || s.contains("final") { return "Final payment" }
        if s.contains("retainer") { return "Retainer" }
        return recurring ? "Recurring payment" : "Payment"
    }

    mutating func extractPayments() {
        var emitted: [(Money, CalendarDate?)] = []
        var frequencyEmitted = false
        let isInvoice = docType == .invoice || docType == .quotation

        for s in sentences {
            guard Context.paymentContext.firstMatch(in: text, range: s) != nil,
                  Context.penaltyContext.firstMatch(in: text, range: s) == nil else { continue }
            var mentions = amounts(in: s)
            // Drop amount-in-words that repeat a numeric amount in the same sentence.
            mentions = mentions.filter { m in !(m.fromWords && mentions.contains { !$0.fromWords && $0.money == m.money }) }
            // The total amount itself is not an instalment.
            if let t = totalAmountRange { mentions.removeAll { NSIntersectionRange($0.range, t).length > 0 } }
            // Nor are subtotals and tax lines.
            if Context.subtotal.firstMatch(in: text, range: s) != nil && s.length < 90 { continue }
            guard !mentions.isEmpty else { continue }

            let sentenceDates = dates(in: s)
            let sentenceRelatives = relatives(in: s)
            let freq = recurrence(in: s)
            // For a single "total ... payable in instalments" sentence without dates, skip.
            if sentenceDates.isEmpty && sentenceRelatives.isEmpty && freq == nil && !isDueWithoutDate(s) { continue }

            for (i, mention) in mentions.enumerated() {
                var due: DateValue?
                var notes: [String] = []
                if sentenceDates.count == mentions.count {
                    let d = sentenceDates[i]
                    due = DateValue(date: d.date, ambiguousFormat: d.ambiguous)
                } else if let d = nearest(sentenceDates, to: mention.range) {
                    due = DateValue(date: d.date, ambiguousFormat: d.ambiguous)
                } else if let rel = nearest(sentenceRelatives, to: mention.range) {
                    due = .relative(rel.spec)
                }
                var rec: Recurrence?
                if let freq {
                    rec = Recurrence(frequency: freq, endDate: endDate)
                    if due == nil {
                        if let dm = Context.dayOfMonth.firstMatch(in: text, range: s), let day = Int(dm.group(1, in: ns) ?? ""), (1...31).contains(day) {
                            if let start = effectiveDate {
                                due = DateValue(date: Context.firstOccurrence(day: day, onOrAfter: start))
                                notes.append("Due on day \(day) of each month, starting from the effective date \(start.numericString).")
                            } else {
                                notes.append("Due on day \(day) of each month; the start date could not be determined.")
                            }
                        } else if let start = effectiveDate {
                            due = DateValue(date: start)
                            notes.append("First occurrence assumed to be the effective date \(start.numericString).")
                        }
                    }
                }
                if due == nil && isInvoice, let dueDate = invoiceDueDate() {
                    due = DateValue(date: dueDate)
                }
                let key = (mention.money, due?.resolved)
                if emitted.contains(where: { $0.0 == key.0 && $0.1 == key.1 }) { continue }
                emitted.append(key)
                let value = PaymentValue(amount: mention.money, due: due, label: paymentLabel(in: s, recurring: rec != nil), recurrence: rec)
                add(.payment, .payment(value), range: quoteRange(value: mention.range, within: s),
                    strength: due != nil ? .strong : .weak, notes: notes)
                if let freq, !frequencyEmitted {
                    frequencyEmitted = true
                    add(.paymentFrequency, .frequency(freq), range: quoteRange(value: mention.range, within: s), strength: .strong)
                }
            }
        }

        // Invoices: the total is payable on the due date.
        if isInvoice, emitted.isEmpty, let t = totalAmountRange, let total = amounts.first(where: { $0.range == t }) {
            let dueDate = invoiceDueDate()
            let rel = invoiceRelativeDue()
            let due: DateValue? = dueDate.map { DateValue(date: $0) } ?? rel.map { .relative($0) }
            let label = docType == .quotation ? "Quoted amount" : "Invoice payment"
            let value = PaymentValue(amount: total.money, due: due, label: label)
            let container = sentence(containing: t.location)
            add(.payment, .payment(value), range: quoteRange(value: t, within: container), strength: due != nil ? .strong : .weak,
                notes: due == nil ? ["No due date was found on the invoice."] : [])
        }
    }

    func isDueWithoutDate(_ s: NSRange) -> Bool {
        let str = sub(s).lowercased()
        return str.contains("on signing") || str.contains("upon signing") || str.contains("advance")
    }

    func invoiceDueDate() -> CalendarDate? {
        for m in Context.dueLabel.matches(in: text) {
            guard let line = lines.first(where: { NSLocationInRange(m.range.location, $0) }) else { continue }
            if let d = dates(in: line).first(where: { $0.range.location >= m.range.location }) { return d.date }
            if let idx = lines.firstIndex(of: line), idx + 1 < lines.count, let d = dates(in: lines[idx + 1]).first { return d.date }
        }
        return nil
    }

    func invoiceRelativeDue() -> RelativeDateSpec? {
        relatives.first { $0.spec.anchor == .invoiceDate }.map { rel in
            var spec = rel.spec
            spec.baseDate = effectiveDate
            return spec
        }
    }

    func nearest(_ items: [DateMention], to r: NSRange) -> DateMention? {
        items.min { abs($0.range.location - r.location) < abs($1.range.location - r.location) }
    }

    func nearest(_ items: [RelativeDateMention], to r: NSRange) -> RelativeDateMention? {
        items.min { abs($0.range.location - r.location) < abs($1.range.location - r.location) }
    }

    static func firstOccurrence(day: Int, onOrAfter start: CalendarDate) -> CalendarDate {
        let clamped = min(day, CalendarDate.daysInMonth(year: start.year, month: start.month))
        let candidate = CalendarDate(unchecked: start.year, start.month, clamped)
        if candidate >= start { return candidate }
        let next = start.adding(months: 1)
        return CalendarDate(unchecked: next.year, next.month, min(day, CalendarDate.daysInMonth(year: next.year, month: next.month)))
    }

    // MARK: Obligations (non-payment)

    static let dutyPattern = Pattern(#"^(.{2,60}?)\s+(?:shall|will|must|agrees?\s+to|is\s+required\s+to|undertakes?\s+to)\s+(?:be\s+required\s+to\s+)?(deliver|submit|provide|complete|hand\s+over|furnish|return|share|send|launch|finish)\b"#)

    mutating func extractObligations() {
        for s in sentences {
            guard let m = Context.dutyPattern.firstMatch(in: text, range: s), m.range.location == s.location else { continue }
            let d = dates(in: s).first
            let rel = relatives(in: s).first
            guard d != nil || rel != nil else { continue }
            if Context.paymentContext.firstMatch(in: text, range: s) != nil && !amounts(in: s).isEmpty { continue }
            let subject = (m.group(1, in: ns) ?? "").trimmed()
            let responsible = resolveParty(subject)
            var summary = sub(s).collapsingWhitespace()
            if summary.count > 160 { summary = String(summary.prefix(157)) + "…" }
            let due: DateValue? = d.map { DateValue(date: $0.date, ambiguousFormat: $0.ambiguous) } ?? rel.map { .relative($0.spec) }
            let verb = (m.group(2, in: ns) ?? "").lowercased()
            let category: ObligationCategory = verb.contains("deliver") || verb.contains("submit") || verb.contains("launch") ? .deliverable : .deadline
            add(.obligation, .obligation(ObligationValue(summary: summary, responsibleParty: responsible, due: due, recurrence: nil, category: category)),
                range: quoteRange(value: s, within: s), strength: .weak)
        }
    }

    /// Maps "The Service Provider" to the party whose role is "Service Provider".
    func resolveParty(_ subject: String) -> String? {
        let key = TextNormalizer.normalize(subject).replacingOccurrences(of: "the ", with: "")
        if let p = parties.first(where: { ($0.role.map(TextNormalizer.normalize) ?? "") == key }) { return p.name }
        if let p = parties.first(where: { TextNormalizer.normalize($0.name) == key }) { return p.name }
        return subject.isEmpty ? nil : subject
    }

    // MARK: Clauses

    static let clauseKeywords: [(ClauseCategory, Pattern)] = [
        (.payment, Pattern(#"payment\s+terms|\bpayments?\b|\bfees?\b|consideration|remuneration|compensation"#)),
        (.renewal, Pattern(#"renew"#)),
        (.termination, Pattern(#"terminat"#)),
        (.notice, Pattern(#"notice\s+period|days'?\s+(?:prior\s+)?(?:written\s+)?notice"#)),
        (.confidentiality, Pattern(#"confidential|non[\s-]?disclosure"#)),
        (.deliverables, Pattern(#"deliverables?|scope\s+of\s+(?:work|services)|services\s+to\s+be\s+provided"#)),
        (.penalties, Pattern(#"penalt|late\s+(?:fee|payment)|interest\s+(?:@|at\s+the\s+rate|of)|liquidated\s+damages"#)),
        (.deadlines, Pattern(#"deadline|timeline|no\s+later\s+than|on\s+or\s+before|time\s+is\s+of\s+the\s+essence"#)),
    ]
    static let headingPrefix = Pattern(#"^\s*(?:(?:\d+(?:\.\d+)*|[A-Z]|[IVX]+)[.)]\s*|article\s+\d+\s*[:.\-]?\s*|clause\s+\d+\s*[:.\-]?\s*|section\s+\d+\s*[:.\-]?\s*)?[A-Za-z &/,'-]{3,50}:?\s*$"#)

    mutating func extractClauses() {
        for (category, keyword) in Context.clauseKeywords {
            var found: (range: NSRange, heading: Bool)?
            // Prefer a heading line followed by its first sentence.
            for line in lines where line.length <= 60 {
                guard Context.headingPrefix.firstMatch(in: text, range: line) != nil,
                      keyword.firstMatch(in: text, range: line) != nil else { continue }
                if let idx = sentences.firstIndex(where: { $0.location > line.location + line.length - 1 }) {
                    let body = sentences[idx]
                    let end = body.location + min(body.length, 400)
                    found = (NSRange(location: line.location, length: end - line.location), true)
                } else {
                    found = (line, true)
                }
                break
            }
            if found == nil, let s = sentences.first(where: { keyword.firstMatch(in: text, range: $0) != nil && $0.length > 25 }) {
                found = (s, false)
            }
            guard let f = found else { continue }
            var summary = sub(f.range).collapsingWhitespace()
            if summary.count > 240 { summary = String(summary.prefix(237)) + "…" }
            let range = f.range.length > 400 ? NSRange(location: f.range.location, length: 400) : f.range
            add(.clause, .clause(ClauseValue(category: category, summary: summary)), range: range, strength: f.heading ? .strong : .weak)
        }
    }

    // MARK: Identifiers

    mutating func extractIdentifiers() {
        var seen = Set<String>()
        for m in IdentifierDetector.mentions(in: text) where seen.insert(m.value.value).inserted {
            add(.identifier, .identifier(m.value), range: m.range, strength: .strong)
        }
    }
}

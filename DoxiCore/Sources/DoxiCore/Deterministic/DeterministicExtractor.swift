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
    /// Whether the total came from an explicit "total" label (then it is not also a payment).
    var totalIsExplicit = false

    init(document: DocumentText) {
        self.document = document
        // Values are parsed from OCR-repaired text; quotes still come from the original pages.
        self.text = OCRDigits.normalize(document.fullText)
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

    mutating func add(_ kind: FieldKind, _ value: FieldValue, range: NSRange, strength: RuleStrength, notes: [String] = [],
                      extra: [NSRange] = []) {
        let span = document.span(for: TextRange(range), match: .exact)
        // Supporting text outside the main quote (e.g. a due date on another line).
        let extras = extra.filter { NSIntersectionRange($0, range).length < $0.length }
            .compactMap { document.span(for: TextRange($0), match: .exact) }
        out.append(ExtractedFieldDraft(kind: kind, value: value, origin: .deterministic, source: span,
                                       notes: notes, ruleStrength: strength, additionalSources: extras.isEmpty ? nil : extras))
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
        #"\b(?:by\s+and\s+)?be?twe*n\s*:?\s+(?:(?:mr|ms|mrs|dr|shri|smt)\.?\s+)?(.{2,120}?)\s*"# + partyTerminator +
        #"[\s\S]{0,600}?\b(?:and|AND)\s*:?\s+(?-i:(?=(?:M/[Ss]\.?\s*|Mr\.?\s|Ms\.?\s|Mrs\.?\s|Dr\.?\s|Shri\s|Smt\.?\s)?[A-Z0-9]))(?:(?:mr|ms|mrs|dr|shri|smt)\.?\s+)?(.{2,120}?)\s*"# + partyTerminator)
    static let rolePattern = Pattern(#"(?:hereinafter|herein\s*after)\s+(?:jointly\s+)?(?:referred\s+to\s+as|called|known\s+as)\s+(?:the\s+)?["“'‘]?(?:the\s+)?([A-Za-z][A-Za-z ]{1,30}?)["”'’]?\s*(?:\)|,|;|\.|which|and)"#)
    static let labelPattern = Pattern(
        #"^[ \t]*(client|customer|service\s+provider|freelancer|consultant|developer|designer|agency|vendor|contractor|landlord|lessor|licensor|tenant|lessee|licensee|disclosing\s+party|receiving\s+party|bill(?:ed)?\s+to|invoice\s+to|buyer|seller|supplier|party\s+a|party\s+b|first\s+party|second\s+party)(?:\s+name)?[ \t]*[:\-–][ \t]*(.{0,80})$"#,
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

    static let amongIntro = Pattern(#"\b(?:by\s+and\s+)?(?:among(?:st)?|between)\s*:[ \t]*\n"#)
    static let numberedParty = Pattern(#"^[ \t]*(?:\d{1,2}[.)]|\(?[a-z]\))[ \t]*(.+?)[ \t]*(?:,|\(|;|$)"#, anchorsMatchLines: true)
    static let quotedRole = Pattern(#"\(\s*["“']?([A-Za-z][A-Za-z ]{1,30}?)["”']?\s*\)"#)
    static let fromToLabel = Pattern(#"^[ \t]*(from|to)[ \t]*[:\-–][ \t]*(.{0,80})$"#, anchorsMatchLines: true)
    static let letterheadReject = Pattern(#"invoice|quotation|estimate|\bdate\b|\bno\b|gstin|\bpan\b|phone|mobile|email|@|www\.|\d{3,}|bill|tax"#)

    mutating func extractParties() {
        let head = NSRange(location: 0, length: min(ns.length, 5000))
        // "by and among: 1. Horizon Events Pvt Ltd, Gurugram ("Organiser"); 2. …"
        if let intro = Context.amongIntro.firstMatch(in: text, range: head) {
            var cursor = intro.range.location + intro.range.length
            for line in lines where line.location >= cursor {
                guard let m = Context.numberedParty.firstMatch(in: text, range: line), let nr = m.groupRange(1) else { break }
                let role = Context.quotedRole.firstMatch(in: text, range: line)?.group(1, in: ns)
                addParty(sub(nr), role: role, range: nr, strength: .weak)
                cursor = line.location + line.length
            }
        }
        if docType == .invoice || docType == .quotation {
            var hasFrom = false
            for m in Context.fromToLabel.matches(in: text, range: head) {
                guard let r = m.groupRange(2), !sub(r).trimmed().isEmpty, let label = m.group(1, in: ns)?.lowercased() else { continue }
                // "From: Rana Digital Studio, New Delhi" — keep the name before the first comma.
                var nameRange = r
                let comma = (sub(r) as NSString).range(of: ",")
                if comma.location != NSNotFound { nameRange = NSRange(location: r.location, length: comma.location) }
                if label == "from" { hasFrom = true }
                addParty(sub(nameRange), role: label == "from" ? "Vendor" : "Client", range: nameRange, strength: .strong)
            }
            // Letterhead: the issuer's name is usually the first plain line after the title.
            if !hasFrom {
                for r in lines.prefix(4) {
                    let s = sub(r).trimmed()
                    guard s.count >= 3, s.count <= 60, Context.letterheadReject.firstMatch(in: text, range: r) == nil,
                          s.filter(\.isLetter).count >= 3 else { continue }
                    addParty(s, role: "Vendor", range: r, strength: .weak)
                    break
                }
            }
        }
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
            guard var nr = nameRange else { continue }
            // "Client: Sunrise Dental Clinic, Jaipur" — the name ends at the first comma.
            let comma = (sub(nr) as NSString).range(of: ",")
            if comma.location != NSNotFound && comma.location >= 3 { nr = NSRange(location: nr.location, length: comma.location) }
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
        (Pattern(#"^[ \t]*date[ \t]*[:\-–]|(?<![a-z] )\bdate[ \t]*:"#, anchorsMatchLines: true), 4, true),
    ]

    static let periodRange = Pattern(#"(?:from|commencing(?:\s+on)?|beginning(?:\s+on)?|starting(?:\s+on)?|w\.?e\.?f\.?|period\s+of|term\s+of)\s+(\S[^\n]{4,28}?)\s+(?:to|till|until|up\s*to|through)\s+(\S[^\n]{4,28}?)(?=[\s.,;)]|$)"#)

    /// "from 01/09/2026 to 28/02/2027": start and end of a period, when both parse as dates.
    func periodDates() -> (start: DateMention, end: DateMention, container: NSRange)? {
        for m in Context.periodRange.matches(in: text) {
            guard let r1 = m.groupRange(1), let r2 = m.groupRange(2),
                  let d1 = dates.first(where: { $0.range.location == r1.location }),
                  let d2 = dates.first(where: { $0.range.location == r2.location }), d1.date < d2.date else { continue }
            return (d1, d2, sentence(containing: m.range.location) ?? m.range)
        }
        return nil
    }

    mutating func extractEffectiveDate() {
        var best: (priority: Int, date: DateMention, container: NSRange, label: Bool)?
        if let p = periodDates() {
            best = (1, p.start, p.container, false)
        }
        // For invoices, quotations and letters the document's own date label comes first;
        // "dated" there usually refers to another document.
        let keywords = (docType?.isAgreement ?? true) ? Context.effectiveKeywords
            : Context.effectiveKeywords.map { k in (k.0, k.2 ? k.1 - 4 : k.1, k.2) }.sorted { $0.1 < $1.1 }
        for (pattern, priority, label) in keywords {
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

    static let endKeywords = Pattern(#"(?:end|expiry|expiration|completion|termination)\s+date|expir(?:e|es|ing)\s+on|terminat(?:e|es)\s+on|ends?\s+on|valid\s+(?:till|until|up\s*to|upto)|\buntil\b|\btill\b|ending\s+on|\bthrough\b|\bto\b"#)
    static let termPattern = Pattern(#"(?:for\s+a\s+(?:period|term)\s+of|term\s+of\s+this\s+(?:agreement|contract)\s+(?:shall\s+be|is)|period\s+of)\s+"# + RelativeDateParser.quantity + #"(days?|weeks?|months?|years?)"#)

    mutating func extractEndDate() {
        if let p = periodDates(), effectiveDate == p.start.date {
            endDate = p.end.date
            add(.endDate, .date(DateValue(date: p.end.date, ambiguousFormat: p.end.ambiguous)),
                range: quoteRange(value: p.end.range, within: p.container), strength: .strong)
            return
        }
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
            // Weak connecting words only count when the date follows immediately ("to 31/12/2026").
            if isWeakWord && d.range.location - (m.range.location + m.range.length) > 4 { continue }
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
                                        anchor: .effectiveDate, anchorText: "the effective date", baseDate: effectiveDate, isTermLength: true)
            endDate = spec.derivedDate
            let container = sentence(containing: m.range.location)
            add(.endDate, .date(.relative(spec)), range: quoteRange(value: m.range, within: container), strength: .weak,
                notes: ["Derived from the contract term (\(spec.offset.formatted))."])
        }
    }

    // MARK: Notice & renewal

    static let noticeStrong: [Pattern] = [
        Pattern(RelativeDateParser.quantity + #"(?:business\s+|working\s+|calendar\s+|clear\s+)?(days?|weeks?|months?)(?:'s|’s|'|’)?\s+(?:prior\s+|advance\s+|previous\s+)?(?:written\s+)?(?:prior\s+)?notice"#),
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
    static let totalStrong = Pattern(#"grand\s+total|total\s+(?:amount|payable|contract\s+value|project\s+(?:fee|cost|value)|fee|fees|consideration|price|cost|value|invoice\s+value)|contract\s+value|project\s+value|amount\s+payable|net\s+payable|balance\s+due|amount\s+due|total\s+due|^[ \t]*total[ \t]*[:\-–]?"#, anchorsMatchLines: true)
    static let totalWeak = Pattern(#"\bfees?\b|consideration|remuneration|compensation|\bvalue\s+of\s+(?:this|the)\b|\bcost\b"#)
    static let subtotal = Pattern(#"sub[\s-]?total|taxable\s+value|\b[cis]gst\b|\btax\b"#)

    /// Amounts in total lines of tables often have no currency marker ("Grand Total   1,25,000").
    func tableTotalMentions() -> [AmountMention] {
        var out: [AmountMention] = []
        let number = Pattern(#"(?<![\d.,])\d{1,3}(?:,\d{2,3})+(?:\.\d{1,2})?(?![\d,])|(?<![\d.,])\d{4,9}(?:\.\d{1,2})?(?![\d,])"#)
        for line in lines where line.length < 140 {
            guard Context.totalStrong.firstMatch(in: text, range: line) != nil, amounts(in: line).isEmpty,
                  Context.subtotal.firstMatch(in: text, range: line) == nil,
                  let m = number.matches(in: text, range: line).last,
                  let money = AmountParser.makeMoney(number: sub(m.range), multiplier: nil, currency: "INR") else { continue }
            out.append(AmountMention(range: m.range, money: money, text: sub(m.range), fromWords: false))
        }
        return out
    }

    mutating func extractTotalAmount() {
        var best: (score: Int, mention: AmountMention, container: NSRange)?
        for mention in amounts + tableTotalMentions() {
            guard let container = lines.first(where: { NSLocationInRange(mention.range.location, $0) }).flatMap({ line -> NSRange? in
                // Use the line for tabular documents, otherwise the sentence.
                line.length < 90 ? line : sentence(containing: mention.range.location)
            }) else { continue }
            if Context.penaltyContext.firstMatch(in: text, range: container) != nil
                || Context.exampleContext.firstMatch(in: text, range: container) != nil
                || Context.pastPayment.firstMatch(in: text, range: container) != nil { continue }
            if Context.subtotal.firstMatch(in: text, range: container) != nil && Context.totalStrong.matches(in: text, range: container).allSatisfy({ sub($0.range).lowercased().contains("sub") }) { continue }
            var score = 0
            if let k = Context.totalStrong.matches(in: text, range: container).first(where: { !sub($0.range).lowercased().contains("sub") }), k.range.location <= mention.range.location + mention.range.length {
                score = 3
                let kw = sub(k.range).lowercased()
                if kw.contains("grand") || kw.contains("amount due") || kw.contains("balance due") || kw.contains("total amount") || kw.contains("contract value") { score = 4 }
                // The amount directly following a "total" keyword is the total, not an instalment.
                if mention.range.location - (k.range.location + k.range.length) > 80 { score -= 1 }
            } else if Context.totalWeak.firstMatch(in: text, range: container) != nil && recurrence(in: container) == nil {
                // A recurring fee ("monthly licence fee") is not a contract total.
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
        totalIsExplicit = b.score >= 3
        add(.totalAmount, .money(b.mention.money), range: quoteRange(value: b.mention.range, within: b.container),
            strength: b.score >= 3 ? .strong : .weak)
    }

    /// Payments that already happened are history, not obligations.
    static let pastPayment = Pattern(#"\b(?:has|have|had|was|were)\s+(?:already\s+)?(?:been\s+)?(?:paid|received|deposited|remitted)|already\s+(?:been\s+)?paid|received\s+(?:with\s+thanks|a\s+sum|an\s+amount|the\s+sum|payment)|receipt\s+of\s+(?:rs|inr|₹)|paid\s+in\s+full"#)
    /// Illustrations inside clauses ("for example, an invoice of ₹80,000").
    static let exampleContext = Pattern(#"\bfor\s+(?:example|instance)\b|\be\.\s?g\.|\bby\s+way\s+of\s+(?:example|illustration)|\billustrat"#)

    static let paymentContext = Pattern(#"\bpa(?:y|id|yable|yment)|instal+ment|advance|milestone|\bdue\b|balance|remaining|tranche|\brent\b|deposit|retainer|on\s+signing|upon\s+(?:signing|completion|delivery)"#)
    static let dueLabel = Pattern(#"(?:payment\s+)?due\s+(?:date|on|by)|pa(?:y|yable|id)\s+(?:by|on\s+or\s+before|before)|(?:release|clear|settle)\s+(?:the\s+)?(?:payment|amount|dues)\s+(?:by|on\s+or\s+before|before)|on\s+or\s+before|due\s*[:\-–]"#)
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

    static let paymentHeading = Pattern(#"^[ \t]*(?:\d+[.)]\s*)?(?:payment(?:\s+terms|\s+schedule)?|fees?(?:\s+and\s+payment)?|milestones?)[ \t]*:?[ \t]*$"#, anchorsMatchLines: true)
    static let splitInto = Pattern(#"(?:in|by|across)\s+(?:two|three|four|five|six|\d{1,2})\s+(?:equal\s+)?(?:parts|instal+ments|tranches|payments|milestones)"#)
    static let withinEvent = Pattern(#"within\s+\d{1,3}\s+(?:business\s+|working\s+)?days?\s+(?:of|from|after)\s+[a-z]"#)

    /// Units that sit in a list under a "Payment:" heading.
    func underPaymentHeading(_ s: NSRange) -> Bool {
        guard let heading = Context.paymentHeading.matches(in: text).last(where: { $0.range.location < s.location }) else { return false }
        let between = NSRange(location: heading.range.location, length: s.location - heading.range.location)
        // Stop at a blank line or another heading-like line between them.
        return !sub(between).contains("\n\n") && between.length < 600
    }

    mutating func extractPayments() {
        var emitted: [(Money, CalendarDate?)] = []
        var frequencyEmitted = false
        let isInvoice = docType == .invoice || docType == .quotation

        for s in sentences {
            guard Context.paymentContext.firstMatch(in: text, range: s) != nil || underPaymentHeading(s),
                  Context.penaltyContext.firstMatch(in: text, range: s) == nil,
                  Context.pastPayment.firstMatch(in: text, range: s) == nil,
                  Context.exampleContext.firstMatch(in: text, range: s) == nil else { continue }
            var mentions = amounts(in: s)
            // Drop amount-in-words that repeat a numeric amount in the same sentence.
            mentions = mentions.filter { m in !(m.fromWords && mentions.contains { !$0.fromWords && $0.money == m.money }) }
            // "Rs. 1,20,000 in two parts: …" — the amount being split is not itself a payment.
            mentions.removeAll { m in
                let after = NSRange(location: m.range.location + m.range.length, length: min(40, s.location + s.length - m.range.location - m.range.length))
                return Context.splitInto.firstMatch(in: text, range: after).map { $0.range.location - after.location < 6 } ?? false
            }
            // The total amount itself is not an instalment.
            // (A fee named only in a payment sentence — "will pay Rs. 45,000 within 30 days of…" —
            // is both the value and the payment.)
            if let t = totalAmountRange, totalIsExplicit { mentions.removeAll { NSIntersectionRange($0.range, t).length > 0 } }
            // Nor are subtotals and tax lines.
            if Context.subtotal.firstMatch(in: text, range: s) != nil && s.length < 90 { continue }
            guard !mentions.isEmpty else { continue }

            var sentenceDates = dueCandidates(in: s)
            // "…remains outstanding. The amount was due on 25/09/2026."
            if sentenceDates.isEmpty, let idx = sentences.firstIndex(of: s), idx + 1 < sentences.count,
               Context.dueLabel.firstMatch(in: text, range: sentences[idx + 1]) != nil || sub(sentences[idx + 1]).lowercased().contains("due"),
               amounts(in: sentences[idx + 1]).isEmpty {
                sentenceDates = dueCandidates(in: sentences[idx + 1])
            }
            let sentenceRelatives = relatives(in: s)
            let freq = recurrence(in: s)
            // For a single "total ... payable in instalments" sentence without dates, skip.
            let eventDue = Context.dueEvent.firstMatch(in: text, range: s) ?? Context.withinEvent.firstMatch(in: text, range: s)
            if sentenceDates.isEmpty && sentenceRelatives.isEmpty && freq == nil && !isDueWithoutDate(s) && eventDue == nil { continue }

            // "three equal instalments of Rs 20,000 each payable on A, B and C"
            let lower = sub(s).lowercased()
            if mentions.count == 1, sentenceDates.count > 1, freq == nil, lower.contains("each") || lower.contains("equal") {
                let mention = mentions[0]
                for (n, d) in sentenceDates.enumerated() {
                    let value = PaymentValue(amount: mention.money, due: DateValue(date: d.date, ambiguousFormat: d.ambiguous), label: "Installment \(n + 1)")
                    emitted.append((mention.money, d.date))
                    add(.payment, .payment(value), range: quoteRange(value: d.range, within: s), strength: .strong)
                }
                continue
            }

            var previousEnd = s.location
            for (i, mention) in mentions.enumerated() {
                defer { previousEnd = mention.range.location + mention.range.length }
                var due: DateValue?
                var dueRange: NSRange?
                var notes: [String] = []
                if sentenceDates.count == mentions.count {
                    let d = sentenceDates[i]
                    due = DateValue(date: d.date, ambiguousFormat: d.ambiguous)
                    dueRange = lineOrSentence(d.range)
                } else if let d = nearest(sentenceDates, to: mention.range) {
                    due = DateValue(date: d.date, ambiguousFormat: d.ambiguous)
                    dueRange = lineOrSentence(d.range)
                } else if let rel = nearest(sentenceRelatives, to: mention.range) {
                    due = .relative(rel.spec)
                    dueRange = lineOrSentence(rel.range)
                }
                var rec: Recurrence?
                if let freq {
                    rec = Recurrence(frequency: freq, endDate: endDate)
                    if due == nil {
                        if let dm = Context.dayOfMonth.firstMatch(in: text, range: s), let day = Int(dm.group(1, in: ns) ?? ""), (1...31).contains(day) {
                            if let start = effectiveDate {
                                due = DateValue(date: Context.firstOccurrence(day: day, onOrAfter: start),
                                                computedFrom: "day \(day) of each month, first on or after the start date \(start.numericString)")
                                dueRange = dm.range
                            } else {
                                notes.append("Due on day \(day) of each month; the start date could not be determined.")
                            }
                        } else {
                            notes.append("The first due date is not stated; set it before confirming.")
                        }
                    }
                }
                if due == nil && isInvoice, let found = invoiceDueDate() {
                    due = DateValue(date: found.date)
                    dueRange = found.range
                }
                let label = localLabel(for: mention, previousEnd: previousEnd, in: s, recurring: rec != nil)
                if due == nil {
                    let window = NSRange(location: mention.range.location, length: min(s.location + s.length - mention.range.location, 60))
                    if let ev = Context.dueEvent.firstMatch(in: text, range: window) {
                        notes.append("Due \(sub(ev.range).trimmed()) (no calendar date).")
                    } else if let ev = Context.withinEvent.firstMatch(in: text, range: s) {
                        let phrase = sentence(containing: ev.range.location).map { sub(NSRange(location: ev.range.location, length: min(80, $0.location + $0.length - ev.range.location))) } ?? sub(ev.range)
                        notes.append("Due \(phrase.trimmed().trimmingCharacters(in: CharacterSet(charactersIn: "."))) (no calendar date).")
                    }
                }
                let key = (mention.money, due?.resolved)
                if due != nil, emitted.contains(where: { $0.0 == key.0 && $0.1 == key.1 }) { continue }
                emitted.append(key)
                let value = PaymentValue(amount: mention.money, due: due, label: label, recurrence: rec)
                let quote = quoteRange(value: mention.range, within: s)
                add(.payment, .payment(value), range: quote, strength: due != nil ? .strong : .weak, notes: notes,
                    extra: dueRange.map { [$0] } ?? [])
                if let freq, !frequencyEmitted {
                    frequencyEmitted = true
                    add(.paymentFrequency, .frequency(freq), range: quoteRange(value: mention.range, within: s), strength: .strong)
                }
            }
        }

        // Payment schedule tables: rows with a date and an amount under a header naming both.
        for (idx, header) in lines.enumerated() {
            let h = sub(header).lowercased()
            guard (h.contains("due") || h.contains("date")) && (h.contains("amount") || h.contains("rs") || h.contains("inr") || h.contains("₹") || h.contains("fee")),
                  dates(in: header).isEmpty else { continue }
            for row in lines[(idx + 1)...] {
                if row.location - (header.location + header.length) > 2000 { break }
                let rowText = sub(row).lowercased()
                if rowText.contains("total") || rowText.trimmed().isEmpty { break }
                let rowDates = dates(in: row)
                guard rowDates.count == 1, let d = rowDates.first else { continue }
                var money = amounts(in: row).first?.money
                var moneyRange = amounts(in: row).first?.range
                if money == nil, let bare = Pattern(#"(?<![\d.,/])\d{1,3}(?:,\d{2,3})+(?:\.\d{1,2})?(?![\d,/])"#).matches(in: text, range: row).last {
                    money = AmountParser.makeMoney(number: sub(bare.range), multiplier: nil, currency: "INR")
                    moneyRange = bare.range
                }
                guard let amount = money, let mr = moneyRange, !emitted.contains(where: { $0.0 == amount && $0.1 == d.date }) else { continue }
                if mr.location < d.range.location + d.range.length && NSIntersectionRange(mr, d.range).length > 0 { continue }
                emitted.append((amount, d.date))
                let label = sub(NSRange(location: row.location, length: max(0, min(d.range.location, mr.location) - row.location))).trimmed()
                add(.payment, .payment(PaymentValue(amount: amount, due: DateValue(date: d.date, ambiguousFormat: d.ambiguous),
                                                    label: label.isEmpty ? "Payment" : label.collapsingWhitespace())),
                    range: row, strength: .strong)
            }
        }

        // Invoices: the total is payable on the due date.
        if isInvoice, emitted.isEmpty, let t = totalAmountRange,
           let total = (amounts + tableTotalMentions()).first(where: { $0.range == t }) {
            let dueDate = invoiceDueDate()
            let rel = invoiceRelativeDue()
            let due: DateValue? = dueDate.map { DateValue(date: $0.date) } ?? rel.map { .relative($0.spec) }
            let dueRange = dueDate?.range ?? rel.map { lineOrSentence($0.range) }
            let label = docType == .quotation ? "Quoted amount" : "Invoice payment"
            let value = PaymentValue(amount: total.money, due: due, label: label)
            let container = sentence(containing: t.location)
            add(.payment, .payment(value), range: quoteRange(value: t, within: container), strength: due != nil ? .strong : .weak,
                notes: due == nil ? ["No due date was found on the invoice."] : [], extra: dueRange.map { [$0] } ?? [])
        }
    }

    static let referenceDate = Pattern(#"(?:dated|invoice\s+date|date\s+of\s+(?:the\s+)?invoice|issued\s+on)\s*[:\-]?\s*$"#)
    static let dueEvent = Pattern(#"\b(?:on|upon|after|before)\s+(confirmation|delivery|completion|signing|acceptance|approval|go[\s-]?live|launch|handover)(?:\s+of\s+(?:the\s+)?[a-z]+)?"#)

    /// Dates in a unit that can be due dates: not references to other documents' dates.
    func dueCandidates(in s: NSRange) -> [DateMention] {
        dates(in: s).filter { d in
            let start = max(s.location, d.range.location - 24)
            let before = NSRange(location: start, length: d.range.location - start)
            return Context.referenceDate.firstMatch(in: text, range: before) == nil
        }
    }

    /// Label from the words just before an amount ("…, balance Rs. 62,500").
    func localLabel(for mention: AmountMention, previousEnd: Int, in s: NSRange, recurring: Bool) -> String {
        let start = max(s.location, previousEnd)
        let end = min(s.location + s.length, mention.range.location + mention.range.length + 40)
        let window = NSRange(location: start, length: max(0, end - start))
        let local = paymentLabel(in: window, recurring: recurring)
        return local == "Payment" || local == "Recurring payment" ? paymentLabel(in: s, recurring: recurring) : local
    }

    func isDueWithoutDate(_ s: NSRange) -> Bool {
        let str = sub(s).lowercased()
        return str.contains("on signing") || str.contains("upon signing") || str.contains("advance")
    }

    /// The due date on an invoice and the line it is on.
    func invoiceDueDate() -> (date: CalendarDate, range: NSRange)? {
        for m in Context.dueLabel.matches(in: text) {
            guard let line = lines.first(where: { NSLocationInRange(m.range.location, $0) }) else { continue }
            if let d = dates(in: line).first(where: { $0.range.location >= m.range.location }) { return (d.date, line) }
            if let idx = lines.firstIndex(of: line), idx + 1 < lines.count, let d = dates(in: lines[idx + 1]).first {
                return (d.date, NSRange(location: line.location, length: lines[idx + 1].location + lines[idx + 1].length - line.location))
            }
        }
        return nil
    }

    func invoiceRelativeDue() -> (spec: RelativeDateSpec, range: NSRange)? {
        relatives.first { $0.spec.anchor == .invoiceDate }.map { rel in
            var spec = rel.spec
            spec.baseDate = effectiveDate
            return (spec, rel.range)
        }
    }

    /// The line (if short) or sentence containing a range, as a readable quote.
    func lineOrSentence(_ r: NSRange) -> NSRange {
        if let line = lines.first(where: { NSLocationInRange(r.location, $0) }), line.length <= 200 { return line }
        return sentence(containing: r.location).map { quoteRange(value: r, within: $0) } ?? r
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
            guard let m = Context.dutyPattern.firstMatch(in: text, range: s), m.range.location == s.location,
                  Context.exampleContext.firstMatch(in: text, range: s) == nil else { continue }
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

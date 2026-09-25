import Foundation

/// Locates model-reported quotes and values in the document text. This is what
/// turns "the model said so" into "here is where it is written".
public final class SourceMatcher: @unchecked Sendable {
    public let document: DocumentText
    let text: String
    let ns: NSString
    let normalized: NormalizedText
    let normalizedNS: NSString
    let tokens: [(token: String, range: NSRange)]
    /// Whether numeric dates in this document are MM/DD (same evidence rule as the extractor).
    public let preferMonthFirst: Bool
    lazy var sentenceRanges: [NSRange] = SentenceSplitter.ranges(in: text)

    public init(document: DocumentText) {
        self.document = document
        self.text = document.fullText
        self.ns = text as NSString
        self.normalized = NormalizedText(text)
        self.normalizedNS = normalized.text as NSString
        var toks: [(String, NSRange)] = []
        let p = Pattern(#"[\p{L}\p{N}]+"#)
        for m in p.matches(in: text) {
            toks.append((TextNormalizer.normalize(ns.substring(with: m.range)), m.range))
        }
        self.tokens = toks
        let probe = DateParser.mentions(in: text)
        self.preferMonthFirst = probe.contains { $0.monthFirst } && !probe.contains { $0.dayFirstOnly }
    }

    public struct Match: Equatable {
        public var range: NSRange
        public var quality: MatchQuality
        /// How many places in the document matched equally well. More than one means
        /// the chosen occurrence could not be told apart from others.
        public var equallyGoodOccurrences: Int = 1
    }

    /// Finds a quote in the document. When the quote occurs more than once, the
    /// occurrence is chosen by (1) whether it contains `value`, (2) whether it is on
    /// `page` (0-based), (3) how well its surroundings fit `kind`, then (4) position.
    public func locate(quote: String, page: Int? = nil, value: FieldValue? = nil, kind: FieldKind? = nil) -> Match? {
        let trimmed = quote.trimmed().trimmingCharacters(in: CharacterSet(charactersIn: "\"'“”…."))
        guard trimmed.count >= 3 else { return nil }

        // 1. Verbatim.
        let exact = allRanges(of: trimmed, in: ns)
        if !exact.isEmpty { return choose(exact, quality: .exact, page: page, value: value, kind: kind) }
        // 2. Normalised (case, whitespace, quotes, dashes).
        let nq = TextNormalizer.normalize(trimmed)
        if nq.count >= 3 {
            let normalizedHits = allRanges(of: nq, in: normalizedNS).map { normalized.originalRange(of: $0) }
            if !normalizedHits.isEmpty { return choose(normalizedHits, quality: .normalized, page: page, value: value, kind: kind) }
        }
        // 3. Token windows (OCR noise, dropped punctuation, small paraphrase).
        let windows = fuzzyWindows(quote: trimmed)
        guard let bestScore = windows.map(\.score).max() else { return nil }
        // Near-best windows compete on the same criteria as exact hits.
        let contenders = windows.filter { $0.score >= bestScore - 0.05 }.map(\.range)
        return choose(contenders, quality: .fuzzy, page: page, value: value, kind: kind)
    }

    func choose(_ ranges: [NSRange], quality: MatchQuality, page: Int?, value: FieldValue?, kind: FieldKind?) -> Match? {
        guard !ranges.isEmpty else { return nil }
        let pageRange = page.flatMap { document.fullTextRange(ofPage: $0) }
        typealias Scored = (range: NSRange, key: [Int])
        let scored: [Scored] = ranges.map { r in
            let verified = value.map { verify($0, in: r) == .verified } ?? false
            let onPage = pageRange.map { NSLocationInRange(r.location, $0.nsRange) } ?? false
            let context = kind.map { contextScore($0, around: r) } ?? 0
            return (r, [verified ? 1 : 0, onPage ? 1 : 0, context])
        }
        let best = scored.max { a, b in a.key.lexicographicallyPrecedes(b.key) || (a.key == b.key && a.range.location > b.range.location) }!
        let ties = scored.filter { $0.key == best.key }.count
        return Match(range: best.range, quality: quality, equallyGoodOccurrences: ties)
    }

    static let contextPatterns: [FieldKind: Pattern] = [
        .totalAmount: Pattern(#"total|grand|contract\s+value|project\s+(?:fee|value|cost)|consideration|amount\s+(?:due|payable)"#),
        .payment: Pattern(#"\bpa(?:y|id|yable|yment)|instal+ment|advance|\bdue\b|balance|\brent\b|milestone|deposit"#),
        .effectiveDate: Pattern(#"effective|commenc|start|\bdated\b|made\s+on|entered\s+into|invoice\s+date|^\s*date"#),
        .endDate: Pattern(#"\bend|expir|until|\btill\b|terminat|valid|\bto\b"#),
        .noticePeriod: Pattern(#"notice"#),
        .renewal: Pattern(#"renew|extend"#),
    ]
    static let misleadingContext = Pattern(#"penalt|late\s+fee|interest|for\s+example|e\.g\.|already\s+paid|has\s+paid|received"#)

    /// How well the text around a range fits a field kind (higher is better).
    func contextScore(_ kind: FieldKind, around r: NSRange) -> Int {
        // The sentence (or line) containing the match is the context; neighbouring
        // sentences often talk about other amounts.
        let window = sentenceRanges.first { NSLocationInRange(r.location, $0) } ?? expanded(r, by: 60)
        var score = 0
        if let p = SourceMatcher.contextPatterns[kind], p.firstMatch(in: text, range: window) != nil { score += 2 }
        if kind == .totalAmount || kind == .payment, SourceMatcher.misleadingContext.firstMatch(in: text, range: window) != nil { score -= 2 }
        return score
    }

    func allRanges(of needle: String, in haystack: NSString) -> [NSRange] {
        var out: [NSRange] = []
        var search = NSRange(location: 0, length: haystack.length)
        while true {
            let r = haystack.range(of: needle, options: [], range: search)
            if r.location == NSNotFound { break }
            out.append(r)
            let next = r.location + max(1, r.length)
            guard next < haystack.length else { break }
            search = NSRange(location: next, length: haystack.length - next)
        }
        return out
    }

    /// Candidate token windows scoring at least 0.75 (share of quote tokens found in order-free window).
    func fuzzyWindows(quote: String) -> [(score: Double, range: NSRange)] {
        var q = TextNormalizer.tokens(quote)
        guard q.count >= 3 else { return [] }
        if q.count > 40 { q = Array(q.prefix(40)) }
        let n = q.count
        let anchors = Set(q.prefix(4))
        var out: [(Double, NSRange)] = []
        var lastEnd = -1
        for i in tokens.indices where anchors.contains(tokens[i].token) || tokenClose(tokens[i].token, q[0]) {
            let windowEnd = min(tokens.count, i + n + 3)
            var used = [Bool](repeating: false, count: n)
            var hits = 0
            var lastHit = i
            for j in i..<windowEnd {
                let t = tokens[j].token
                if let k = (0..<n).first(where: { !used[$0] && (q[$0] == t || tokenClose(q[$0], t)) }) {
                    used[k] = true
                    hits += 1
                    lastHit = j
                }
            }
            let score = Double(hits) / Double(n)
            guard score >= 0.75 else { continue }
            // If the window began on a later quote word (earlier ones were misread), step back
            // over as many preceding tokens on the same line.
            var first = i
            if let lead = used.firstIndex(of: true), lead > 0 {
                var k = lead
                while k > 0, first > 0 {
                    let gap = NSRange(location: tokens[first - 1].range.location,
                                      length: tokens[first].range.location - tokens[first - 1].range.location)
                    if ns.substring(with: gap).contains("\n") { break }
                    first -= 1
                    k -= 1
                }
            }
            let start = tokens[first].range.location
            let endRange = tokens[lastHit].range
            let range = NSRange(location: start, length: endRange.location + endRange.length - start)
            // Overlapping windows describe the same place; keep the better one.
            if start < lastEnd, let last = out.last {
                if score > last.0 { out[out.count - 1] = (score, range); lastEnd = range.location + range.length }
                continue
            }
            out.append((score, range))
            lastEnd = range.location + range.length
        }
        return out
    }

    func tokenClose(_ a: String, _ b: String) -> Bool {
        if a == b { return true }
        let fa = SourceMatcher.ocrFold(a), fb = SourceMatcher.ocrFold(b)
        if fa == fb && fa.count >= 2 { return true }
        guard fa.count >= 5, fb.count >= 5, abs(fa.count - fb.count) <= 1 else { return false }
        return PartyMatcher.levenshtein(fa, fb) <= 1
    }

    /// Folds characters OCR commonly confuses ("rn"/"m", "l"/"1"/"i", "0"/"o", "5"/"s").
    static func ocrFold(_ s: String) -> String {
        var t = s.replacingOccurrences(of: "rn", with: "m").replacingOccurrences(of: "vv", with: "w")
        t = String(t.map { ch -> Character in
            switch ch {
            case "1", "i", "|", "!": return "l"
            case "0": return "o"
            case "5": return "s"
            default: return ch
            }
        })
        return t
    }


    // MARK: Value verification

    public enum Verification: Equatable {
        case verified
        case notFound
        case notApplicable
    }

    /// Checks that the value itself is written inside `range` of the full text.
    public func verify(_ value: FieldValue, in range: NSRange) -> Verification {
        let window = expanded(range, by: 40)
        let s = OCRDigits.normalize(ns.substring(with: window))
        switch value {
        case .money(let m):
            return containsAmount(m, in: s) ? .verified : .notFound
        case .date(let d):
            return containsDate(d, in: s) ? .verified : .notFound
        case .duration(let d):
            return DurationParser.mentions(in: s).contains { $0.duration.approximateDays == d.approximateDays } ? .verified : .notFound
        case .party(let p):
            return containsName(p.name, in: s) ? .verified : .notFound
        case .payment(let p):
            if let a = p.amount, !containsAmount(a, in: s) { return .notFound }
            if let d = p.due, (d.date != nil || d.relative != nil), !containsDate(d, in: s) { return .notFound }
            return p.amount == nil && p.due == nil ? .notApplicable : .verified
        case .obligation(let o):
            if let d = o.due, !containsDate(d, in: s) { return .notFound }
            return .verified
        case .identifier(let i):
            return s.contains(i.value) ? .verified : .notFound
        case .renewal(let r):
            if let term = r.term, !DurationParser.mentions(in: s).contains(where: { $0.duration.approximateDays == term.approximateDays }) { return .notFound }
            return TextNormalizer.normalize(s).contains("renew") || TextNormalizer.normalize(s).contains("extend") ? .verified : .notFound
        case .text, .documentType, .frequency, .clause:
            return .notApplicable
        }
    }

    /// Checks a value against several source ranges together: for a payment the
    /// amount may be on one line and its due date on another.
    public func verify(_ value: FieldValue, inAny ranges: [NSRange]) -> Verification {
        guard !ranges.isEmpty else { return .notFound }
        let results = ranges.map { verify(value, in: $0) }
        if results.contains(.verified) { return .verified }
        if results.allSatisfy({ $0 == .notApplicable }) { return .notApplicable }
        if case .payment(let p) = value {
            let amountOK = p.amount.map { a in ranges.contains { verify(.money(a), in: $0) == .verified } } ?? true
            let dateOK = p.due.map { d in ranges.contains { verify(.date(d), in: $0) == .verified } } ?? true
            return amountOK && dateOK ? .verified : .notFound
        }
        return .notFound
    }

    /// Full-text range of a source span.
    public func fullTextRange(of span: SourceSpan) -> NSRange? {
        document.fullTextRange(ofPage: span.pageIndex).map { NSRange(location: $0.location + span.range.location, length: span.range.length) }
    }

    func expanded(_ r: NSRange, by n: Int) -> NSRange {
        let start = max(0, r.location - n)
        let end = min(ns.length, r.location + r.length + n)
        return NSRange(location: start, length: end - start)
    }

    func containsAmount(_ m: Money, in s: String) -> Bool {
        AmountParser.mentions(in: s).contains { $0.money.minorUnits == m.minorUnits }
            || AmountParser.groupedNumbers(in: s).contains(m.minorUnits)
            || Pattern(#"(?<![\d.,])\#(m.minorUnits / 100)(?:\.0{1,2})?(?![\d,])"#).firstMatch(in: s) != nil && m.minorUnits % 100 == 0
    }

    func containsDate(_ d: DateValue, in s: String) -> Bool {
        // A calculated date is not written anywhere; its basis ("5th of each month") is
        // checked by the caller's quote, so only the written parts are verified here.
        if d.computedFrom != nil { return true }
        if let rel = d.relative, rel.isTermLength == true {
            return DurationParser.mentions(in: s).contains { $0.duration.approximateDays == rel.offset.approximateDays }
        }
        if let date = d.date {
            let found = DateParser.mentions(in: s, preferMonthFirst: preferMonthFirst)
            if found.contains(where: { $0.date == date }) { return true }
        }
        if let rel = d.relative {
            return RelativeDateParser.mentions(in: s).contains { $0.spec.offset.approximateDays == rel.offset.approximateDays && $0.spec.after == rel.after }
        }
        return false
    }

    func containsName(_ name: String, in s: String) -> Bool {
        let canonical = PartyMatcher.canonical(name)
        guard !canonical.isEmpty else { return false }
        if PartyMatcher.canonical(s).contains(canonical) { return true }
        let nameTokens = Set(PartyMatcher.tokens(name))
        let windowTokens = Set(PartyMatcher.tokens(s))
        return Double(nameTokens.intersection(windowTokens).count) / Double(max(1, nameTokens.count)) >= 0.8
    }

    // MARK: Locating values without a quote

    /// Finds the value itself in the text (used when a quote cannot be matched).
    /// Among several occurrences, the one whose surroundings fit `kind` wins.
    public func locateValue(_ value: FieldValue, page: Int?, kind: FieldKind? = nil) -> Match? {
        var candidates: [NSRange] = []
        switch value {
        case .money(let m):
            candidates = AmountParser.mentions(in: text).filter { $0.money.minorUnits == m.minorUnits }.map(\.range)
        case .date(let d):
            guard let date = d.date else { return nil }
            candidates = DateParser.mentions(in: text, preferMonthFirst: preferMonthFirst).filter { $0.date == date }.map(\.range)
        case .duration(let du):
            candidates = DurationParser.mentions(in: text).filter { $0.duration.approximateDays == du.approximateDays }.map(\.range)
        case .party(let p):
            candidates = allRanges(of: p.name, in: ns)
            if candidates.isEmpty {
                candidates = allRanges(of: TextNormalizer.normalize(p.name), in: normalizedNS).map { normalized.originalRange(of: $0) }
            }
        case .payment(let p):
            guard let a = p.amount else { return nil }
            let amounts = AmountParser.mentions(in: text).filter { $0.money.minorUnits == a.minorUnits }
            if let date = p.due?.date {
                let dates = DateParser.mentions(in: text, preferMonthFirst: preferMonthFirst).filter { $0.date == date }
                let paired = amounts.filter { c in dates.contains { abs($0.range.location - c.range.location) < 200 } }
                candidates = (paired.isEmpty ? amounts : paired).map(\.range)
            } else {
                candidates = amounts.map(\.range)
            }
        case .identifier(let i):
            candidates = allRanges(of: i.value, in: ns)
        default:
            return nil
        }
        return choose(candidates, quality: .valueOnly, page: page, value: nil, kind: kind)
    }

    /// The sentence around a range, for readable quotes.
    public func sentence(around range: NSRange) -> NSRange {
        let sentences = SentenceSplitter.ranges(in: text)
        guard let s = sentences.first(where: { NSLocationInRange(range.location, $0) }) else { return range }
        if s.length <= 280 { return s }
        return expanded(range, by: 100)
    }

    public func span(for range: NSRange, quality: MatchQuality) -> SourceSpan? {
        document.span(for: TextRange(range), match: quality)
    }
}

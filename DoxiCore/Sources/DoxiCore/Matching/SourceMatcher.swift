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
    }

    /// Finds a quote in the document, preferring occurrences on `page` (0-based).
    public func locate(quote: String, page: Int? = nil) -> Match? {
        let trimmed = quote.trimmed().trimmingCharacters(in: CharacterSet(charactersIn: "\"'“”…."))
        guard trimmed.count >= 3 else { return nil }

        // 1. Verbatim.
        if let r = best(of: allRanges(of: trimmed, in: ns), page: page) {
            return Match(range: r, quality: .exact)
        }
        // 2. Normalised (case, whitespace, quotes, dashes).
        let nq = TextNormalizer.normalize(trimmed)
        if nq.count >= 3, let r = best(of: allRanges(of: nq, in: normalizedNS).map { normalized.originalRange(of: $0) }, page: page) {
            return Match(range: r, quality: .normalized)
        }
        // 3. Token window (OCR noise, dropped punctuation, small paraphrase).
        return fuzzy(quote: trimmed, page: page)
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

    func best(of ranges: [NSRange], page: Int?) -> NSRange? {
        guard let page, let pageRange = document.fullTextRange(ofPage: page) else { return ranges.first }
        return ranges.first { NSLocationInRange($0.location, pageRange.nsRange) } ?? ranges.first
    }

    func fuzzy(quote: String, page: Int?) -> Match? {
        var q = TextNormalizer.tokens(quote)
        guard q.count >= 3 else { return nil }
        if q.count > 40 { q = Array(q.prefix(40)) }
        let n = q.count
        let anchors = Set(q.prefix(4))
        var best: (score: Double, start: Int, end: Int)?
        let pageRange = page.flatMap { document.fullTextRange(ofPage: $0) }

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
            var score = Double(hits) / Double(n)
            if let pr = pageRange, NSLocationInRange(tokens[i].range.location, pr.nsRange) { score += 0.01 }
            if best == nil || score > best!.score { best = (score, i, lastHit) }
        }
        guard let b = best, b.score >= 0.75 else { return nil }
        let start = tokens[b.start].range.location
        let endRange = tokens[b.end].range
        return Match(range: NSRange(location: start, length: endRange.location + endRange.length - start), quality: .fuzzy)
    }

    func tokenClose(_ a: String, _ b: String) -> Bool {
        guard a.count >= 5, b.count >= 5, abs(a.count - b.count) <= 1 else { return false }
        return PartyMatcher.levenshtein(a, b) <= 1
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
        let s = ns.substring(with: window)
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
    public func locateValue(_ value: FieldValue, page: Int?) -> NSRange? {
        switch value {
        case .money(let m):
            return AmountParser.mentions(in: text).first { $0.money.minorUnits == m.minorUnits }?.range
        case .date(let d):
            guard let date = d.date else { return nil }
            return DateParser.mentions(in: text, preferMonthFirst: preferMonthFirst).first { $0.date == date }?.range
        case .duration(let du):
            return DurationParser.mentions(in: text).first { $0.duration.approximateDays == du.approximateDays }?.range
        case .party(let p):
            let r = ns.range(of: p.name, options: [.caseInsensitive, .diacriticInsensitive])
            if r.location != NSNotFound { return r }
            let nr = normalizedNS.range(of: TextNormalizer.normalize(p.name))
            return nr.location != NSNotFound ? normalized.originalRange(of: nr) : nil
        case .payment(let p):
            guard let a = p.amount else { return nil }
            let candidates = AmountParser.mentions(in: text).filter { $0.money.minorUnits == a.minorUnits }
            if let date = p.due?.date {
                let dates = DateParser.mentions(in: text, preferMonthFirst: preferMonthFirst).filter { $0.date == date }
                if let pair = candidates.first(where: { c in dates.contains { abs($0.range.location - c.range.location) < 200 } }) { return pair.range }
            }
            return candidates.first?.range
        case .identifier(let i):
            let r = ns.range(of: i.value)
            return r.location == NSNotFound ? nil : r
        default:
            return nil
        }
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

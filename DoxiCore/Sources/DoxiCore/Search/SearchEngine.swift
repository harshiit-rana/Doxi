import Foundation

/// A document flattened for search.
public struct SearchableDocument: Sendable {
    public struct Field: Sendable {
        public var label: String
        public var value: String
        public var amount: Money?
        public var date: CalendarDate?
        public init(label: String, value: String, amount: Money? = nil, date: CalendarDate? = nil) {
            self.label = label; self.value = value; self.amount = amount; self.date = date
        }
    }

    public struct Obligation: Sendable {
        public var id: UUID
        public var title: String
        public var amount: Money?
        public var dueDate: CalendarDate?
        public var status: ObligationStatus
        public init(id: UUID, title: String, amount: Money?, dueDate: CalendarDate?, status: ObligationStatus) {
            self.id = id; self.title = title; self.amount = amount; self.dueDate = dueDate; self.status = status
        }
    }

    public var id: UUID
    public var filename: String
    public var title: String
    public var documentType: String
    public var parties: [String]
    public var fields: [Field]
    public var obligations: [Obligation]
    public var fullText: String
    public var tags: [String]
    /// Amounts written anywhere in the text (minor units), precomputed.
    public var textAmounts: Set<Int64>

    public init(id: UUID, filename: String, title: String, documentType: String, parties: [String], fields: [Field],
                obligations: [Obligation], fullText: String, tags: [String] = [], textAmounts: Set<Int64>? = nil) {
        self.id = id
        self.filename = filename
        self.title = title
        self.documentType = documentType
        self.parties = parties
        self.fields = fields
        self.obligations = obligations
        self.fullText = fullText
        self.tags = tags
        self.textAmounts = textAmounts ?? SearchableDocument.amounts(in: fullText)
    }

    public static func amounts(in text: String) -> Set<Int64> {
        Set(AmountParser.mentions(in: text).map(\.money.minorUnits) + AmountParser.groupedNumbers(in: text))
    }
}

public struct SearchResult: Sendable {
    public var documentID: UUID
    public var score: Double
    /// Extracted fields that matched ("Party: ABC Technologies").
    public var matchedFields: [String]
    public var matchedObligationIDs: [UUID]
    /// Text around the first match in the document body.
    public var snippet: String?
}

/// What a query means beyond plain words.
public struct SearchQuery: Sendable {
    public var raw: String
    public var tokens: [String]
    public var amount: Money?
    public var month: Int?
    public var date: CalendarDate?
    public var year: Int?

    public init(_ raw: String) {
        self.raw = raw
        let trimmed = raw.trimmed()
        tokens = TextNormalizer.tokens(trimmed)
        date = DateParser.mentions(in: trimmed).first?.date
        if date == nil, tokens.count <= 2, let m = tokens.compactMap({ t -> Int? in
            guard t.count >= 3, let n = DateParser.monthNumber(t) else { return nil }
            let full = CalendarDate.monthNames[n - 1].lowercased()
            return full.hasPrefix(t) || t == "sept" ? n : nil
        }).first {
            month = m
        }
        if let y = tokens.compactMap({ Int($0) }).first(where: { (1990...2100).contains($0) }), tokens.count <= 2 { year = y }
        // Amount queries: currency marker, grouping, multiplier, or a bare number that is not a year.
        let looksLikeAmount = trimmed.contains("₹") || trimmed.lowercased().hasPrefix("rs") || trimmed.lowercased().hasPrefix("inr")
            || trimmed.contains(",") || trimmed.lowercased().contains("lakh") || trimmed.lowercased().contains("crore")
            || trimmed.lowercased().hasSuffix("k") || (Int(trimmed).map { $0 >= 100 && !(1990...2100).contains($0) } ?? false)
        if looksLikeAmount, date == nil { amount = AmountParser.parseLoose(trimmed) }
    }
}

public enum SearchEngine {
    public static func search(_ raw: String, in documents: [SearchableDocument]) -> [SearchResult] {
        let q = SearchQuery(raw)
        guard !q.tokens.isEmpty || q.amount != nil else { return [] }
        return documents.compactMap { score(q, $0) }.sorted { $0.score > $1.score }
    }

    static func score(_ q: SearchQuery, _ doc: SearchableDocument) -> SearchResult? {
        var score = 0.0
        var matchedFields: [String] = []
        var matchedObligations: [UUID] = []

        // Amount match.
        if let amount = q.amount {
            var hit = false
            for f in doc.fields where f.amount?.minorUnits == amount.minorUnits {
                matchedFields.append("\(f.label): \(f.value)")
                score += 6
                hit = true
            }
            for o in doc.obligations where o.amount?.minorUnits == amount.minorUnits {
                matchedObligations.append(o.id)
                score += 5
                hit = true
            }
            if doc.textAmounts.contains(amount.minorUnits) {
                score += 3
                hit = true
            }
            if hit {
                return SearchResult(documentID: doc.id, score: score, matchedFields: matchedFields, matchedObligationIDs: matchedObligations,
                                    snippet: snippet(for: amount, in: doc.fullText))
            }
            // Fall through to text matching (e.g. an invoice number that looks like an amount).
        }

        // Date / month match.
        if q.date != nil || q.month != nil {
            let matchesDate: (CalendarDate) -> Bool = { d in
                if let qd = q.date { return d == qd }
                if let m = q.month { return d.month == m && (q.year == nil || d.year == q.year) }
                return false
            }
            for f in doc.fields where f.date.map(matchesDate) == true {
                matchedFields.append("\(f.label): \(f.value)")
                score += 4
            }
            for o in doc.obligations where o.dueDate.map(matchesDate) == true {
                matchedObligations.append(o.id)
                score += 4
            }
        }

        // Text match: every token must appear somewhere.
        let title = TextNormalizer.normalize(doc.title + " " + doc.filename)
        let partiesText = TextNormalizer.normalize(doc.parties.joined(separator: " | "))
        let type = TextNormalizer.normalize(doc.documentType + " " + doc.tags.joined(separator: " "))
        let body = TextNormalizer.normalize(doc.fullText)
        let fieldTexts = doc.fields.map { ($0, TextNormalizer.normalize($0.label + " " + $0.value)) }
        let obligationTexts = doc.obligations.map { ($0, TextNormalizer.normalize($0.title + " " + $0.status.displayName)) }

        var allTokensFound = !q.tokens.isEmpty
        var textScore = 0.0
        for (i, token) in q.tokens.enumerated() {
            let isLast = i == q.tokens.count - 1
            func has(_ s: String) -> Bool { containsWord(s, token, prefix: isLast) }
            var found = false
            if has(title) { textScore += 5; found = true }
            if has(partiesText) { textScore += 4; found = true }
            if has(type) { textScore += 2; found = true }
            for (f, t) in fieldTexts where has(t) {
                textScore += 2
                found = true
                let label = "\(f.label): \(f.value)"
                if !matchedFields.contains(label) { matchedFields.append(label) }
            }
            for (o, t) in obligationTexts where has(t) {
                textScore += 2
                found = true
                if !matchedObligations.contains(o.id) { matchedObligations.append(o.id) }
            }
            if has(body) { textScore += 1; found = true }
            if !found { allTokensFound = false }
        }
        if allTokensFound {
            score += textScore
            // Whole phrase bonus.
            let phrase = TextNormalizer.normalize(q.raw)
            if q.tokens.count > 1 && (title.contains(phrase) || partiesText.contains(phrase)) { score += 5 }
        } else if score == 0 {
            return nil
        }
        guard score > 0 else { return nil }
        let snippetText = q.tokens.first.flatMap { snippet(forToken: $0, in: doc.fullText) }
            ?? q.month.flatMap { snippet(forToken: CalendarDate.monthNames[$0 - 1].lowercased(), in: doc.fullText) }
        return SearchResult(documentID: doc.id, score: score, matchedFields: matchedFields, matchedObligationIDs: matchedObligations, snippet: snippetText)
    }

    static func containsWord(_ haystack: String, _ token: String, prefix: Bool) -> Bool {
        var search = haystack.startIndex..<haystack.endIndex
        while let r = haystack.range(of: token, range: search) {
            let beforeOK = r.lowerBound == haystack.startIndex || !haystack[haystack.index(before: r.lowerBound)].isLetterOrDigit
            let afterOK = prefix || r.upperBound == haystack.endIndex || !haystack[r.upperBound].isLetterOrDigit
            if beforeOK && afterOK { return true }
            search = r.upperBound..<haystack.endIndex
        }
        return false
    }

    static func snippet(forToken token: String, in text: String) -> String? {
        let normalized = NormalizedText(text)
        let r = (normalized.text as NSString).range(of: token)
        guard r.location != NSNotFound else { return nil }
        return window(around: normalized.originalRange(of: r), in: text)
    }

    static func snippet(for amount: Money, in text: String) -> String? {
        guard let m = AmountParser.mentions(in: text).first(where: { $0.money.minorUnits == amount.minorUnits }) else { return nil }
        return window(around: m.range, in: text)
    }

    static func window(around r: NSRange, in text: String) -> String {
        let ns = text as NSString
        let start = max(0, r.location - 60)
        let end = min(ns.length, r.location + r.length + 60)
        var s = ns.substring(with: NSRange(location: start, length: end - start)).collapsingWhitespace()
        if start > 0 { s = "…" + s }
        if end < ns.length { s += "…" }
        return s
    }
}

extension Character {
    var isLetterOrDigit: Bool { isLetter || isNumber }
}

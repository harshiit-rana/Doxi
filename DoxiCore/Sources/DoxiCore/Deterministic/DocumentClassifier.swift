import Foundation

/// Keyword-based document type classification. Keywords in the first lines
/// (the title area) count more than keywords in the body.
public enum DocumentClassifier {
    struct Rule {
        let type: DocumentType
        let pattern: Pattern
        let weight: Double
    }

    static let rules: [Rule] = [
        Rule(type: .nda, pattern: Pattern(#"non[\s-]?disclosure|confidentiality\s+agreement|\bNDA\b"#), weight: 4),
        Rule(type: .invoice, pattern: Pattern(#"tax\s+invoice|invoice\s+(?:no|number|#|date)\s*[:.#]|\bbill(?:ed)?\s+to\b|^[ \t]*invoice[ \t]*$"#, anchorsMatchLines: true), weight: 3),
        // A bare mention of "invoice" (e.g. a letter about an invoice) is weak evidence.
        Rule(type: .invoice, pattern: Pattern(#"\binvoice\b"#), weight: 0.5),
        Rule(type: .quotation, pattern: Pattern(#"\bquotation\b|\bquote\s+(?:no|number|#)|\bestimate\b|\bproposal\b"#), weight: 3),
        Rule(type: .freelanceAgreement, pattern: Pattern(#"\bfreelance(?:r)?\b|independent\s+contractor"#), weight: 3),
        Rule(type: .serviceAgreement, pattern: Pattern(#"services?\s+agreement|consult(?:ancy|ing)\s+agreement|master\s+services|statement\s+of\s+work"#), weight: 3),
        Rule(type: .vendorAgreement, pattern: Pattern(#"vendor\s+agreement|supply\s+agreement|supplier\s+agreement"#), weight: 3),
        Rule(type: .rentalAgreement, pattern: Pattern(#"rent(?:al)?\s+agreement|lease\s+(?:agreement|deed)|leave\s+and\s+licen[cs]e|\blandlord\b|\btenant\b|\blessee\b|\blessor\b|monthly\s+rent"#), weight: 3),
        Rule(type: .purchaseOrder, pattern: Pattern(#"purchase\s+order|\bP\.?O\.?\s+(?:no|number)"#), weight: 3),
        Rule(type: .paymentSchedule, pattern: Pattern(#"payment\s+schedule"#), weight: 1.5),
        Rule(type: .businessLetter, pattern: Pattern(#"dear\s+(?:sir|madam|mr|ms)|yours\s+(?:faithfully|sincerely|truly)|^[ \t]*subject[ \t]*:"#, anchorsMatchLines: true), weight: 2),
        Rule(type: .contract, pattern: Pattern(#"\bagreement\b|\bcontract\b"#), weight: 1),
    ]

    public struct Result {
        public let type: DocumentType
        public let evidence: NSRange
        public let inTitle: Bool
    }

    public static func classify(_ text: String) -> Result? {
        let ns = text as NSString
        let scanLength = min(ns.length, 6000)
        let lines = SentenceSplitter.lineRanges(in: text).prefix(6)
        let titleEnd = lines.last.map { $0.location + $0.length } ?? 0
        var scores: [DocumentType: (score: Double, rule: Rule, evidence: NSRange, inTitle: Bool)] = [:]
        for rule in rules {
            let matches = rule.pattern.matches(in: text, range: NSRange(location: 0, length: scanLength))
            guard let first = matches.first else { continue }
            var score = 0.0
            var titleHit: NSRange?
            for m in matches.prefix(10) {
                let inTitle = m.range.location < titleEnd
                score += rule.weight * (inTitle ? 3 : 1)
                if inTitle && titleHit == nil { titleHit = m.range }
            }
            if let existing = scores[rule.type] {
                scores[rule.type] = (existing.score + score, existing.rule, existing.evidence, existing.inTitle || titleHit != nil)
            } else {
                scores[rule.type] = (score, rule, titleHit ?? first.range, titleHit != nil)
            }
        }
        guard let b = scores.values.max(by: { $0.score < $1.score }) else { return nil }
        return Result(type: b.rule.type, evidence: b.evidence, inTitle: b.inTitle)
    }
}

import Foundation

public struct DateMention: Hashable, Sendable {
    public var range: NSRange
    public var date: CalendarDate
    public var text: String
    /// Numeric date whose day and month could be swapped (e.g. 05/10/2026).
    public var ambiguous: Bool
    /// Numeric date that could only be read as MM/DD (second number > 12).
    public var monthFirst: Bool
    /// Numeric date that could only be read as DD/MM (first number > 12).
    public var dayFirstOnly: Bool = false
    /// Components as written (for re-interpretation of ambiguous numeric dates).
    var numericParts: (Int, Int, Int)?

    public static func == (a: DateMention, b: DateMention) -> Bool { a.range == b.range && a.date == b.date }
    public func hash(into h: inout Hasher) { h.combine(range.location); h.combine(range.length); h.combine(date) }
}

/// Finds calendar dates. Numeric dates default to the Indian DD/MM/YYYY order.
public enum DateParser {
    static let month = #"(jan(?:uary)?|feb(?:ruary)?|mar(?:ch)?|apr(?:il)?|may|june?|july?|aug(?:ust)?|sep(?:t(?:ember)?)?|oct(?:ober)?|nov(?:ember)?|dec(?:ember)?)"#
    static let ordinal = #"(?:st|nd|rd|th)?"#

    static let numeric = Pattern(#"(?<![\d/.\-])(\d{1,2})\s?([/.\-])\s?(\d{1,2})\s?\2\s?(\d{4}|\d{2})(?![\d/]|\.\d)"#)
    static let iso = Pattern(#"(?<!\d)(\d{4})-(\d{2})-(\d{2})(?!\d)"#)
    static let dayMonthYear = Pattern(#"(?<!\d)(\d{1,2})\s*"# + ordinal + #"(?:\s+day)?(?:\s+of)?[\s\-/.,]*"# + month + #"\.?[\s\-/.,']*(\d{4}|'?\d{2}(?!\d))"#)
    static let monthDayYear = Pattern(month + #"\.?\s+(\d{1,2})\s*"# + ordinal + #",?\s*(\d{4})"#)

    public static func monthNumber(_ s: String) -> Int? {
        let key = String(s.lowercased().prefix(3))
        return ["jan", "feb", "mar", "apr", "may", "jun", "jul", "aug", "sep", "oct", "nov", "dec"].firstIndex(of: key).map { $0 + 1 }
    }

    static func expandYear(_ s: String) -> Int? {
        let digits = s.filter(\.isNumber)
        guard let y = Int(digits) else { return nil }
        if digits.count == 2 { return y < 70 ? 2000 + y : 1900 + y }
        return y
    }

    /// Finds all dates. If `preferMonthFirst` is set (the document shows evidence of
    /// US ordering), ambiguous numeric dates are read as MM/DD.
    public static func mentions(in text: String, preferMonthFirst: Bool = false) -> [DateMention] {
        let ns = text as NSString
        var found: [DateMention] = []

        for m in iso.matches(in: text) {
            guard let y = Int(m.group(1, in: ns) ?? ""), let mo = Int(m.group(2, in: ns) ?? ""), let d = Int(m.group(3, in: ns) ?? ""),
                  let date = CalendarDate(year: y, month: mo, day: d) else { continue }
            found.append(DateMention(range: m.range, date: date, text: ns.substring(with: m.range), ambiguous: false, monthFirst: false))
        }
        for m in numeric.matches(in: text) {
            guard let a = Int(m.group(1, in: ns) ?? ""), let b = Int(m.group(3, in: ns) ?? ""),
                  let y = expandYear(m.group(4, in: ns) ?? "") else { continue }
            if let mention = interpretNumeric(a, b, y, range: m.range, text: ns.substring(with: m.range), preferMonthFirst: preferMonthFirst) {
                found.append(mention)
            }
        }
        for m in dayMonthYear.matches(in: text) {
            guard let d = Int(m.group(1, in: ns) ?? ""), let mo = monthNumber(m.group(2, in: ns) ?? ""),
                  let y = expandYear(m.group(3, in: ns) ?? ""), let date = CalendarDate(year: y, month: mo, day: d) else { continue }
            found.append(DateMention(range: m.range, date: date, text: ns.substring(with: m.range), ambiguous: false, monthFirst: false))
        }
        for m in monthDayYear.matches(in: text) {
            guard let mo = monthNumber(m.group(1, in: ns) ?? ""), let d = Int(m.group(2, in: ns) ?? ""),
                  let y = Int(m.group(3, in: ns) ?? ""), let date = CalendarDate(year: y, month: mo, day: d) else { continue }
            found.append(DateMention(range: m.range, date: date, text: ns.substring(with: m.range), ambiguous: false, monthFirst: false))
        }
        // Keep the longest of overlapping mentions.
        let sorted = found.sorted { $0.range.length > $1.range.length }
        var kept: [DateMention] = []
        for item in sorted where !kept.contains(where: { NSIntersectionRange($0.range, item.range).length > 0 }) {
            kept.append(item)
        }
        return kept.sorted { $0.range.location < $1.range.location }
    }

    static func interpretNumeric(_ a: Int, _ b: Int, _ y: Int, range: NSRange, text: String, preferMonthFirst: Bool) -> DateMention? {
        let dm = CalendarDate(year: y, month: b, day: a)
        let md = CalendarDate(year: y, month: a, day: b)
        switch (dm, md) {
        case let (dm?, md?):
            let ambiguous = a != b
            let chosen = preferMonthFirst ? md : dm
            var mention = DateMention(range: range, date: chosen, text: text, ambiguous: ambiguous, monthFirst: false)
            mention.numericParts = (a, b, y)
            return mention
        case let (dm?, nil):
            var mention = DateMention(range: range, date: dm, text: text, ambiguous: false, monthFirst: false)
            mention.dayFirstOnly = true
            return mention
        case let (nil, md?):
            return DateMention(range: range, date: md, text: text, ambiguous: false, monthFirst: true)
        default:
            return nil
        }
    }

    /// Parses a single date string (from a model response or user input). ISO dates
    /// are accepted first, then any format `mentions` understands.
    public static func parseSingle(_ s: String) -> CalendarDate? {
        if let iso = CalendarDate(iso: s) { return iso }
        return mentions(in: s).first?.date
    }
}

public struct RelativeDateMention: Hashable, Sendable {
    public var range: NSRange
    public var spec: RelativeDateSpec
    public var text: String
}

/// Finds relative dates such as "within 30 days of signing" or
/// "15 days from the date of invoice".
public enum RelativeDateParser {
    static let quantity = #"(\d{1,3}|(?:"# + NumberWords.alternation + #")(?:[\s-](?:"# + NumberWords.alternation + #"))?)\s*(?:\((\d{1,3})\)\s*)?"#
    static let anchor = #"((?:the\s+)?date\s+of\s+(?:this\s+)?(?:agreement|contract|signing|execution|invoice|receipt\s+of\s+(?:the\s+|an\s+|each\s+)?invoice)|(?:the\s+)?signing(?:\s+of\s+this\s+(?:agreement|contract))?|(?:the\s+)?execution(?:\s+of\s+this\s+(?:agreement|contract))?|(?:the\s+)?effective\s+date|(?:the\s+)?commencement(?:\s+date)?|(?:the\s+)?(?:invoice\s+date|receipt\s+of\s+(?:the\s+|an\s+|each\s+)?invoice|invoice)|(?:the\s+)?(?:expiry|expiration|end|termination)(?:\s+date)?(?:\s+of\s+(?:this|the)\s+(?:agreement|term|contract))?|(?:the\s+)?(?:completion|delivery|acceptance)(?:\s+of\s+(?:the\s+)?[a-z]+(?:\s+[a-z]+)?)?)"#
    static let pattern = Pattern(#"(?:within\s+)?"# + quantity + #"(?:business\s+|working\s+|calendar\s+)?(days?|weeks?|months?|years?)'?\s+(after|from|of|following|before|prior\s+to|preceding)\s+"# + anchor)

    /// "Net 30" payment terms: 30 days after the invoice date.
    static let netTerms = Pattern(#"\bnet[\s-]*(\d{1,3})(?:\s*days)?\b"#)

    public static func mentions(in text: String) -> [RelativeDateMention] {
        let ns = text as NSString
        let net = netTerms.matches(in: text).compactMap { m -> RelativeDateMention? in
            guard let v = Int(m.group(1, in: ns) ?? ""), v > 0 else { return nil }
            return RelativeDateMention(range: m.range, spec: RelativeDateSpec(offset: Duration(value: v, unit: .days), after: true,
                                                                              anchor: .invoiceDate, anchorText: "the invoice date"),
                                       text: ns.substring(with: m.range))
        }
        return net + pattern.matches(in: text).compactMap { m in
            let qty = m.group(2, in: ns).flatMap { Int($0) } ?? NumberWords.parseInt(m.group(1, in: ns) ?? "")
            guard let value = qty, value > 0, let unitWord = m.group(3, in: ns), let dir = m.group(4, in: ns),
                  let anchorText = m.group(5, in: ns) else { return nil }
            let unit = DurationParser.unit(unitWord)
            let after = !(dir.lowercased().hasPrefix("before") || dir.lowercased().hasPrefix("prior") || dir.lowercased().hasPrefix("preced"))
            let spec = RelativeDateSpec(offset: Duration(value: value, unit: unit), after: after,
                                        anchor: classify(anchorText), anchorText: anchorText.trimmed().collapsingWhitespace())
            return RelativeDateMention(range: m.range, spec: spec, text: ns.substring(with: m.range))
        }
    }

    static func classify(_ anchor: String) -> DateAnchor {
        let a = anchor.lowercased()
        if a.contains("invoice") { return .invoiceDate }
        if a.contains("effective") || a.contains("commencement") { return .effectiveDate }
        if a.contains("expir") || a.contains("terminat") || a.range(of: #"\bend\b"#, options: .regularExpression) != nil { return .endDate }
        if a.contains("sign") || a.contains("execution") || a.contains("agreement") || a.contains("contract") { return .signing }
        return .other
    }
}

/// Finds durations such as "30 days", "thirty (30) days", "one month".
public enum DurationParser {
    static let pattern = Pattern(RelativeDateParser.quantity + #"(?:business\s+|working\s+|calendar\s+|clear\s+)?(days?|weeks?|months?|years?)(?:'|’)?(?![a-z])"#)

    public struct Mention: Hashable, Sendable {
        public var range: NSRange
        public var duration: Duration
    }

    public static func mentions(in text: String) -> [Mention] {
        let ns = text as NSString
        return pattern.matches(in: text).compactMap { m in
            let qty = m.group(2, in: ns).flatMap { Int($0) } ?? NumberWords.parseInt(m.group(1, in: ns) ?? "")
            guard let value = qty, value > 0, value < 10_000, let unitWord = m.group(3, in: ns) else { return nil }
            return Mention(range: m.range, duration: Duration(value: value, unit: unit(unitWord)))
        }
    }

    static func unit(_ word: String) -> DurationUnit {
        let w = word.lowercased()
        if w.hasPrefix("week") { return .weeks }
        if w.hasPrefix("month") { return .months }
        if w.hasPrefix("year") { return .years }
        return .days
    }

    /// Parses a standalone duration ("30 days", "1 year", "thirty days").
    public static func parseSingle(_ s: String) -> Duration? { mentions(in: s).first?.duration }
}

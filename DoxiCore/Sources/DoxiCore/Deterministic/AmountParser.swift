import Foundation

/// A money amount found in text.
public struct AmountMention: Hashable, Sendable {
    public var range: NSRange
    public var money: Money
    public var text: String
    public var fromWords: Bool
}

/// Finds amounts written the ways they appear in Indian business documents:
/// `₹80,000`, `Rs. 80,000/-`, `INR 1,20,000.50`, `Rs 1.5 lakh`, `₹2 crore`,
/// `80,000/-`, and `Rupees Eighty Thousand Only`.
public enum AmountParser {
    static let number = #"\d{1,3}(?:,\d{2,3})+(?:\.\d{1,2})?|\d+(?:\.\d{1,2})?"#
    static let multiplier = #"lakhs?|lacs?|crores?|cr\b\.?|thousand|million|mn\b|k\b"#
    static let currencyPrefix = #"₹|(?<![A-Za-z])(?:rs\.?|inr|rupees|usd|us\$|eur|gbp)(?![A-Za-z])|\$|€|£"#

    static let prefixed = Pattern("(" + currencyPrefix + #")\s*(?:\.\s*)?("# + number + #")(?:\s*("# + multiplier + #"))?(?:\s*/-)?"#)
    static let suffixed = Pattern("(?<![\\d.,])(" + number + #")(?:\s*("# + multiplier + #"))?\s*(/-|(?<![A-Za-z])(?:rupees|inr|rs)(?![A-Za-z])|₹)"#)
    static let wordAlt = #"\b(?:"# + NumberWords.alternation + #"|and)\b"#
    static let words = Pattern(
        #"(?:(?:indian\s+)?rupees|(?<![A-Za-z])rs\.?|(?<![A-Za-z])inr)\s*:?\s*((?:"# + wordAlt + #"[\s-]+)*"# + wordAlt + #")(?:\s+only)?|((?:"# + wordAlt + #"[\s-]+)+)rupees(?:\s+only)?"#)

    public static func mentions(in text: String) -> [AmountMention] {
        let ns = text as NSString
        var found: [AmountMention] = []

        for m in prefixed.matches(in: text) {
            guard let cur = m.group(1, in: ns), let num = m.group(2, in: ns),
                  let money = makeMoney(number: num, multiplier: m.group(3, in: ns), currency: currencyCode(cur)) else { continue }
            found.append(AmountMention(range: m.range, money: money, text: ns.substring(with: m.range), fromWords: false))
        }
        for m in suffixed.matches(in: text) {
            guard let num = m.group(1, in: ns), let suffix = m.group(3, in: ns) else { continue }
            let currency = suffix == "/-" ? "INR" : currencyCode(suffix)
            guard let money = makeMoney(number: num, multiplier: m.group(2, in: ns), currency: currency) else { continue }
            found.append(AmountMention(range: m.range, money: money, text: ns.substring(with: m.range), fromWords: false))
        }
        for m in words.matches(in: text) {
            let phrase = m.group(1, in: ns) ?? m.group(2, in: ns) ?? ""
            guard let value = NumberWords.parse(phrase), value > 0 else { continue }
            found.append(AmountMention(range: m.range, money: Money(minorUnits: value * 100), text: ns.substring(with: m.range), fromWords: true))
        }
        return removeOverlaps(found)
    }

    /// Keeps the longest mention among overlapping ones.
    static func removeOverlaps(_ items: [AmountMention]) -> [AmountMention] {
        let sorted = items.sorted { $0.range.length > $1.range.length }
        var kept: [AmountMention] = []
        for item in sorted where !kept.contains(where: { NSIntersectionRange($0.range, item.range).length > 0 }) {
            kept.append(item)
        }
        return kept.sorted { $0.range.location < $1.range.location }
    }

    static func currencyCode(_ token: String) -> String {
        let t = token.lowercased().replacingOccurrences(of: ".", with: "")
        switch t {
        case "$", "usd", "us$": return "USD"
        case "€", "eur": return "EUR"
        case "£", "gbp": return "GBP"
        default: return "INR"
        }
    }

    static func makeMoney(number: String, multiplier: String?, currency: String) -> Money? {
        guard let base = Decimal(string: number.replacingOccurrences(of: ",", with: ""), locale: Locale(identifier: "en_US_POSIX")) else { return nil }
        var factor: Decimal = 1
        if let mult = multiplier?.lowercased().replacingOccurrences(of: ".", with: "") {
            if mult.hasPrefix("lakh") || mult.hasPrefix("lac") { factor = 100_000 }
            else if mult.hasPrefix("crore") || mult == "cr" { factor = 10_000_000 }
            else if mult == "thousand" || mult == "k" { factor = 1_000 }
            else if mult == "million" || mult == "mn" { factor = 1_000_000 }
        }
        let value = base * factor
        guard value > 0 else { return nil }
        return Money(major: value, currency: currency)
    }

    /// Lenient parse of a single amount typed by a user or returned by a model:
    /// accepts bare numbers ("80000", "80,000.50", "1.5 lakh", "80k") as INR.
    public static func parseLoose(_ s: String, defaultCurrency: String = "INR") -> Money? {
        let t = s.trimmed()
        guard !t.isEmpty else { return nil }
        if let m = mentions(in: t).first, m.range.length >= t.utf16Length - 6 { return m.money }
        let bare = Pattern("^(?:" + currencyPrefix + #")?\s*("# + number + #")\s*("# + multiplier + #")?\s*(?:/-)?$"#)
        let ns = t as NSString
        guard let m = bare.firstMatch(in: t), let num = m.group(1, in: ns) else {
            if let words = NumberWords.parse(t.replacingOccurrences(of: "only", with: "", options: .caseInsensitive)
                .replacingOccurrences(of: "rupees", with: "", options: .caseInsensitive)) {
                return Money(minorUnits: words * 100, currency: defaultCurrency)
            }
            return nil
        }
        let currency = t.hasPrefix("$") || t.lowercased().hasPrefix("usd") ? "USD" : defaultCurrency
        return makeMoney(number: num, multiplier: m.group(2, in: ns), currency: currency)
    }

    /// Plain numbers with digit grouping ("80,000", "1,20,000") that may be amounts in
    /// tables without a currency marker. Used for search indexing only.
    public static func groupedNumbers(in text: String) -> [Int64] {
        let p = Pattern(#"(?<![\d.,])\d{1,3}(?:,\d{2,3})+(?:\.\d{1,2})?(?![\d,])"#)
        let ns = text as NSString
        return p.matches(in: text).compactMap { m in
            let raw = ns.substring(with: m.range).replacingOccurrences(of: ",", with: "")
            return Decimal(string: raw).map { Money(major: $0).minorUnits }
        }
    }
}

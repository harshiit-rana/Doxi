import Foundation

/// Parses English number words using the Indian numbering system
/// ("one lakh twenty thousand" = 120000, "two crore fifty lakh" = 25000000).
public enum NumberWords {
    static let units: [String: Int] = [
        "zero": 0, "one": 1, "two": 2, "three": 3, "four": 4, "five": 5, "six": 6, "seven": 7, "eight": 8,
        "nine": 9, "ten": 10, "eleven": 11, "twelve": 12, "thirteen": 13, "fourteen": 14, "fifteen": 15,
        "sixteen": 16, "seventeen": 17, "eighteen": 18, "nineteen": 19, "twenty": 20, "thirty": 30,
        "forty": 40, "fourty": 40, "fifty": 50, "sixty": 60, "seventy": 70, "eighty": 80, "ninety": 90,
        "a": 1, "an": 1,
    ]
    static let scales: [String: Int64] = [
        "hundred": 100, "thousand": 1_000, "lakh": 100_000, "lakhs": 100_000, "lac": 100_000, "lacs": 100_000,
        "million": 1_000_000, "crore": 10_000_000, "crores": 10_000_000,
    ]

    /// Regex alternation of all number words (longest first).
    static let alternation: String = {
        let words = Array(units.keys.filter { $0 != "a" && $0 != "an" }) + Array(scales.keys)
        return words.sorted { $0.count > $1.count }.joined(separator: "|")
    }()

    /// Parses a phrase of number words. Returns nil if any token is not a number word
    /// (other than "and") or the phrase is empty.
    public static func parse(_ phrase: String) -> Int64? {
        let tokens = phrase.lowercased()
            .replacingOccurrences(of: "-", with: " ")
            .split(whereSeparator: { !$0.isLetter })
            .map(String.init)
            .filter { $0 != "and" }
        guard !tokens.isEmpty else { return nil }
        var total: Int64 = 0
        var current: Int64 = 0
        var sawNumber = false
        for token in tokens {
            if let u = units[token] {
                current += Int64(u)
                sawNumber = true
            } else if let scale = scales[token] {
                if current == 0 { current = 1 }
                if scale == 100 {
                    current *= 100
                } else {
                    total += current * scale
                    current = 0
                }
                sawNumber = true
            } else {
                return nil
            }
        }
        return sawNumber ? total + current : nil
    }

    /// Parses digits ("30") or words ("thirty").
    public static func parseInt(_ s: String) -> Int? {
        let t = s.trimmed()
        if let v = Int(t) { return v }
        return parse(t).map { Int($0) }
    }
}

import Foundation

public struct IdentifierMention: Hashable, Sendable {
    public var range: NSRange
    public var value: IdentifierValue
}

/// Detects Indian business identifiers: GSTIN, PAN and Aadhaar numbers.
/// Aadhaar numbers are validated with the Verhoeff checksum and stored masked.
public enum IdentifierDetector {
    static let gstin = Pattern(#"(?<![A-Z0-9])(\d{2}[A-Z]{5}\d{4}[A-Z][1-9A-Z]Z[0-9A-Z])(?![A-Z0-9])"#, caseInsensitive: false)
    static let pan = Pattern(#"(?<![A-Z0-9])([A-Z]{3}[PCHFATBLJG][A-Z]\d{4}[A-Z])(?![A-Z0-9])"#, caseInsensitive: false)
    static let aadhaar = Pattern(#"(?<![\d])([2-9]\d{3})[ -]?(\d{4})[ -]?(\d{4})(?![\d])"#)

    public static func mentions(in text: String) -> [IdentifierMention] {
        let ns = text as NSString
        var out: [IdentifierMention] = []
        let gstMatches = gstin.matches(in: text)
        for m in gstMatches {
            out.append(IdentifierMention(range: m.range, value: IdentifierValue(type: .gstin, value: ns.substring(with: m.range))))
        }
        for m in pan.matches(in: text) where !gstMatches.contains(where: { NSIntersectionRange($0.range, m.range).length > 0 }) {
            out.append(IdentifierMention(range: m.range, value: IdentifierValue(type: .pan, value: ns.substring(with: m.range))))
        }
        for m in aadhaar.matches(in: text) {
            let digits = ns.substring(with: m.range).filter(\.isNumber)
            guard digits.count == 12, verhoeffValid(digits) else { continue }
            out.append(IdentifierMention(range: m.range, value: IdentifierValue(type: .aadhaar, value: "XXXX XXXX " + digits.suffix(4))))
        }
        return out.sorted { $0.range.location < $1.range.location }
    }

    static let d: [[Int]] = [
        [0, 1, 2, 3, 4, 5, 6, 7, 8, 9], [1, 2, 3, 4, 0, 6, 7, 8, 9, 5], [2, 3, 4, 0, 1, 7, 8, 9, 5, 6],
        [3, 4, 0, 1, 2, 8, 9, 5, 6, 7], [4, 0, 1, 2, 3, 9, 5, 6, 7, 8], [5, 9, 8, 7, 6, 0, 4, 3, 2, 1],
        [6, 5, 9, 8, 7, 1, 0, 4, 3, 2], [7, 6, 5, 9, 8, 2, 1, 0, 4, 3], [8, 7, 6, 5, 9, 3, 2, 1, 0, 4],
        [9, 8, 7, 6, 5, 4, 3, 2, 1, 0],
    ]
    static let p: [[Int]] = [
        [0, 1, 2, 3, 4, 5, 6, 7, 8, 9], [1, 5, 7, 6, 2, 8, 3, 0, 9, 4], [5, 8, 0, 3, 7, 9, 6, 1, 4, 2],
        [8, 9, 1, 6, 0, 4, 3, 5, 2, 7], [9, 4, 5, 3, 1, 2, 6, 8, 7, 0], [4, 2, 8, 6, 5, 7, 3, 9, 0, 1],
        [2, 7, 9, 3, 8, 0, 6, 4, 1, 5], [7, 0, 4, 6, 9, 1, 3, 2, 5, 8],
    ]

    public static func verhoeffValid(_ digits: String) -> Bool {
        var c = 0
        for (i, ch) in digits.reversed().enumerated() {
            guard let n = ch.wholeNumberValue else { return false }
            c = d[c][p[i % 8][n]]
        }
        return c == 0
    }
}

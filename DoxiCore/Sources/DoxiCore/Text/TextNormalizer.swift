import Foundation

/// Normalises text for matching while keeping a map back to the original
/// UTF-16 offsets, so a match found in normalised text can be highlighted in
/// the original document.
public struct NormalizedText: Sendable {
    /// The normalised string (lowercased, folded, whitespace collapsed, punctuation reduced).
    public let text: String
    /// For each UTF-16 unit of `text`, the UTF-16 offset in the original string.
    public let originalOffsets: [Int]
    /// For each UTF-16 unit of `text`, the end offset of its original character.
    let originalEnds: [Int]

    public init(_ original: String) {
        var out: [UInt16] = []
        var offsets: [Int] = []
        var ends: [Int] = []
        var lastWasSpace = true
        let ns = original as NSString
        var i = 0
        while i < ns.length {
            let range = ns.rangeOfComposedCharacterSequence(at: i)
            let piece = ns.substring(with: range)
            let mapped = NormalizedText.map(piece)
            for ch in mapped {
                if ch == " " {
                    if lastWasSpace { continue }
                    lastWasSpace = true
                } else {
                    lastWasSpace = false
                }
                for unit in String(ch).utf16 {
                    out.append(unit)
                    offsets.append(range.location)
                    ends.append(range.location + range.length)
                }
            }
            i = range.location + range.length
        }
        if out.last == 32 {
            out.removeLast()
            offsets.removeLast()
            ends.removeLast()
        }
        self.originalEnds = ends
        self.text = String(decoding: out, as: UTF16.self)
        self.originalOffsets = offsets
    }

    /// Maps one composed character to its normalised form.
    static func map(_ piece: String) -> String {
        guard let scalar = piece.unicodeScalars.first else { return "" }
        if CharacterSet.whitespacesAndNewlines.contains(scalar) { return " " }
        switch piece {
        case "\u{2018}", "\u{2019}", "\u{201A}", "\u{2032}", "`": return "'"
        case "\u{201C}", "\u{201D}", "\u{201E}", "\u{2033}": return "\""
        case "\u{2010}", "\u{2011}", "\u{2012}", "\u{2013}", "\u{2014}", "\u{2212}": return "-"
        case "\u{200B}", "\u{200C}", "\u{200D}", "\u{FEFF}", "\u{00AD}": return ""
        case "\u{00A0}": return " "
        default: break
        }
        let folded = piece.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: Locale(identifier: "en_US_POSIX"))
        return folded.lowercased()
    }

    /// Maps a range in the normalised text back to a range in the original string.
    public func originalRange(of range: NSRange) -> NSRange {
        guard range.length > 0, range.location < originalOffsets.count else { return NSRange(location: 0, length: 0) }
        let start = originalOffsets[range.location]
        let lastIndex = min(range.location + range.length, originalEnds.count) - 1
        return NSRange(location: start, length: max(0, originalEnds[lastIndex] - start))
    }
}

public enum TextNormalizer {
    /// Normalised form used for comparisons (no offset map).
    public static func normalize(_ s: String) -> String { NormalizedText(s).text }

    /// Fast normalisation for search: case/diacritic/width folded, punctuation and
    /// whitespace reduced to single spaces. No offset map (not for highlighting).
    public static func searchKey(_ s: String) -> String {
        let folded = s.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: Locale(identifier: "en_US_POSIX"))
        var out = String.UnicodeScalarView()
        out.reserveCapacity(folded.unicodeScalars.count)
        var lastSpace = true
        for u in folded.unicodeScalars {
            if CharacterSet.alphanumerics.contains(u) || u == "₹" {
                out.append(u)
                lastSpace = false
            } else if !lastSpace {
                out.append(" ")
                lastSpace = true
            }
        }
        return String(out).lowercased()
    }

    /// Lowercase alphanumeric tokens.
    public static func tokens(_ s: String) -> [String] {
        normalize(s).split(whereSeparator: { !($0.isLetter || $0.isNumber) }).map(String.init)
    }
}

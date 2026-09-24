import Foundation

/// Thin wrapper over `NSRegularExpression` that works in UTF-16 ranges, which is
/// the unit used for every text range in DoxiCore.
struct Pattern: @unchecked Sendable {
    let regex: NSRegularExpression

    init(_ pattern: String, caseInsensitive: Bool = true, anchorsMatchLines: Bool = false) {
        var options: NSRegularExpression.Options = []
        if caseInsensitive { options.insert(.caseInsensitive) }
        if anchorsMatchLines { options.insert(.anchorsMatchLines) }
        // Patterns are compile-time constants; a failure is a programming error caught by tests.
        regex = try! NSRegularExpression(pattern: pattern, options: options)
    }

    func matches(in text: String, range: NSRange? = nil) -> [NSTextCheckingResult] {
        let ns = text as NSString
        return regex.matches(in: text, options: [], range: range ?? NSRange(location: 0, length: ns.length))
    }

    func firstMatch(in text: String, range: NSRange? = nil) -> NSTextCheckingResult? {
        let ns = text as NSString
        return regex.firstMatch(in: text, options: [], range: range ?? NSRange(location: 0, length: ns.length))
    }
}

extension NSTextCheckingResult {
    /// The captured substring for a group, or nil when the group did not participate.
    func group(_ index: Int, in text: NSString) -> String? {
        guard index < numberOfRanges else { return nil }
        let r = range(at: index)
        guard r.location != NSNotFound else { return nil }
        return text.substring(with: r)
    }

    func groupRange(_ index: Int) -> NSRange? {
        guard index < numberOfRanges else { return nil }
        let r = range(at: index)
        return r.location == NSNotFound ? nil : r
    }
}

extension String {
    var utf16Length: Int { (self as NSString).length }

    func trimmed() -> String { trimmingCharacters(in: .whitespacesAndNewlines) }

    /// Collapses runs of whitespace into single spaces.
    func collapsingWhitespace() -> String {
        split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
    }
}

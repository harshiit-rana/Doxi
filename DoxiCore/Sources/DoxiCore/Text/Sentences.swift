import Foundation

/// Splits text into sentence-like units: sentences, list items and short lines.
/// Contracts mix prose with numbered clauses and invoices are line oriented, so
/// both line breaks before list markers and sentence punctuation split units.
enum SentenceSplitter {
    private static let boundary = Pattern(
        #"(?<=[.;!?])(?<!(?i:\b(?:rs|no|nos|mr|ms|mrs|dr|pvt|ltd|co|st|sr|jr|vs|viz|etc|inc|approx|cl|art|sec|m/s|messrs|shri|smt|govt|dept|ref|e\.g|i\.e)\.))\s+(?=["'(]?[A-Z0-9₹])|\n\s*\n|\n(?=\s*(?:\(?[0-9]{1,2}(?:\.[0-9]{1,2})*[.)]|\(?[a-z]{1,3}[.)]|[•\-*]|[A-Z][A-Za-z /&]{2,40}:)\s)"#,
        caseInsensitive: false)

    /// Ranges (UTF-16) of each unit, trimmed of surrounding whitespace.
    static func ranges(in text: String) -> [NSRange] {
        let ns = text as NSString
        var out: [NSRange] = []
        var start = 0
        func emit(_ end: Int) {
            var s = start, e = end
            while s < e, let c = UnicodeScalar(ns.character(at: s)), CharacterSet.whitespacesAndNewlines.contains(c) { s += 1 }
            while e > s, let c = UnicodeScalar(ns.character(at: e - 1)), CharacterSet.whitespacesAndNewlines.contains(c) { e -= 1 }
            if e > s { out.append(NSRange(location: s, length: e - s)) }
        }
        for m in boundary.matches(in: text) {
            emit(m.range.location)
            start = m.range.location + m.range.length
        }
        emit(ns.length)
        // Headings: a short line without closing punctuation followed by a new line
        // that starts with a capital letter is its own unit ("3. Fees and Payment").
        out = out.flatMap { r -> [NSRange] in
            let unit = ns.substring(with: r) as NSString
            let nl = unit.range(of: "\n")
            guard nl.location != NSNotFound, nl.location <= 60, nl.location + 1 < unit.length else { return [r] }
            let head = unit.substring(to: nl.location).trimmed()
            guard let last = head.last, !",;:-(&".contains(last), !head.isEmpty,
                  let next = unit.substring(from: nl.location + 1).trimmed().first, next.isUppercase || next.isNumber || next == "₹" else { return [r] }
            let first = NSRange(location: r.location, length: nl.location)
            let restStart = r.location + nl.location + 1
            var restRange = NSRange(location: restStart, length: r.location + r.length - restStart)
            while restRange.length > 0, let c = UnicodeScalar(ns.character(at: restRange.location)), CharacterSet.whitespacesAndNewlines.contains(c) {
                restRange = NSRange(location: restRange.location + 1, length: restRange.length - 1)
            }
            return restRange.length > 0 ? [first, restRange] : [first]
        }
        // Very long units (tables, run-on scans) are further split by line.
        return out.flatMap { r -> [NSRange] in
            guard r.length > 600 else { return [r] }
            var pieces: [NSRange] = []
            var s = r.location
            let end = r.location + r.length
            var i = r.location
            while i < end {
                if ns.character(at: i) == 10 {
                    if i > s { pieces.append(NSRange(location: s, length: i - s)) }
                    s = i + 1
                }
                i += 1
            }
            if end > s { pieces.append(NSRange(location: s, length: end - s)) }
            return pieces
        }
    }

    /// Ranges of each line (split on newlines), skipping blank lines.
    static func lineRanges(in text: String) -> [NSRange] {
        let ns = text as NSString
        var out: [NSRange] = []
        var s = 0
        for i in 0...ns.length {
            if i == ns.length || ns.character(at: i) == 10 {
                let r = NSRange(location: s, length: i - s)
                if !ns.substring(with: r).trimmed().isEmpty { out.append(r) }
                s = i + 1
            }
        }
        return out
    }
}

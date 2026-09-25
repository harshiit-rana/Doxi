import Foundation

/// Repairs digits that OCR commonly reads as letters inside numbers and dates
/// ("O1/12/2026" → "01/12/2026", "50,OOO" → "50,000"). Substitutions are one
/// character for one character, so every text range stays valid for the original.
public enum OCRDigits {
    static let token = Pattern(#"(?<![A-Za-z])[0-9OoIl|][0-9OoIl|,./\-]*[0-9OoIl|](?![A-Za-z])"#, caseInsensitive: false)

    public static func normalize(_ text: String) -> String {
        let ns = NSMutableString(string: text)
        for m in token.matches(in: text) {
            let t = ns.substring(with: m.range)
            let digits = t.filter(\.isNumber).count
            let letters = t.filter { "OoIl|".contains($0) }.count
            // Only fix tokens that are clearly numeric: at least two real digits, and either
            // more digits than look-alikes or number punctuation ("50,OOO", "O1/12/2026").
            let punctuated = t.contains { ",./-".contains($0) }
            guard letters > 0, digits >= 2, digits > letters || punctuated else { continue }
            var fixed = ""
            for ch in t {
                switch ch {
                case "O", "o": fixed.append("0")
                case "I", "l", "|": fixed.append("1")
                default: fixed.append(ch)
                }
            }
            ns.replaceCharacters(in: m.range, with: fixed)
        }
        return ns as String
    }
}

import Foundation

/// An amount of money stored in minor units (paise for INR) to avoid floating
/// point drift.
public struct Money: Codable, Hashable, Sendable, Comparable {
    public var minorUnits: Int64
    public var currency: String

    public init(minorUnits: Int64, currency: String = "INR") {
        self.minorUnits = minorUnits
        self.currency = currency
    }

    public init(major: Decimal, currency: String = "INR") {
        var scaled = major * 100
        var rounded = Decimal()
        NSDecimalRound(&rounded, &scaled, 0, .plain)
        self.minorUnits = NSDecimalNumber(decimal: rounded).int64Value
        self.currency = currency
    }

    public var majorValue: Decimal { Decimal(minorUnits) / 100 }

    public static func < (lhs: Money, rhs: Money) -> Bool {
        (lhs.currency, lhs.minorUnits) < (rhs.currency, rhs.minorUnits)
    }

    public var currencySymbol: String {
        switch currency {
        case "INR": return "₹"
        case "USD": return "$"
        case "EUR": return "€"
        case "GBP": return "£"
        default: return currency + " "
        }
    }

    /// Formats with Indian digit grouping for INR (₹1,20,000) and western grouping otherwise.
    public var formatted: String {
        let negative = minorUnits < 0
        let absMinor = negative ? -minorUnits : minorUnits
        let whole = absMinor / 100
        let fraction = absMinor % 100
        let grouped = currency == "INR" ? Money.indianGrouping(whole) : Money.westernGrouping(whole)
        let fractionPart = fraction == 0 ? "" : String(format: ".%02d", fraction)
        return (negative ? "-" : "") + currencySymbol + grouped + fractionPart
    }

    static func indianGrouping(_ value: Int64) -> String {
        let digits = String(value)
        guard digits.count > 3 else { return digits }
        let lastThree = digits.suffix(3)
        var rest = String(digits.dropLast(3))
        var groups: [String] = []
        while rest.count > 2 {
            groups.insert(String(rest.suffix(2)), at: 0)
            rest = String(rest.dropLast(2))
        }
        if !rest.isEmpty { groups.insert(rest, at: 0) }
        return groups.joined(separator: ",") + "," + lastThree
    }

    static func westernGrouping(_ value: Int64) -> String {
        let digits = Array(String(value))
        var out = ""
        for (i, ch) in digits.enumerated() {
            if i > 0 && (digits.count - i) % 3 == 0 { out.append(",") }
            out.append(ch)
        }
        return out
    }
}

import Foundation

/// The user's identity, used to work out which party in a document is them.
public struct IdentityProfile: Codable, Hashable, Sendable {
    public var name: String
    public var businessName: String
    public var aliases: [String]
    public var gstin: String?

    public init(name: String, businessName: String = "", aliases: [String] = [], gstin: String? = nil) {
        self.name = name
        self.businessName = businessName
        self.aliases = aliases
        self.gstin = gstin
    }

    /// All names the user goes by, non-empty and de-duplicated.
    public var allNames: [String] {
        var seen = Set<String>()
        return ([name, businessName] + aliases).map { $0.trimmed() }.filter { !$0.isEmpty && seen.insert(PartyMatcher.canonical($0)).inserted }
    }

    public var isComplete: Bool { !name.trimmed().isEmpty }
}

public enum PartyMatchOutcome: Equatable, Sendable {
    /// Exactly one party confidently matches the profile.
    case matched(index: Int, score: Double, matchedName: String)
    /// Several parties could be the user; ask.
    case ambiguous(candidates: [Int])
    /// No party resembles the profile; ask.
    case noMatch
}

/// Fuzzy matching of party names against the user's profile. It never guesses:
/// anything short of one clear match returns `.ambiguous` or `.noMatch` so the
/// app asks "Who are you in this agreement?".
public enum PartyMatcher {
    static let honorifics: Set<String> = ["mr", "ms", "mrs", "dr", "shri", "smt", "sri", "kumari", "m", "s", "messrs", "the"]
    static let suffixes: Set<String> = ["pvt", "private", "ltd", "limited", "llp", "inc", "incorporated", "co", "company", "corp",
                                        "corporation", "opc", "plc", "llc", "gmbh", "proprietor", "proprietorship"]

    /// Lowercase tokens without honorifics and company suffixes.
    public static func tokens(_ name: String) -> [String] {
        TextNormalizer.tokens(name).filter { !honorifics.contains($0) && !suffixes.contains($0) }
    }

    public static func canonical(_ name: String) -> String { tokens(name).joined(separator: " ") }

    /// Similarity in 0...1 between two names.
    public static func similarity(_ a: String, _ b: String) -> Double {
        let ta = tokens(a), tb = tokens(b)
        guard !ta.isEmpty, !tb.isEmpty else { return 0 }
        let ca = ta.joined(separator: " "), cb = tb.joined(separator: " ")
        if ca == cb { return 1 }
        let sa = Set(ta), sb = Set(tb)
        // One name fully contained in the other ("Harshit" in "Harshit Rana", "ABC Technologies" in "ABC Technologies India").
        let smaller = sa.count <= sb.count ? sa : sb
        let larger = sa.count <= sb.count ? sb : sa
        if smaller.isSubset(of: larger) {
            // "Rana Digital" inside "Rana Digital Studio" is a strong signal; a single shared
            // word ("Rana", "Harshit") is not: many people share a first or last name, so it
            // only makes the party a candidate and the user is asked.
            if smaller.count >= 2 { return 0.9 }
            return smaller.contains { $0.count >= 3 } ? 0.65 : 0.4
        }
        // OCR noise: near-identical strings.
        let editRatio = 1 - Double(levenshtein(ca, cb)) / Double(max(ca.count, cb.count))
        if editRatio >= 0.88 { return 0.86 }
        // Token overlap with typo tolerance.
        var hits = 0.0
        for t in smaller where larger.contains(t) || larger.contains(where: { $0.count >= 5 && levenshtein($0, t) <= 1 }) {
            hits += 1
        }
        return 0.8 * hits / Double(larger.count)
    }

    public static func levenshtein(_ a: String, _ b: String) -> Int {
        let x = Array(a), y = Array(b)
        if x.isEmpty { return y.count }
        if y.isEmpty { return x.count }
        var prev = Array(0...y.count)
        var cur = [Int](repeating: 0, count: y.count + 1)
        for i in 1...x.count {
            cur[0] = i
            for j in 1...y.count {
                cur[j] = min(prev[j] + 1, cur[j - 1] + 1, prev[j - 1] + (x[i - 1] == y[j - 1] ? 0 : 1))
            }
            swap(&prev, &cur)
        }
        return prev[y.count]
    }

    /// Best score of a party name against every name in the profile.
    public static func score(_ partyName: String, profile: IdentityProfile) -> (score: Double, matched: String) {
        profile.allNames.map { (similarity(partyName, $0), $0) }.max { $0.0 < $1.0 } ?? (0, "")
    }

    public static let matchThreshold = 0.85
    public static let ambiguityThreshold = 0.6

    public static func match(parties: [String], profile: IdentityProfile) -> PartyMatchOutcome {
        guard profile.isComplete, !parties.isEmpty else { return .noMatch }
        let scored = parties.enumerated().map { (index: $0.offset, result: score($0.element, profile: profile)) }
        let strong = scored.filter { $0.result.score >= matchThreshold }
        let plausible = scored.filter { $0.result.score >= ambiguityThreshold }
        if strong.count == 1, plausible.count == 1, let s = strong.first {
            return .matched(index: s.index, score: s.result.score, matchedName: s.result.matched)
        }
        if !plausible.isEmpty { return .ambiguous(candidates: plausible.map(\.index)) }
        return .noMatch
    }
}

/// Works out whether a payment is owed to the user or by the user.
public enum DirectionResolver {
    static let payerRoles = ["client", "customer", "buyer", "tenant", "lessee", "licensee", "purchaser", "bill to", "billed to", "company"]
    static let payeeRoles = ["service provider", "freelancer", "consultant", "vendor", "contractor", "supplier", "seller",
                             "landlord", "lessor", "licensor", "agency", "developer", "designer"]

    public struct Party: Sendable {
        public var name: String
        public var role: String?
        public init(name: String, role: String?) { self.name = name; self.role = role }
    }

    public struct Result: Equatable, Sendable {
        public var direction: FinancialDirection
        /// Why, in words shown to the user.
        public var reason: String
    }

    /// - Parameters:
    ///   - userParty: the party the user confirmed as themselves; nil if not chosen yet;
    ///     `userIsNeither` when they said they are not a party.
    public static func resolve(payer: String?, payee: String?, userParty: String?, userIsNeither: Bool,
                               parties: [Party]) -> Result {
        if userIsNeither { return Result(direction: .notMine, reason: "You said you are not a party to this document.") }
        guard let user = userParty else { return Result(direction: .unknown, reason: "Choose which party you are to set the direction.") }
        func isUser(_ name: String?) -> Bool { name.map { PartyMatcher.similarity($0, user) >= PartyMatcher.matchThreshold } ?? false }
        if isUser(payee) { return Result(direction: .owedToMe, reason: "The document names you (\(user)) as the payee.") }
        if isUser(payer) { return Result(direction: .iOwe, reason: "The document names you (\(user)) as the payer.") }
        if let payer, !payer.isEmpty, parties.count == 2, parties.contains(where: { PartyMatcher.similarity($0.name, payer) >= PartyMatcher.matchThreshold }) {
            return Result(direction: .owedToMe, reason: "The other party (\(payer)) is named as the payer.")
        }
        if let payee, !payee.isEmpty, parties.count == 2, parties.contains(where: { PartyMatcher.similarity($0.name, payee) >= PartyMatcher.matchThreshold }) {
            return Result(direction: .iOwe, reason: "The other party (\(payee)) is named as the payee.")
        }
        // Fall back to the user's role in the document.
        if let role = parties.first(where: { PartyMatcher.similarity($0.name, user) >= PartyMatcher.matchThreshold })?.role?.lowercased() {
            if payeeRoles.contains(where: { role.contains($0) }) {
                return Result(direction: .owedToMe, reason: "You are the \(role) in this document, who receives payment.")
            }
            if payerRoles.contains(where: { role.contains($0) }) {
                return Result(direction: .iOwe, reason: "You are the \(role) in this document, who makes payment.")
            }
        }
        return Result(direction: .unknown, reason: "The document does not say who pays; please choose.")
    }
}

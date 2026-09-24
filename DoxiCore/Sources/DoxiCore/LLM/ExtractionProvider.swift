import Foundation

/// A language-model backed extractor. Implementations send document text to a
/// model and return its structured answer. They never decide confidence: every
/// value they return is re-located in the document by `SourceMatcher`.
public protocol ExtractionProvider: Sendable {
    /// Stable identifier ("anthropic", "apple-on-device").
    var id: String { get }
    /// Name shown to the user, e.g. "Claude (Anthropic cloud)".
    var displayName: String { get }
    /// True when document text leaves the device. The UI must disclose this.
    var sendsDataOffDevice: Bool { get }

    func extract(_ request: LLMExtractionRequest) async throws -> LLMExtractionResponse
}

public struct LLMExtractionRequest: Sendable {
    public var document: DocumentText
    /// Used to resolve words like "this year"; also given to the model.
    public var today: CalendarDate
    /// Maximum characters of document text to send.
    public var maxCharacters: Int

    public init(document: DocumentText, today: CalendarDate, maxCharacters: Int = 300_000) {
        self.document = document
        self.today = today
        self.maxCharacters = maxCharacters
    }
}

public enum ExtractionProviderError: Error, Equatable, LocalizedError, Sendable {
    case missingAPIKey
    case invalidAPIKey
    case rateLimited(retryAfterSeconds: Int?)
    case overloaded
    case network(String)
    case server(status: Int, message: String)
    case badRequest(String)
    case refused(String?)
    case truncated
    case invalidResponse(String)
    case unavailable(String)

    public var errorDescription: String? {
        switch self {
        case .missingAPIKey: return "No API key is configured for cloud extraction. Add one in Settings."
        case .invalidAPIKey: return "The API key was rejected. Check it in Settings."
        case .rateLimited(let s): return "The AI service is rate limiting requests" + (s.map { ". Try again in \($0) seconds." } ?? ". Try again shortly.")
        case .overloaded: return "The AI service is temporarily overloaded. Try again shortly."
        case .network(let m): return "Network error: \(m)"
        case .server(let status, let m): return "The AI service returned an error (\(status)): \(m)"
        case .badRequest(let m): return "The AI service rejected the request: \(m)"
        case .refused(let m): return "The AI service declined to process this document" + (m.map { " (\($0))" } ?? "") + "."
        case .truncated: return "The AI response was cut off before it finished."
        case .invalidResponse(let m): return "The AI response could not be read: \(m)"
        case .unavailable(let m): return m
        }
    }

    /// Whether retrying later might succeed.
    public var isTransient: Bool {
        switch self {
        case .rateLimited, .overloaded, .network, .server: return true
        default: return false
        }
    }
}

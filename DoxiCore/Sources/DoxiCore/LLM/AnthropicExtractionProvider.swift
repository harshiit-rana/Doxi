import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Cloud extraction through the Anthropic Messages API (raw HTTPS; there is no
/// official Swift SDK). The API key is supplied by the user at runtime and is
/// never bundled with the app.
public struct AnthropicExtractionProvider: ExtractionProvider {
    public static let defaultModel = "claude-opus-5"
    public static let endpoint = URL(string: "https://api.anthropic.com/v1/messages")!

    public let id = "anthropic"
    public var displayName: String { "Claude (Anthropic cloud)" }
    public let sendsDataOffDevice = true

    public var apiKey: String
    public var model: String
    public var timeout: TimeInterval
    /// Performs the HTTP request. Replaceable for tests.
    public var transport: @Sendable (URLRequest) async throws -> (Data, HTTPURLResponse)

    public init(apiKey: String, model: String = AnthropicExtractionProvider.defaultModel, timeout: TimeInterval = 240,
                transport: (@Sendable (URLRequest) async throws -> (Data, HTTPURLResponse))? = nil) {
        self.apiKey = apiKey
        self.model = model
        self.timeout = timeout
        self.transport = transport ?? AnthropicExtractionProvider.urlSessionTransport
    }

    /// Ephemeral: no cookies, cache or credentials are written to disk for these requests.
    static let session = URLSession(configuration: .ephemeral)

    public static let urlSessionTransport: @Sendable (URLRequest) async throws -> (Data, HTTPURLResponse) = { request in
        // Continuation-based so it also builds against swift-corelibs-foundation (tests on Linux).
        let (data, response): (Data, URLResponse) = try await withCheckedThrowingContinuation { continuation in
            let task = AnthropicExtractionProvider.session.dataTask(with: request) { data, response, error in
                if let error {
                    continuation.resume(throwing: ExtractionProviderError.network(error.localizedDescription))
                } else if let data, let response {
                    continuation.resume(returning: (data, response))
                } else {
                    continuation.resume(throwing: ExtractionProviderError.network("Empty response"))
                }
            }
            task.resume()
        }
        guard let http = response as? HTTPURLResponse else { throw ExtractionProviderError.network("No HTTP response") }
        return (data, http)
    }

    /// Request options; compatibility retries drop optional features the API rejects.
    struct Options: Equatable {
        var structuredOutput = true
        var serverFallbacks = true
    }

    func makeRequest(prompt: String, options: Options) throws -> URLRequest {
        var body: [String: Any] = [
            "model": model,
            "max_tokens": 16000,
            "thinking": ["type": "adaptive"],
            "system": LLMPrompt.system + (options.structuredOutput ? "" : "\n\n" + LLMPrompt.jsonShapeDescription),
            "messages": [["role": "user", "content": prompt]],
        ]
        var outputConfig: [String: Any] = ["effort": "medium"]
        if options.structuredOutput {
            outputConfig["format"] = ["type": "json_schema", "schema": LLMPrompt.jsonSchema]
        }
        body["output_config"] = outputConfig
        if options.serverFallbacks {
            body["fallbacks"] = "default"
        }
        var request = URLRequest(url: AnthropicExtractionProvider.endpoint)
        request.httpMethod = "POST"
        request.timeoutInterval = timeout
        request.setValue("application/json", forHTTPHeaderField: "content-type")
        request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        if options.serverFallbacks {
            request.setValue("server-side-fallback-2026-07-01", forHTTPHeaderField: "anthropic-beta")
        }
        request.httpBody = try JSONSerialization.data(withJSONObject: body, options: [.sortedKeys])
        return request
    }

    public func extract(_ request: LLMExtractionRequest) async throws -> LLMExtractionResponse {
        guard !apiKey.trimmed().isEmpty else { throw ExtractionProviderError.missingAPIKey }
        let (prompt, _) = LLMPrompt.user(request.document, today: request.today, maxCharacters: request.maxCharacters)
        var options = Options()
        for _ in 0..<3 {
            let urlRequest = try makeRequest(prompt: prompt, options: options)
            let (data, http) = try await transport(urlRequest)
            switch http.statusCode {
            case 200:
                return try AnthropicExtractionProvider.parseMessage(data)
            case 400:
                let message = AnthropicExtractionProvider.errorMessage(data)
                let lower = message.lowercased()
                // Drop optional request features if this account or model does not accept them.
                if options.serverFallbacks && (lower.contains("fallback") || lower.contains("anthropic-beta")) {
                    options.serverFallbacks = false
                    continue
                }
                if options.structuredOutput && (lower.contains("output_config") || lower.contains("format") || lower.contains("schema")) {
                    options.structuredOutput = false
                    continue
                }
                throw ExtractionProviderError.badRequest(message)
            case 401, 403:
                throw ExtractionProviderError.invalidAPIKey
            case 429:
                let retry = http.value(forHTTPHeaderField: "retry-after").flatMap { Int($0) }
                throw ExtractionProviderError.rateLimited(retryAfterSeconds: retry)
            case 529, 503:
                throw ExtractionProviderError.overloaded
            default:
                throw ExtractionProviderError.server(status: http.statusCode, message: AnthropicExtractionProvider.errorMessage(data))
            }
        }
        throw ExtractionProviderError.badRequest("The request was rejected after compatibility retries.")
    }

    static func errorMessage(_ data: Data) -> String {
        if let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let err = obj["error"] as? [String: Any], let msg = err["message"] as? String {
            return msg
        }
        return String(data: data.prefix(300), encoding: .utf8) ?? "Unknown error"
    }

    /// Reads the text blocks of a Messages API response and parses the JSON they contain.
    static func parseMessage(_ data: Data) throws -> LLMExtractionResponse {
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw ExtractionProviderError.invalidResponse("Response was not JSON")
        }
        let stopReason = obj["stop_reason"] as? String
        if stopReason == "refusal" {
            let details = obj["stop_details"] as? [String: Any]
            throw ExtractionProviderError.refused(details?["explanation"] as? String)
        }
        let blocks = obj["content"] as? [[String: Any]] ?? []
        let text = blocks.filter { ($0["type"] as? String) == "text" }.compactMap { $0["text"] as? String }.joined()
        if stopReason == "max_tokens" {
            throw ExtractionProviderError.truncated
        }
        guard !text.trimmed().isEmpty else { throw ExtractionProviderError.invalidResponse("No text in response") }
        return try LLMExtractionResponse.parse(text: text)
    }
}

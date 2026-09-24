import Foundation

/// Result of running extraction over a document.
public struct ExtractionOutcome: Sendable {
    public var fields: [ExtractedFieldDraft]
    /// The provider whose output was used, if any.
    public var providerID: String?
    public var providerName: String?
    /// True if document text was sent off the device.
    public var sentOffDevice: Bool
    /// Problems that did not stop extraction (shown to the user).
    public var warnings: [String]
    public var providerError: ExtractionProviderError?
}

/// Document text → deterministic extraction → optional model extraction →
/// normalisation → source matching → merge → relative date resolution →
/// confidence. Never throws: a failed model call falls back to on-device results.
public struct ExtractionPipeline: Sendable {
    public var deterministic: DeterministicExtractor
    public var provider: (any ExtractionProvider)?

    public init(deterministic: DeterministicExtractor = DeterministicExtractor(), provider: (any ExtractionProvider)? = nil) {
        self.deterministic = deterministic
        self.provider = provider
    }

    public func run(_ document: DocumentText, today: CalendarDate = .today()) async -> ExtractionOutcome {
        var warnings: [String] = []
        guard !document.isEmpty else {
            return ExtractionOutcome(fields: [], providerID: nil, providerName: nil, sentOffDevice: false,
                                     warnings: ["No text could be read from this document. You can still add details manually."], providerError: nil)
        }
        let ruleFields = deterministic.extract(document)
        var modelFields: [ExtractedFieldDraft] = []
        var providerError: ExtractionProviderError?

        if let provider {
            let request = LLMExtractionRequest(document: document, today: today)
            if LLMPrompt.documentBody(document, maxCharacters: request.maxCharacters).truncated {
                warnings.append("The document is long; only the first part was sent for AI extraction.")
            }
            do {
                let response = try await provider.extract(request)
                modelFields = LLMFieldMapper(matcher: SourceMatcher(document: document)).map(response)
            } catch let e as ExtractionProviderError {
                providerError = e
                warnings.append((e.errorDescription ?? "AI extraction failed.") + " Showing on-device results only.")
            } catch {
                providerError = .unavailable(error.localizedDescription)
                warnings.append("AI extraction failed (\(error.localizedDescription)). Showing on-device results only.")
            }
        }

        var fields = FieldMerger.merge(deterministic: ruleFields, llm: modelFields)
        // First pass for confidence so the resolver can prefer trusted dates.
        ConfidenceScorer.apply(&fields)
        RelativeDateResolver.resolve(&fields)
        for i in fields.indices { fields[i].notes = fields[i].notes.filter { !$0.hasPrefix("This date depends on") } }
        ConfidenceScorer.apply(&fields)
        fields.sort { a, b in
            if a.kind != b.kind { return a.kind.sortRank < b.kind.sortRank }
            let da = a.value.primaryDate, db = b.value.primaryDate
            if let da, let db, da != db { return da < db }
            return (a.source?.range.location ?? .max) < (b.source?.range.location ?? .max)
        }
        if fields.isEmpty {
            warnings.append("No details were recognised automatically. You can add them manually.")
        }
        return ExtractionOutcome(fields: fields, providerID: provider?.id, providerName: provider?.displayName,
                                 sentOffDevice: provider?.sendsDataOffDevice == true && providerError != .missingAPIKey,
                                 warnings: warnings, providerError: providerError)
    }
}

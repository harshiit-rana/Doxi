import DoxiCore
import Foundation
#if canImport(FoundationModels)
import FoundationModels
#endif

/// Extraction with Apple's on-device language model (iOS 26+, Apple Intelligence
/// devices). Text never leaves the device. The model's context is small, so the
/// document is processed in page chunks and the answers are merged; every value
/// is still re-located in the document by the pipeline.
enum OnDeviceModel {
    /// Whether the on-device model can be used right now, with a reason if not.
    static var availability: (available: Bool, reason: String) {
        #if canImport(FoundationModels)
        if #available(iOS 26.0, *) {
            switch SystemLanguageModel.default.availability {
            case .available:
                return (true, "Available on this device")
            case .unavailable(let reason):
                return (false, "Unavailable: \(String(describing: reason))")
            }
        }
        #endif
        return (false, "Requires iOS 26 and an Apple Intelligence capable device")
    }

    static func makeProvider() -> (any ExtractionProvider)? {
        #if canImport(FoundationModels)
        if #available(iOS 26.0, *), availability.available {
            return FoundationModelsExtractionProvider()
        }
        #endif
        return nil
    }
}

#if canImport(FoundationModels)
@available(iOS 26.0, *)
struct FoundationModelsExtractionProvider: ExtractionProvider {
    let id = "apple-on-device"
    let displayName = "Apple on-device model"
    let sendsDataOffDevice = false
    /// Characters of document text per request, leaving room for instructions and output.
    let chunkCharacters = 5_000

    func extract(_ request: LLMExtractionRequest) async throws -> LLMExtractionResponse {
        var parts: [LLMExtractionResponse] = []
        for chunk in LLMPrompt.chunks(request.document, maxCharacters: chunkCharacters) {
            let session = LanguageModelSession(instructions: LLMPrompt.system + "\n\n" + LLMPrompt.jsonShapeDescription)
            let (prompt, _) = LLMPrompt.user(chunk, today: request.today, maxCharacters: chunkCharacters + 1_000)
            do {
                let response = try await session.respond(to: prompt)
                parts.append(try LLMExtractionResponse.parse(text: response.content))
            } catch let error as ExtractionProviderError {
                throw error
            } catch {
                throw ExtractionProviderError.unavailable("The on-device model could not process this document (\(error.localizedDescription)).")
            }
        }
        return LLMExtractionResponse.merge(parts)
    }
}
#endif

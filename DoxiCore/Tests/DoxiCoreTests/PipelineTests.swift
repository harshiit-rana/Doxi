import XCTest
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
@testable import DoxiCore

final class PipelineTests: XCTestCase {
    let doc = Fixtures.doc(Fixtures.freelanceContract)

    func response() -> LLMExtractionResponse {
        var r = LLMExtractionResponse()
        r.parties = [
            .init(name: "ABC Technologies Pvt. Ltd.", role: "Client", sourceQuote: "between ABC Technologies Private Limited, a company incorporated", page: 1),
            .init(name: "Harshit Rana", role: "Freelancer", sourceQuote: "and Harshit Rana, residing at New Delhi", page: 1),
        ]
        r.effectiveDate = .init(value: "2026-09-15", sourceQuote: "This Agreement shall be effective from 15 September 2026", page: 1)
        var p1 = LLMExtractionResponse.Payment()
        p1.amount = LooseString("40000"); p1.dueDate = "2026-10-15"; p1.payer = "ABC Technologies"; p1.payee = "Harshit Rana"
        p1.description = "First installment"
        p1.sourceQuote = "The first installment of Rs. 40,000/- shall be paid on 15/10/2026."
        var hallucinated = LLMExtractionResponse.Payment()
        hallucinated.amount = LooseString("15000"); hallucinated.dueDate = "2026-12-01"
        hallucinated.sourceQuote = "A completion bonus of Rs. 15,000 shall be paid on 01/12/2026."
        var wrongValue = LLMExtractionResponse.Payment()
        wrongValue.amount = LooseString("45000"); wrongValue.dueDate = "2026-11-15"
        wrongValue.sourceQuote = "The second installment of Rs. 40,000/- shall be paid on 15/11/2026."
        r.payments = [p1, hallucinated, wrongValue]
        r.endDate = .init(value: "2026-12-31", sourceQuote: "shall remain in force until 15 December 2026", page: 1)
        return r
    }

    func testAgreementRaisesConfidenceAndEnrichesPayerPayee() async {
        let out = await ExtractionPipeline(provider: StubProvider(result: .success(response()))).run(doc)
        let first = out.fields.first { $0.kind == .payment && $0.value.primaryDate?.isoString == "2026-10-15" }
        XCTAssertEqual(first?.origin, .both)
        XCTAssertEqual(first?.confidence, .high)
        if case .payment(let p)? = first?.value {
            XCTAssertEqual(p.payee, "Harshit Rana")
            XCTAssertEqual(p.label, "Installment 1")
        }
        XCTAssertTrue(out.sentOffDevice)
    }

    func testHallucinatedValueIsUnverified() async {
        let out = await ExtractionPipeline(provider: StubProvider(result: .success(response()))).run(doc)
        let bonus = out.fields.first { $0.value.primaryAmount?.minorUnits == 1_500_000 }
        XCTAssertNotNil(bonus)
        XCTAssertNil(bonus?.source)
        XCTAssertEqual(bonus?.confidence, .unverified)
    }

    func testValueNotInQuoteIsLowConfidence() async {
        let out = await ExtractionPipeline(provider: StubProvider(result: .success(response()))).run(doc)
        let wrong = out.fields.first { $0.value.primaryAmount?.minorUnits == 4_500_000 }
        XCTAssertEqual(wrong?.confidence, .unverified == wrong?.confidence ? .unverified : .low)
        XCTAssertLessThanOrEqual(wrong?.confidence ?? .high, .low)
    }

    func testConflictingEndDateIsFlagged() async {
        let out = await ExtractionPipeline(provider: StubProvider(result: .success(response()))).run(doc)
        let ends = out.fields.filter { $0.kind == .endDate }
        XCTAssertEqual(ends.count, 2)
        XCTAssertTrue(ends.allSatisfy { $0.conflictGroup != nil && $0.confidence <= .medium })
    }

    func testProviderFailureFallsBackToOnDevice() async {
        let out = await ExtractionPipeline(provider: StubProvider(result: .failure(.rateLimited(retryAfterSeconds: 20)))).run(doc)
        XCTAssertEqual(out.providerError, .rateLimited(retryAfterSeconds: 20))
        XCTAssertFalse(out.fields.isEmpty)
        XCTAssertTrue(out.warnings.contains { $0.contains("rate limiting") })
        XCTAssertTrue(out.fields.allSatisfy { $0.origin == .deterministic })
    }

    func testEmptyDocument() async {
        let out = await ExtractionPipeline().run(DocumentText(pages: []))
        XCTAssertTrue(out.fields.isEmpty)
        XCTAssertFalse(out.warnings.isEmpty)
    }

    func testRelativeDueDateResolvedFromEffectiveDate() async {
        let text = """
        CONSULTING AGREEMENT
        This Agreement is effective from 01/09/2026.
        An advance of Rs. 20,000 shall be paid within 7 days of the Effective Date.
        """
        let out = await ExtractionPipeline().run(Fixtures.doc(text))
        guard case .payment(let p)? = out.fields.first(where: { $0.kind == .payment })?.value else { return XCTFail("no payment") }
        XCTAssertEqual(p.due?.relative?.baseDate?.isoString, "2026-09-01")
        XCTAssertEqual(p.due?.resolved?.isoString, "2026-09-08")
        XCTAssertTrue(p.due?.formatted.contains("base 01/09/2026") ?? false)
    }

    func testRelativeDateWithoutBaseStaysMediumOrLower() async {
        let text = "An advance of Rs. 20,000 shall be paid within 7 days of signing of this Agreement."
        let out = await ExtractionPipeline().run(Fixtures.doc(text))
        let f = out.fields.first { $0.kind == .payment }
        XCTAssertNil(f?.value.primaryDate)
        XCTAssertLessThanOrEqual(f?.confidence ?? .high, .medium)
    }
}

final class AnthropicProviderTests: XCTestCase {
    func testRequestShape() throws {
        let provider = AnthropicExtractionProvider(apiKey: "test-key")
        let req = try provider.makeRequest(prompt: "hello", options: .init())
        XCTAssertEqual(req.value(forHTTPHeaderField: "x-api-key"), "test-key")
        XCTAssertEqual(req.value(forHTTPHeaderField: "anthropic-version"), "2023-06-01")
        let body = try JSONSerialization.jsonObject(with: req.httpBody!) as! [String: Any]
        XCTAssertEqual(body["model"] as? String, "claude-opus-5")
        let format = (body["output_config"] as? [String: Any])?["format"] as? [String: Any]
        XCTAssertEqual(format?["type"] as? String, "json_schema")
        XCTAssertEqual((body["thinking"] as? [String: Any])?["type"] as? String, "adaptive")
    }

    func testMissingKey() async {
        do {
            _ = try await AnthropicExtractionProvider(apiKey: "  ").extract(LLMExtractionRequest(document: Fixtures.doc("x"), today: .today()))
            XCTFail("expected error")
        } catch let e as ExtractionProviderError {
            XCTAssertEqual(e, .missingAPIKey)
        } catch { XCTFail("\(error)") }
    }

    static func http(_ status: Int, _ json: String, headers: [String: String] = [:]) -> (Data, HTTPURLResponse) {
        (json.data(using: .utf8)!, HTTPURLResponse(url: AnthropicExtractionProvider.endpoint, statusCode: status, httpVersion: nil, headerFields: headers)!)
    }

    func testParsesTextBlockAndSkipsThinking() async throws {
        let payload = #"{"parties":[{"name":"ABC","role":null,"source_quote":"ABC","page":1}],"payments":[],"obligations":[],"clauses":[],"document_type":null,"title":null,"effective_date":null,"end_date":null,"renewal":null,"notice_period":null,"total_amount":{"amount":80000,"currency":"INR","source_quote":"x","page":"1"}}"#
        let escaped = payload.replacingOccurrences(of: "\"", with: "\\\"")
        let body = #"{"content":[{"type":"thinking","thinking":""},{"type":"text","text":"\#(escaped)"}],"stop_reason":"end_turn"}"#
        let provider = AnthropicExtractionProvider(apiKey: "k", transport: { _ in Self.http(200, body) })
        let r = try await provider.extract(LLMExtractionRequest(document: Fixtures.doc("ABC"), today: .today()))
        XCTAssertEqual(r.parties?.first?.name, "ABC")
        XCTAssertEqual(r.totalAmount?.amount?.value, "80000")
    }

    func testErrorMapping() async {
        let cases: [(Int, String, [String: String], ExtractionProviderError)] = [
            (401, #"{"error":{"message":"invalid x-api-key"}}"#, [:], .invalidAPIKey),
            (429, #"{"error":{"message":"rate"}}"#, ["retry-after": "30"], .rateLimited(retryAfterSeconds: 30)),
            (529, #"{"error":{"message":"overloaded"}}"#, [:], .overloaded),
            (200, #"{"content":[],"stop_reason":"refusal","stop_details":{"explanation":"policy"}}"#, [:], .refused("policy")),
            (200, #"{"content":[{"type":"text","text":"{\"parties\": ["}],"stop_reason":"max_tokens"}"#, [:], .truncated),
        ]
        for (status, body, headers, expected) in cases {
            let provider = AnthropicExtractionProvider(apiKey: "k", transport: { _ in Self.http(status, body, headers: headers) })
            do {
                _ = try await provider.extract(LLMExtractionRequest(document: Fixtures.doc("x"), today: .today()))
                XCTFail("expected \(expected)")
            } catch let e as ExtractionProviderError {
                XCTAssertEqual(e, expected)
            } catch { XCTFail("\(error)") }
        }
    }

    func testCompatibilityRetryDropsStructuredOutput() async throws {
        let counter = Counter()
        let ok = #"{"content":[{"type":"text","text":"```json\n{\"parties\": []}\n```"}],"stop_reason":"end_turn"}"#
        let provider = AnthropicExtractionProvider(apiKey: "k", transport: { req in
            let n = counter.increment()
            let body = try JSONSerialization.jsonObject(with: req.httpBody!) as! [String: Any]
            let hasFormat = (body["output_config"] as? [String: Any])?["format"] != nil
            if n == 1 { XCTAssertTrue(hasFormat); return Self.http(400, #"{"error":{"message":"output_config.format: not supported"}}"#) }
            XCTAssertFalse(hasFormat)
            return Self.http(200, ok)
        })
        let r = try await provider.extract(LLMExtractionRequest(document: Fixtures.doc("x"), today: .today()))
        XCTAssertEqual(r.parties?.count, 0)
        XCTAssertEqual(counter.value, 2)
    }

    func testChunkingKeepsPageIndices() {
        let pages = (0..<5).map { i in PageText(index: i, source: .pdfText, lines: [TextLine(text: String(repeating: "a", count: 400), box: .init(x: 0, y: 0, width: 1, height: 1))]) }
        let chunks = LLMPrompt.chunks(DocumentText(pages: pages), maxCharacters: 900)
        XCTAssertEqual(chunks.map { $0.pages.map(\.index) }, [[0, 1], [2, 3], [4]])
    }
}

final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private(set) var value = 0
    func increment() -> Int { lock.lock(); defer { lock.unlock() }; value += 1; return value }
}

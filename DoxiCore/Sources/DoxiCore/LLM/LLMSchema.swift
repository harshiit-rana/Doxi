import Foundation

/// A string that may arrive as a JSON string, number or boolean.
public struct LooseString: Codable, Hashable, Sendable {
    public var value: String

    public init(_ value: String) { self.value = value }

    public init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if let s = try? c.decode(String.self) { value = s }
        else if let i = try? c.decode(Int.self) { value = String(i) }
        else if let d = try? c.decode(Double.self) { value = String(d) }
        else if let b = try? c.decode(Bool.self) { value = String(b) }
        else { throw DecodingError.typeMismatch(String.self, .init(codingPath: decoder.codingPath, debugDescription: "Expected string-like value")) }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        try c.encode(value)
    }
}

/// The JSON structure requested from language models. Every item carries a
/// verbatim `source_quote` so it can be located and verified in the document.
public struct LLMExtractionResponse: Codable, Hashable, Sendable {
    public struct Sourced: Codable, Hashable, Sendable {
        public var value: LooseString?
        public var sourceQuote: String?
        public var page: LooseString?
        public init(value: String?, sourceQuote: String?, page: Int?) {
            self.value = value.map(LooseString.init); self.sourceQuote = sourceQuote; self.page = page.map { LooseString(String($0)) }
        }
    }

    public struct Party: Codable, Hashable, Sendable {
        public var name: String
        public var role: String?
        public var sourceQuote: String?
        public var page: LooseString?
        public init(name: String, role: String?, sourceQuote: String?, page: Int?) {
            self.name = name; self.role = role; self.sourceQuote = sourceQuote; self.page = page.map { LooseString(String($0)) }
        }
    }

    public struct Renewal: Codable, Hashable, Sendable {
        public var automatic: Bool?
        public var renewalTerm: String?
        public var summary: String?
        public var sourceQuote: String?
        public var page: LooseString?
    }

    public struct Amount: Codable, Hashable, Sendable {
        public var amount: LooseString?
        public var currency: String?
        public var sourceQuote: String?
        public var page: LooseString?
    }

    public struct Payment: Codable, Hashable, Sendable {
        public var amount: LooseString?
        public var currency: String?
        public var dueDate: String?
        public var dueDateText: String?
        public var payer: String?
        public var payee: String?
        public var recurrence: String?
        public var description: String?
        public var sourceQuote: String?
        public var page: LooseString?
    }

    public struct Obligation: Codable, Hashable, Sendable {
        public var description: String
        public var responsibleParty: String?
        public var dueDate: String?
        public var dueDateText: String?
        public var recurrence: String?
        public var category: String?
        public var sourceQuote: String?
        public var page: LooseString?
    }

    public struct Clause: Codable, Hashable, Sendable {
        public var category: String
        public var summary: String?
        public var sourceQuote: String?
        public var page: LooseString?
    }

    public var documentType: Sourced?
    public var title: Sourced?
    public var parties: [Party]?
    public var effectiveDate: Sourced?
    public var endDate: Sourced?
    public var renewal: Renewal?
    public var noticePeriod: Sourced?
    public var totalAmount: Amount?
    public var payments: [Payment]?
    public var obligations: [Obligation]?
    public var clauses: [Clause]?

    public init() {}

    public static func decode(_ data: Data) throws -> LLMExtractionResponse {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return try decoder.decode(LLMExtractionResponse.self, from: data)
    }

    /// Parses model text that should contain a JSON object, tolerating code fences
    /// and prose around it.
    public static func parse(text: String) throws -> LLMExtractionResponse {
        var s = text.trimmed()
        if let start = s.firstIndex(of: "{"), let end = s.lastIndex(of: "}"), start < end {
            s = String(s[start...end])
        }
        guard let data = s.data(using: .utf8) else { throw ExtractionProviderError.invalidResponse("Empty response") }
        do {
            return try decode(data)
        } catch {
            throw ExtractionProviderError.invalidResponse("Not valid extraction JSON (\(error.localizedDescription))")
        }
    }

    /// Combines responses from several chunks of one document (used by small
    /// on-device models that cannot read the whole document at once).
    public static func merge(_ parts: [LLMExtractionResponse]) -> LLMExtractionResponse {
        var out = LLMExtractionResponse()
        for p in parts {
            out.documentType = out.documentType ?? p.documentType
            out.title = out.title ?? p.title
            out.effectiveDate = out.effectiveDate ?? p.effectiveDate
            out.endDate = out.endDate ?? p.endDate
            out.renewal = out.renewal ?? p.renewal
            out.noticePeriod = out.noticePeriod ?? p.noticePeriod
            out.totalAmount = out.totalAmount ?? p.totalAmount
            out.parties = (out.parties ?? []) + (p.parties ?? [])
            out.payments = (out.payments ?? []) + (p.payments ?? [])
            out.obligations = (out.obligations ?? []) + (p.obligations ?? [])
            out.clauses = (out.clauses ?? []) + (p.clauses ?? [])
        }
        return out
    }
}

/// Builds the prompt and JSON schema shared by all model providers.
public enum LLMPrompt {
    public static let system = """
    You extract facts from business documents (contracts, NDAs, invoices, quotations, rent and vendor agreements) \
    for freelancers and small businesses in India.

    Rules:
    - Report only information that is explicitly written in the document. Never guess or infer missing values; use null.
    - For every item, source_quote must be copied verbatim from the document text (8 to 40 words) and must contain the value. \
    Do not paraphrase, correct spelling, or join text from different places in source_quote.
    - page is the page number shown in the <page number="N"> tag that contains the quote.
    - Keep date roles distinct: effective_date is when the agreement or document takes effect (for invoices and letters, the \
    document's own date); end_date is when it expires or ends. Signing dates, dates of other referenced documents and example \
    dates are not effective, end or due dates.
    - Dates: the document uses the Indian DD/MM/YYYY convention unless it clearly states otherwise. Put a calendar date in \
    due_date / value as YYYY-MM-DD only when the document states that specific date. If a date is relative \
    (for example "within 30 days of signing"), set due_date to null and copy the phrase into due_date_text.
    - Amounts: give the number only (for example "80000" or "150000.50"); lakh and crore must be converted to the full number. \
    Currency as an ISO code such as INR.
    - payments: every individual payment, instalment, advance, recurring fee or rent, with its own amount and due date. \
    Do not list the total contract value as a payment unless it is payable in one go. Do not list amounts that were already \
    paid or received, penalties, late fees, interest, or amounts used as examples. payer and payee are the party names \
    as written in the document, or null if the document does not say.
    - obligations: non-payment duties with a date or deadline (deliverables, submissions, returns). Payments go in payments.
    - clauses: categories payment, renewal, termination, notice, confidentiality, deliverables, penalties, deadlines. \
    summary is a short neutral description of what the clause says. Do not give legal advice or opinions.
    - notice_period value is a duration such as "30 days".
    - renewal.automatic is true only if the document says the agreement renews automatically, false if renewal requires \
    agreement or is excluded, and null if unclear.
    """

    /// The document text wrapped in page tags.
    public static func documentBody(_ doc: DocumentText, maxCharacters: Int) -> (body: String, truncated: Bool) {
        var body = ""
        var truncated = false
        for page in doc.pages {
            let chunk = "<page number=\"\(page.index + 1)\">\n\(page.text)\n</page>\n"
            if body.count + chunk.count > maxCharacters {
                truncated = true
                break
            }
            body += chunk
        }
        return (body, truncated)
    }

    public static func user(_ doc: DocumentText, today: CalendarDate, maxCharacters: Int) -> (prompt: String, truncated: Bool) {
        let (body, truncated) = documentBody(doc, maxCharacters: maxCharacters)
        let prompt = """
        Today's date is \(today.isoString). Extract the facts from this document as JSON.

        <document>
        \(body)</document>
        """
        return (prompt, truncated)
    }

    /// Splits a document into page groups of at most `maxCharacters` each.
    public static func chunks(_ doc: DocumentText, maxCharacters: Int) -> [DocumentText] {
        var out: [DocumentText] = []
        var current: [PageText] = []
        var size = 0
        for page in doc.pages {
            let len = page.text.count
            if !current.isEmpty && size + len > maxCharacters {
                out.append(DocumentText(pages: current))
                current = []
                size = 0
            }
            if len > maxCharacters {
                // Split an oversized page by lines, keeping the page index.
                var lines: [TextLine] = []
                var lineSize = 0
                for line in page.lines {
                    if lineSize + line.text.count > maxCharacters && !lines.isEmpty {
                        out.append(DocumentText(pages: [PageText(index: page.index, source: page.source, lines: lines)]))
                        lines = []
                        lineSize = 0
                    }
                    lines.append(line)
                    lineSize += line.text.count + 1
                }
                if !lines.isEmpty { out.append(DocumentText(pages: [PageText(index: page.index, source: page.source, lines: lines)])) }
                continue
            }
            current.append(page)
            size += len
        }
        if !current.isEmpty { out.append(DocumentText(pages: current)) }
        return out
    }

    // MARK: JSON schema (strict structured output)

    private static func nullable(_ type: String) -> [String: Any] {
        ["anyOf": [["type": type], ["type": "null"]]]
    }

    private static func object(_ properties: [String: Any]) -> [String: Any] {
        ["type": "object", "properties": properties, "required": Array(properties.keys).sorted(), "additionalProperties": false]
    }

    private static func nullableObject(_ properties: [String: Any]) -> [String: Any] {
        ["anyOf": [object(properties), ["type": "null"]]]
    }

    private static var sourced: [String: Any] {
        nullableObject(["value": nullable("string"), "source_quote": nullable("string"), "page": nullable("integer")])
    }

    public static var jsonSchema: [String: Any] {
        let party = object(["name": ["type": "string"], "role": nullable("string"), "source_quote": nullable("string"), "page": nullable("integer")])
        let payment = object([
            "amount": nullable("string"), "currency": nullable("string"), "due_date": nullable("string"), "due_date_text": nullable("string"),
            "payer": nullable("string"), "payee": nullable("string"), "recurrence": nullable("string"), "description": nullable("string"),
            "source_quote": nullable("string"), "page": nullable("integer"),
        ])
        let obligation = object([
            "description": ["type": "string"], "responsible_party": nullable("string"), "due_date": nullable("string"),
            "due_date_text": nullable("string"), "recurrence": nullable("string"), "category": nullable("string"),
            "source_quote": nullable("string"), "page": nullable("integer"),
        ])
        let clause = object(["category": ["type": "string"], "summary": nullable("string"), "source_quote": nullable("string"), "page": nullable("integer")])
        return object([
            "document_type": sourced,
            "title": sourced,
            "parties": ["type": "array", "items": party],
            "effective_date": sourced,
            "end_date": sourced,
            "renewal": nullableObject(["automatic": nullable("boolean"), "renewal_term": nullable("string"), "summary": nullable("string"),
                                       "source_quote": nullable("string"), "page": nullable("integer")]),
            "notice_period": sourced,
            "total_amount": nullableObject(["amount": nullable("string"), "currency": nullable("string"), "source_quote": nullable("string"), "page": nullable("integer")]),
            "payments": ["type": "array", "items": payment],
            "obligations": ["type": "array", "items": obligation],
            "clauses": ["type": "array", "items": clause],
        ])
    }

    /// A compact description of the expected JSON for models without schema support.
    public static let jsonShapeDescription = """
    Respond with only a JSON object of this shape (use null for anything not in the document):
    {"document_type": {"value": "freelance_agreement|service_agreement|contract|nda|invoice|quotation|vendor_agreement|rental_agreement|purchase_order|business_letter|other", "source_quote": "...", "page": 1},
     "title": {"value": "...", "source_quote": "...", "page": 1},
     "parties": [{"name": "...", "role": "Client", "source_quote": "...", "page": 1}],
     "effective_date": {"value": "YYYY-MM-DD", "source_quote": "...", "page": 1},
     "end_date": {"value": "YYYY-MM-DD", "source_quote": "...", "page": 1},
     "renewal": {"automatic": true, "renewal_term": "1 year", "summary": "...", "source_quote": "...", "page": 1},
     "notice_period": {"value": "30 days", "source_quote": "...", "page": 1},
     "total_amount": {"amount": "80000", "currency": "INR", "source_quote": "...", "page": 1},
     "payments": [{"amount": "40000", "currency": "INR", "due_date": "YYYY-MM-DD", "due_date_text": null, "payer": "...", "payee": "...", "recurrence": null, "description": "First installment", "source_quote": "...", "page": 1}],
     "obligations": [{"description": "...", "responsible_party": "...", "due_date": "YYYY-MM-DD", "due_date_text": null, "recurrence": null, "category": "deliverable", "source_quote": "...", "page": 1}],
     "clauses": [{"category": "termination", "summary": "...", "source_quote": "...", "page": 1}]}
    """
}

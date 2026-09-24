import Foundation
@testable import DoxiCore

/// Small inline documents for unit tests. Evaluation documents live in
/// Evaluation/datasets and are not used by unit tests.
enum Fixtures {
    static let freelanceContract = """
    FREELANCE SERVICES AGREEMENT

    This Agreement is made on 10/09/2026 between ABC Technologies Private Limited, a company incorporated under the Companies Act, 2013 (hereinafter referred to as the "Client") and Harshit Rana, residing at New Delhi (hereinafter referred to as the "Freelancer").

    1. Term
    This Agreement shall be effective from 15 September 2026 and shall remain in force until 15 December 2026.

    2. Fees
    The total project fee shall be INR 80,000 (Rupees Eighty Thousand Only).
    The first installment of Rs. 40,000/- shall be paid on 15/10/2026.
    The second installment of Rs. 40,000/- shall be paid on 15/11/2026.

    3. Termination
    Either party may terminate this Agreement by giving thirty (30) days' prior written notice.

    4. Renewal
    This Agreement shall automatically renew for successive periods of one (1) year unless either party gives notice.
    """

    static let rentAgreement = """
    RENT AGREEMENT
    This Rent Agreement is executed on 01/04/2026 between Mr. Suresh Kumar (hereinafter called the "Landlord") and Rana Digital Studio (hereinafter called the "Tenant").
    The tenancy shall commence on 1st April 2026 for a period of 11 months.
    The Tenant shall pay a monthly rent of Rs. 25,000/- on or before the 5th day of each month.
    """

    static let invoice = """
    TAX INVOICE
    Rana Digital Studio
    GSTIN: 07ABCPR1234K1Z2
    Invoice No: RDS/2026/014
    Invoice Date: 01/10/2026
    Due Date: 31/10/2026
    Bill To:
    XYZ Agency LLP
    Website maintenance - October          25,000.00
    Sub Total                               25,000.00
    IGST @ 18%                               4,500.00
    Grand Total                          ₹ 29,500.00
    """

    static func doc(_ s: String) -> DocumentText { DocumentText(plainText: s) }

    static func field(_ fields: [ExtractedFieldDraft], _ kind: FieldKind) -> ExtractedFieldDraft? {
        fields.first { $0.kind == kind }
    }
}

/// A provider returning a fixed response, for pipeline tests.
struct StubProvider: ExtractionProvider {
    var id = "stub"
    var displayName = "Stub"
    var sendsDataOffDevice = true
    var result: Result<LLMExtractionResponse, ExtractionProviderError>

    func extract(_ request: LLMExtractionRequest) async throws -> LLMExtractionResponse {
        try result.get()
    }
}

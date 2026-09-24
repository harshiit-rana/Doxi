import XCTest
@testable import DoxiCore

final class AmountParserTests: XCTestCase {
    private func amounts(_ s: String) -> [Int64] { AmountParser.mentions(in: s).map { $0.money.minorUnits / 100 } }

    func testRupeeSymbolWithIndianGrouping() {
        XCTAssertEqual(amounts("Total fee of ₹1,20,000 payable"), [120_000])
        XCTAssertEqual(amounts("₹ 80,000"), [80_000])
    }

    func testRsAndINRPrefixes() {
        XCTAssertEqual(amounts("Rs. 80,000/- only"), [80_000])
        XCTAssertEqual(amounts("Rs 40000"), [40_000])
        XCTAssertEqual(amounts("INR 80,000.50"), [80_000])
        XCTAssertEqual(AmountParser.mentions(in: "INR 80,000.50").first?.money.minorUnits, 8_000_050)
        XCTAssertEqual(amounts("an amount of INR80000"), [80_000])
    }

    func testLakhAndCrore() {
        XCTAssertEqual(amounts("Rs. 1.5 lakh"), [150_000])
        XCTAssertEqual(amounts("₹2 crore"), [20_000_000])
        XCTAssertEqual(amounts("INR 3 lakhs"), [300_000])
        XCTAssertEqual(amounts("Rs 2.5 Cr."), [25_000_000])
    }

    func testSuffixForms() {
        XCTAssertEqual(amounts("a sum of 80,000/- to be paid"), [80_000])
        XCTAssertEqual(amounts("pay 25000 rupees monthly"), [25_000])
    }

    func testAmountInWords() {
        XCTAssertEqual(amounts("(Rupees Eighty Thousand Only)"), [80_000])
        XCTAssertEqual(amounts("Rupees One Lakh Twenty Thousand only"), [120_000])
        XCTAssertEqual(amounts("forty thousand rupees"), [40_000])
        XCTAssertEqual(amounts("Rs. Two Crore Fifty Lakh"), [25_000_000])
    }

    func testNumberAndWordsTogetherAreSeparateMentions() {
        XCTAssertEqual(amounts("₹80,000 (Rupees Eighty Thousand Only)"), [80_000, 80_000])
    }

    func testDoesNotMatchInsideWordsOrPlainNumbers() {
        XCTAssertEqual(amounts("within 30 hours"), [])
        XCTAssertEqual(amounts("Clause 12 of 2026"), [])
        XCTAssertEqual(amounts("often rupees"), [])
        XCTAssertEqual(amounts("Contact: 9876543210"), [])
    }

    func testOtherCurrencies() {
        XCTAssertEqual(AmountParser.mentions(in: "USD 1,500").first?.money.currency, "USD")
        XCTAssertEqual(AmountParser.mentions(in: "$2,000").first?.money, Money(minorUnits: 200_000, currency: "USD"))
    }

    func testLooseParsing() {
        XCTAssertEqual(AmountParser.parseLoose("80000"), Money(minorUnits: 8_000_000))
        XCTAssertEqual(AmountParser.parseLoose("80,000"), Money(minorUnits: 8_000_000))
        XCTAssertEqual(AmountParser.parseLoose("₹80,000"), Money(minorUnits: 8_000_000))
        XCTAssertEqual(AmountParser.parseLoose("80k"), Money(minorUnits: 8_000_000))
        XCTAssertEqual(AmountParser.parseLoose("0.8 lakh"), Money(minorUnits: 8_000_000))
        XCTAssertEqual(AmountParser.parseLoose("eighty thousand"), Money(minorUnits: 8_000_000))
        XCTAssertNil(AmountParser.parseLoose("ABC Technologies"))
    }

    func testIndianFormatting() {
        XCTAssertEqual(Money(minorUnits: 8_000_000).formatted, "₹80,000")
        XCTAssertEqual(Money(minorUnits: 12_000_000).formatted, "₹1,20,000")
        XCTAssertEqual(Money(minorUnits: 1_234_567_850).formatted, "₹1,23,45,678.50")
        XCTAssertEqual(Money(minorUnits: 150_000_000, currency: "USD").formatted, "$1,500,000")
    }
}

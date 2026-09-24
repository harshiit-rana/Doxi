import XCTest
@testable import DoxiCore

final class IdentifierTests: XCTestCase {
    func testGSTINAndPAN() {
        let found = IdentifierDetector.mentions(in: "GSTIN: 27AAPFU0939F1ZV, PAN: ABCPR1234K")
        XCTAssertEqual(found.map(\.value.type), [.gstin, .pan])
        XCTAssertEqual(found.first?.value.value, "27AAPFU0939F1ZV")
    }

    func testPANInsideGSTINIsNotDoubleCounted() {
        let found = IdentifierDetector.mentions(in: "29ABCPR1234K1Z5")
        XCTAssertEqual(found.map(\.value.type), [.gstin])
    }

    func testAadhaarRequiresValidChecksumAndIsMasked() {
        // 2345 6789 0124 fails Verhoeff; generate a valid one.
        let base = "23456789012"
        let valid = (0...9).map { base + String($0) }.first(where: IdentifierDetector.verhoeffValid)!
        let spaced = "\(valid.prefix(4)) \(valid.dropFirst(4).prefix(4)) \(valid.suffix(4))"
        let found = IdentifierDetector.mentions(in: "Aadhaar No: \(spaced)")
        XCTAssertEqual(found.first?.value.type, .aadhaar)
        XCTAssertEqual(found.first?.value.value, "XXXX XXXX \(valid.suffix(4))")

        let invalid = (0...9).map { base + String($0) }.first(where: { !IdentifierDetector.verhoeffValid($0) })!
        XCTAssertTrue(IdentifierDetector.mentions(in: invalid).isEmpty)
    }
}

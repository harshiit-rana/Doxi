import XCTest
@testable import DoxiCore

final class PartyMatcherTests: XCTestCase {
    let profile = IdentityProfile(name: "Harshit Rana", businessName: "Rana Digital Studio", aliases: ["Harshit", "Rana Digital"])

    func testMatchesNameAndBusiness() {
        XCTAssertEqual(PartyMatcher.match(parties: ["ABC Technologies Pvt Ltd", "Harshit Rana"], profile: profile),
                       .matched(index: 1, score: 1, matchedName: "Harshit Rana"))
        if case .matched(let i, _, _) = PartyMatcher.match(parties: ["M/s. Rana Digital Studio", "XYZ Agency LLP"], profile: profile) {
            XCTAssertEqual(i, 0)
        } else { XCTFail() }
    }

    func testCompanySuffixesAndHonorificsIgnored() {
        XCTAssertEqual(PartyMatcher.similarity("ABC Technologies Private Limited", "ABC Technologies Pvt. Ltd."), 1)
        XCTAssertEqual(PartyMatcher.similarity("Mr. Harshit Rana", "Harshit Rana"), 1)
    }

    func testOCRTypoTolerated() {
        XCTAssertGreaterThanOrEqual(PartyMatcher.similarity("Harshlt Rana", "Harshit Rana"), PartyMatcher.matchThreshold)
    }

    // Scenarios from the Phase 1 validation plan.
    let planProfile = IdentityProfile(name: "Harshit Rana", businessName: "Rana Digital", aliases: ["Harshit"])

    func testPlanClearMatch() {
        XCTAssertEqual(PartyMatcher.match(parties: ["ABC Technologies", "Harshit Rana"], profile: planProfile),
                       .matched(index: 1, score: 1, matchedName: "Harshit Rana"))
    }

    func testPlanBusinessAliasMatch() {
        guard case .matched(let i, _, let name) = PartyMatcher.match(parties: ["Rana Digital", "ABC Technologies"], profile: planProfile) else {
            return XCTFail("expected a match")
        }
        XCTAssertEqual(i, 0)
        XCTAssertEqual(name, "Rana Digital")
        if case .matched = PartyMatcher.match(parties: ["M/s Rana Digital Studio", "ABC Technologies"], profile: planProfile) {} else { XCTFail() }
    }

    func testPlanSurnameOnlyIsAmbiguous() {
        XCTAssertEqual(PartyMatcher.match(parties: ["Rana", "ABC Technologies"], profile: planProfile), .ambiguous(candidates: [0]))
    }

    func testFirstNameShareIsNotAMatch() {
        // Another Harshit is not the user.
        let outcome = PartyMatcher.match(parties: ["Harshit Mehta", "ABC Technologies"], profile: planProfile)
        XCTAssertEqual(outcome, .ambiguous(candidates: [0]))
    }

    func testPlanNoMatch() {
        XCTAssertEqual(PartyMatcher.match(parties: ["ABC Technologies", "XYZ Agency"], profile: planProfile), .noMatch)
    }

    func testNoMatchAsksUser() {
        XCTAssertEqual(PartyMatcher.match(parties: ["ABC Technologies", "XYZ Agency"], profile: profile), .noMatch)
    }

    func testAmbiguousWhenTwoPartiesLookLikeUser() {
        let outcome = PartyMatcher.match(parties: ["Rana Digital Studio", "Harshit Rana"], profile: profile)
        XCTAssertEqual(outcome, .ambiguous(candidates: [0, 1]))
    }

    func testEmptyProfileNeverMatches() {
        XCTAssertEqual(PartyMatcher.match(parties: ["Harshit Rana"], profile: IdentityProfile(name: "")), .noMatch)
    }

    func testDirectionFromPayerPayee() {
        let parties = [DirectionResolver.Party(name: "ABC Technologies", role: "Client"), DirectionResolver.Party(name: "Harshit Rana", role: "Freelancer")]
        XCTAssertEqual(DirectionResolver.resolve(payer: "ABC Technologies", payee: "Harshit Rana", userParty: "Harshit Rana", userIsNeither: false, parties: parties).direction, .owedToMe)
        XCTAssertEqual(DirectionResolver.resolve(payer: "Harshit Rana", payee: nil, userParty: "Harshit Rana", userIsNeither: false, parties: parties).direction, .iOwe)
    }

    func testDirectionFromRoleWhenPayerUnknown() {
        let parties = [DirectionResolver.Party(name: "Suresh Kumar", role: "Landlord"), DirectionResolver.Party(name: "Rana Digital Studio", role: "Tenant")]
        let r = DirectionResolver.resolve(payer: nil, payee: nil, userParty: "Rana Digital Studio", userIsNeither: false, parties: parties)
        XCTAssertEqual(r.direction, .iOwe)
    }

    func testDirectionUnknownWithoutUserParty() {
        XCTAssertEqual(DirectionResolver.resolve(payer: "A", payee: "B", userParty: nil, userIsNeither: false, parties: []).direction, .unknown)
        XCTAssertEqual(DirectionResolver.resolve(payer: "A", payee: "B", userParty: nil, userIsNeither: true, parties: []).direction, .notMine)
    }
}

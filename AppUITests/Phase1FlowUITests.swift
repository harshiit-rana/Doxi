import XCTest

/// Drives the real app in the simulator through the Phase 1 workflow using two
/// generated documents (a text PDF contract and an image-only scanned invoice):
/// onboarding → processing (PDF text + Vision OCR) → review → confirm → reminders →
/// dashboard money → search → open document → source highlight.
final class Phase1FlowUITests: XCTestCase {
    var app: XCUIApplication!

    override func setUp() {
        continueAfterFailure = false
        app = XCUIApplication()
        app.launchArguments = ["-uitest", "-uitest-seed"]
        app.launch()
    }

    func element(containing text: String) -> XCUIElement {
        app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS[c] %@", text)).firstMatch
    }

    func waitFor(_ e: XCUIElement, _ timeout: TimeInterval = 20, _ message: String) {
        XCTAssertTrue(e.waitForExistence(timeout: timeout), message)
    }

    /// Accepts the system notification permission alert if it appears.
    func allowNotificationsIfAsked() {
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        let allow = springboard.buttons["Allow"]
        if allow.waitForExistence(timeout: 8) { allow.tap() }
    }

    func testEndToEndWorkflow() throws {
        // Onboarding: identity profile.
        let name = app.textFields["Your name"]
        waitFor(name, 20, "onboarding should ask for the user's name")
        name.tap()
        name.typeText("Harshit Rana")
        app.buttons["Continue"].tap()

        // Both documents are processed (the scan needs OCR) and wait for review.
        waitFor(element(containing: "need review"), 180, "both documents should reach review")

        // Open the contract from the Documents tab; its title comes from extraction.
        app.tabBars.buttons["Documents"].tap()
        let contract = element(containing: "ABC Technologies")
        waitFor(contract, 30, "contract title should name the counterparty")
        contract.tap()

        // Tapping an extracted value opens the original with the source.
        let fee = element(containing: "₹80,000")
        waitFor(fee, 10, "total amount should be shown")
        fee.tap()
        waitFor(element(containing: "Exact text"), 10, "source sheet should show the exact source text")
        app.buttons["Done"].tap()

        // Review: accept high-confidence details and confirm.
        app.buttons["reviewLink"].tap()
        waitFor(element(containing: "Who are you"), 10, "identity question shown")
        let accept = app.buttons["acceptHighConfidence"]
        waitFor(accept, 10, "high-confidence details can be accepted together")
        accept.tap()
        app.buttons["confirmAndTrack"].tap()
        let finishAlert = app.alerts.buttons["Confirm and track"]
        if finishAlert.waitForExistence(timeout: 5) { finishAlert.tap() }
        allowNotificationsIfAsked()

        // Dashboard: money owed to the user from the two confirmed installments.
        app.tabBars.buttons["Home"].tap()
        let owed = app.descendants(matching: .any)["owedToMe"]
        waitFor(owed, 20, "money section should appear")
        XCTAssertTrue(owed.label.contains("80,000"), "owed to me should total both installments, got: \(owed.label)")
        waitFor(element(containing: "40,000"), 10, "upcoming installment listed")

        // Reminders were scheduled for the confirmed obligations.
        app.tabBars.buttons["Settings"].tap()
        let scheduled = app.descendants(matching: .any)["scheduledReminders"]
        if scheduled.waitForExistence(timeout: 10) {
            XCTAssertFalse(scheduled.label.hasSuffix(" 0"), "reminders should be scheduled: \(scheduled.label)")
        }

        // Search finds the OCR-only document by a phrase that only exists in its scan.
        app.tabBars.buttons["Search"].tap()
        let field = app.searchFields.firstMatch
        waitFor(field, 10, "search field")
        field.tap()
        field.typeText("Greenleaf")
        let hit = element(containing: "Invoice")
        waitFor(hit, 15, "OCR text of the scanned invoice should be searchable")
        hit.tap()
        waitFor(element(containing: "View original document"), 10, "search result opens the document")

        // Amount search finds the contract.
        app.navigationBars.buttons.firstMatch.tap()
        field.tap()
        field.buttons["Clear text"].tap()
        field.typeText("80,000")
        waitFor(element(containing: "ABC Technologies"), 15, "amount search finds the contract")
    }
}

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
        XCTAssertTrue(e.waitForExistence(timeout: timeout), message + "\n" + app.debugDescription.prefix(4000))
    }

    /// Lists render rows lazily; scroll until the element exists and sits in the middle
    /// of the screen (not under the navigation or tab bar).
    func scrollTo(_ e: XCUIElement, _ message: String, maxSwipes: Int = 10) {
        let height = app.windows.firstMatch.frame.height
        func wellPlaced() -> Bool {
            guard e.exists, e.isHittable else { return false }
            let f = e.frame
            return f.minY > height * 0.15 && f.maxY < height * 0.75
        }
        var swipes = 0
        while !wellPlaced() && swipes < maxSwipes {
            if e.exists && e.frame.minY < height * 0.15 {
                app.swipeDown(velocity: .slow)
            } else {
                app.swipeUp(velocity: .slow)
            }
            swipes += 1
        }
        XCTAssertTrue(e.exists, message + "\n" + app.debugDescription.prefix(4000))
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
        waitFor(app.buttons["reviewLink"], 15, "detail screen should offer review")
        let fee = element(containing: "₹80,000")
        scrollTo(fee, "total amount should be shown")
        fee.tap()
        waitFor(app.navigationBars["Total amount"], 10, "source view for the tapped field should open")
        XCTAssertTrue(element(containing: "The total project fee shall be INR 80,000").exists, "sheet shows the source quote")
        let how = ["Exact text", "Found in scanned text"].contains { element(containing: $0).exists }
        XCTAssertTrue(how, "sheet says how the source was matched")
        app.navigationBars["Total amount"].buttons.firstMatch.tap()

        // Review: accept high-confidence details and confirm.
        let review = app.buttons["reviewLink"]
        for _ in 0..<8 where !(review.exists && review.isHittable) { app.swipeDown() }
        review.tap()
        waitFor(element(containing: "Who are you"), 10, "identity question shown")
        XCTAssertTrue(element(containing: "Matched to your profile").exists,
                      "documents imported before onboarding must be matched once the profile exists")
        // Soft check: a quote inside a review row opens the source (buttons in list rows).
        continueAfterFailure = true
        let quote = element(containing: "The first installment")
        if quote.waitForExistence(timeout: 5) {
            quote.tap()
            let opened = app.navigationBars["Payment"].waitForExistence(timeout: 5)
            XCTAssertTrue(opened, "tapping a quote in Review should open its source")
            if opened { app.navigationBars["Payment"].buttons.firstMatch.tap() }
        }
        continueAfterFailure = false

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
        scrollTo(owed, "money section should appear")
        XCTAssertTrue(owed.label.contains("80,000"), "owed to me should total both installments, got: \(owed.label)")
        for _ in 0..<8 { app.swipeDown() }
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

        // The contract is a text PDF: its text must come from the PDF, not OCR.
        element(containing: "ABC Technologies").tap()
        let textSource = element(containing: "PDF text")
        scrollTo(textSource, "a text PDF should be read from its embedded text")
    }
}

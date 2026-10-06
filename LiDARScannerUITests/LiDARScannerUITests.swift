import XCTest

/// UI tests run with `-ui-testing`, which swaps in an in-memory database,
/// in-memory secrets and fixed capability reporting (see
/// `AppContainer.uiTesting`). They cover navigation and non-hardware flows;
/// LiDAR capture itself must be verified on a physical device
/// (see Docs/TESTING.md for the manual device test plan).
final class LiDARScannerUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    private func launch(capabilities: String = "full") -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-ui-testing"]
        app.launchEnvironment["UITEST_CAPABILITIES"] = capabilities
        app.launch()
        return app
    }

    private func passOnboardingAndCompatibility(_ app: XCUIApplication) {
        let skip = app.buttons["onboarding.skip"]
        XCTAssertTrue(skip.waitForExistence(timeout: 5))
        skip.tap()
        let continueButton = app.buttons["compatibility.continue"]
        XCTAssertTrue(continueButton.waitForExistence(timeout: 5))
        continueButton.tap()
    }

    func testFirstLaunchToHomeAsLocalUser() {
        let app = launch()
        passOnboardingAndCompatibility(app)

        let local = app.buttons["login.continueLocally"]
        XCTAssertTrue(local.waitForExistence(timeout: 5))
        local.tap()

        XCTAssertTrue(app.buttons["home.newScan"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.otherElements["home.empty"].exists || app.staticTexts["No Scans Yet"].exists)
    }

    func testRegisterAccount() {
        let app = launch()
        passOnboardingAndCompatibility(app)

        app.buttons["login.createAccount"].tap()
        let name = app.textFields["register.name"]
        XCTAssertTrue(name.waitForExistence(timeout: 5))
        name.tap()
        name.typeText("Ada")
        app.textFields["register.email"].tap()
        app.textFields["register.email"].typeText("ada@example.com")
        app.secureTextFields["register.password"].tap()
        app.secureTextFields["register.password"].typeText("lovelace1")
        app.secureTextFields["register.confirm"].tap()
        app.secureTextFields["register.confirm"].typeText("lovelace1")
        app.buttons["register.submit"].tap()

        XCTAssertTrue(app.buttons["home.newScan"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts["Hello, Ada"].exists)
    }

    func testNewScanFlowReachesInstructions() {
        let app = launch()
        passOnboardingAndCompatibility(app)
        app.buttons["login.continueLocally"].tap()

        app.buttons["home.newScan"].tap()
        let next = app.buttons["newScan.next"]
        XCTAssertTrue(next.waitForExistence(timeout: 5))
        next.tap()

        let objectMode = app.buttons["mode.object"]
        XCTAssertTrue(objectMode.waitForExistence(timeout: 5))
        objectMode.tap()
        XCTAssertTrue(app.buttons["instructions.start"].waitForExistence(timeout: 5))
    }

    func testUnsupportedDeviceDisablesScanning() {
        let app = launch(capabilities: "none")
        passOnboardingAndCompatibility(app)
        app.buttons["login.continueLocally"].tap()

        let newScan = app.buttons["home.newScan"]
        XCTAssertTrue(newScan.waitForExistence(timeout: 5))
        XCTAssertFalse(newScan.isEnabled)
    }

    func testHistoryEmptyState() {
        let app = launch()
        passOnboardingAndCompatibility(app)
        app.buttons["login.continueLocally"].tap()
        app.buttons["home.viewAll"].tap()
        XCTAssertTrue(app.navigationBars["Scan History"].waitForExistence(timeout: 5))
    }
}

import XCTest

/// Smoke tests that the app launches and its four tabs are reachable.
///
/// Deliberately shallow. UI tests are slow and brittle, and the logic worth testing thoroughly
/// already is — in TallyCore, on any platform, in milliseconds. What only a UI test can tell us
/// is that the thing launches and its navigation is wired up, so that is all these do.
final class TallyUITests: XCTestCase {
    override func setUp() {
        super.setUp()
        continueAfterFailure = false
    }

    private func launch() -> XCUIApplication {
        let app = XCUIApplication()
        // Read by the app to use in-memory stores and a stub parser, so a UI test never touches
        // the real database or the network.
        app.launchArguments += ["--uitesting"]
        app.launch()
        return app
    }

    func testLaunchesToToday() {
        let app = launch()
        XCTAssertTrue(app.staticTexts["Today"].waitForExistence(timeout: 10))
    }

    func testEveryTabIsReachable() {
        let app = launch()

        for tab in ["Log", "History", "Progress", "Today"] {
            let button = app.buttons[tab]
            XCTAssertTrue(button.waitForExistence(timeout: 5), "\(tab) tab should exist")
            button.tap()
        }
    }

    func testComposeFieldAcceptsText() {
        let app = launch()
        app.buttons["Log"].tap()

        let field = app.textFields.firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        field.tap()
        field.typeText("two eggs and toast")

        XCTAssertTrue(app.buttons["Send"].isEnabled)
    }
}

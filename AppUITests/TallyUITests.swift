import XCTest

/// Smoke tests that the app launches and its four tabs are reachable.
///
/// Deliberately shallow. UI tests are slow and brittle, and the logic worth testing thoroughly
/// already is — in TallyCore, on any platform, in milliseconds. What only a UI test can tell us
/// is that the thing launches and its navigation is wired up, so that is all these do.
///
/// `@MainActor` sits on each test method rather than on the class. `XCUIApplication` and the whole
/// query API are main-actor isolated, so under Swift 6 every touch of them from a nonisolated
/// context is an error — but annotating the class instead would put `setUp()` in conflict with
/// `XCTestCase`'s nonisolated declaration. Isolating the methods sidesteps that, which is also why
/// `continueAfterFailure` is set in the helper below instead of in a `setUp()` override.
final class TallyUITests: XCTestCase {
    @MainActor
    private func launch() -> XCUIApplication {
        continueAfterFailure = false

        let app = XCUIApplication()
        // Read by AppEnvironment to use in-memory stores and a stub parser, so a UI test never
        // touches the real database or the network.
        app.launchArguments += ["--uitesting"]
        app.launch()
        return app
    }

    @MainActor
    func testLaunchesToToday() {
        let app = launch()
        XCTAssertTrue(app.staticTexts["Today"].waitForExistence(timeout: 10))
    }

    @MainActor
    func testEveryTabIsReachable() {
        let app = launch()

        // Ends back on Today, so a failure part-way through leaves a recognisable screenshot.
        for tab in ["Log", "History", "Progress", "Today"] {
            let button = app.buttons[tab]
            XCTAssertTrue(button.waitForExistence(timeout: 5), "\(tab) tab should exist")
            button.tap()
        }
    }

    @MainActor
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

import XCTest

/// Smoke tests that the app launches and its four tabs are reachable.
///
/// Deliberately shallow. UI tests are slow and brittle, and the logic worth testing thoroughly
/// already is — in TallyCore, on any platform, in milliseconds. What only a UI test can tell us
/// is that the thing launches and its navigation is wired up, so that is all these do.
///
/// Queries use accessibility **identifiers**, not labels. Labels are user-facing copy that should
/// be free to change, and they are not guaranteed unique: the send button and the keyboard's
/// return key are both labelled "Send", which is ambiguous enough to fail a query outright.
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
        for tab in ["log", "history", "progress", "today"] {
            let button = app.buttons["tab.\(tab)"]
            XCTAssertTrue(button.waitForExistence(timeout: 5), "\(tab) tab should exist")
            button.tap()
        }
    }

    @MainActor
    func testComposeFieldEnablesSending() {
        let app = launch()
        app.buttons["tab.log"].tap()

        let field = app.textFields["log.composeField"]
        XCTAssertTrue(field.waitForExistence(timeout: 5))

        let send = app.buttons["log.sendButton"]
        XCTAssertTrue(send.waitForExistence(timeout: 5))
        // Nothing typed yet, so there is nothing to send.
        XCTAssertFalse(send.isEnabled, "Send should be disabled while the field is empty")

        field.tap()
        field.typeText("two eggs and toast")

        XCTAssertTrue(send.isEnabled, "Send should enable once there is text to log")
    }
}

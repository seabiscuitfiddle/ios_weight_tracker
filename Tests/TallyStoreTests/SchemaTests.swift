import Foundation
import Testing
@testable import TallyStore

@Suite("Schema")
struct SchemaTests {
    @Test("schema version is set")
    func schemaVersion() {
        #expect(TallyStore.schemaVersion >= 1)
    }
}

/// The App Group is derived from the bundle identifier so that changing `APP_BUNDLE_ID` is a
/// single edit. These pin that rule, because getting it wrong has no build-time symptom — just a
/// widget that never shows data.
@Suite("App Group derivation")
struct AppGroupIdentifierTests {
    @Test("prefixes the app's bundle identifier")
    func fromAppBundle() {
        #expect(TallyDatabase.appGroupIdentifier(forBundleIdentifier: "com.example.tally")
            == "group.com.example.tally")
    }

    /// The load-bearing case: the widget's identifier has a `.widget` suffix, and both processes
    /// must land on the same group or they get separate containers.
    @Test("strips the widget suffix so both targets agree")
    func appAndWidgetAgree() {
        let app = TallyDatabase.appGroupIdentifier(forBundleIdentifier: "com.example.tally")
        let widget = TallyDatabase.appGroupIdentifier(forBundleIdentifier: "com.example.tally.widget")

        #expect(app == widget)
    }

    @Test("works for any prefix, so changing it needs no code edit")
    func arbitraryPrefix() {
        #expect(TallyDatabase.appGroupIdentifier(forBundleIdentifier: "dev.example.tally")
            == "group.dev.example.tally")
        #expect(TallyDatabase.appGroupIdentifier(forBundleIdentifier: "dev.example.tally.widget")
            == "group.dev.example.tally")
    }

    /// Under a test runner or command-line tool there is no bundle identifier at all.
    @Test("falls back when there is no bundle identifier", arguments: [nil, ""])
    func fallsBack(_ identifier: String?) {
        #expect(TallyDatabase.appGroupIdentifier(forBundleIdentifier: identifier)
            == TallyDatabase.defaultAppGroupID)
    }

    /// Only a trailing `.widget` is stripped — a prefix that merely contains the word must survive.
    @Test("only strips a trailing suffix")
    func onlyTrailingSuffix() {
        #expect(TallyDatabase.appGroupIdentifier(forBundleIdentifier: "com.widget.tally")
            == "group.com.widget.tally")
    }
}

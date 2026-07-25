import Foundation
import Observation
import SwiftUI
import TallyCore
import TallyStore

/// The app's composition root.
///
/// **The only place that names a concrete storage type.** Everything else in the app talks to
/// `EntryStore` / `WeightStore` / `SettingsStore` and to `NutritionParser`, so swapping SQLite
/// for something else means editing this file and adding a conformance — not touching a single
/// screen.
@Observable
@MainActor
final class AppEnvironment {
    /// Must match the App Group in both entitlements files and in the developer portal.
    /// See README, "What you must fill in".
    static let appGroupID = "group.com.example.tally"

    let stores: StoreBundle
    let keyStore: KeychainAPIKeyStore

    /// Set when the database could not be opened. Surfaced to the user rather than crashed on:
    /// the overwhelmingly likely cause is a misconfigured App Group, and a crash on launch tells
    /// them nothing about how to fix it.
    private(set) var startupError: String?

    /// Rebuilt whenever settings change, because the model and key can both be edited.
    private(set) var parser: any NutritionParser

    var selectedTab: DeepLink.Tab = .today
    /// Set by a deep link so the Log screen knows which compose mode to open in.
    var pendingLogMode: DeepLink.LogMode?
    var isShowingSettings = false

    /// True when launched by a UI test. Those runs use in-memory storage and a stub parser, so a
    /// test never touches the user's real data and never depends on the network or an API key —
    /// a UI test that calls a live API is a test that fails for reasons unrelated to the app.
    static var isUITesting: Bool {
        ProcessInfo.processInfo.arguments.contains("--uitesting")
    }

    init() {
        let keyStore = KeychainAPIKeyStore()
        self.keyStore = keyStore

        if Self.isUITesting {
            self.stores = StoreBundle.inMemory()
            self.parser = StubNutritionParser()
            return
        }

        // A failure here is a setup problem, not a reason to lose the app. Falling back to an
        // in-memory database keeps every screen navigable so the error message can be read —
        // but it is emphatically not a silent fallback: `startupError` is set, and the UI must
        // say the data is not being saved.
        do {
            self.stores = try TallyDatabase.stores(forAppGroup: Self.appGroupID)
        } catch {
            self.stores = StoreBundle.inMemory()
            self.startupError = String(describing: error)
        }

        self.parser = AnthropicNutritionParser(
            transport: URLSessionTransport.makeDefault(),
            keyStore: keyStore,
            configuration: .default
        )
    }

    /// For previews and UI tests: entirely in memory, with a stub parser.
    init(previewStores: StoreBundle, parser: any NutritionParser = StubNutritionParser()) {
        self.stores = previewStores
        self.keyStore = KeychainAPIKeyStore(service: "com.example.tally.preview")
        self.parser = parser
    }

    /// Applies a model change from Settings.
    func updateParserConfiguration(model: String) {
        parser = AnthropicNutritionParser(
            transport: URLSessionTransport.makeDefault(),
            keyStore: keyStore,
            configuration: ParserConfiguration(
                model: model,
                effort: ParserConfiguration.default.effort,
                maxTokens: ParserConfiguration.default.maxTokens,
                baseURL: ParserConfiguration.default.baseURL
            )
        )
    }

    /// Routes an incoming `tally://` URL. Unrecognised URLs are ignored — see `DeepLink`.
    func handle(_ url: URL) {
        guard let link = DeepLink(url: url) else { return }

        selectedTab = link.tab
        switch link {
        case .log(let mode):
            pendingLogMode = mode
        case .settings:
            isShowingSettings = true
        case .today, .history, .progress:
            break
        }
    }
}

/// A parser that returns fixed results, for previews and UI tests.
///
/// UI tests use this so they never touch the network or need a key: a test that depends on a
/// live API is a test that fails for reasons unrelated to the app.
struct StubNutritionParser: NutritionParser {
    var result: ParseResult = ParseResult(
        items: [
            ParsedItem(
                kind: .food, label: "Scrambled eggs & toast", calories: 340,
                proteinGrams: 18, fiberGrams: 3, confidence: .medium
            )
        ],
        note: "Assumed two eggs and one slice."
    )
    var error: (any Error)?

    func parse(_ input: ParseInput, context: ParseContext) async throws -> ParseResult {
        if let error { throw error }
        return result
    }
}

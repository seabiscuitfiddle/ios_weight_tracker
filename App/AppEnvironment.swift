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
    let stores: StoreBundle

    /// Which provider and model the parser is currently built from. Held here as well as in
    /// storage so Settings has something to bind to without a read on every keystroke.
    private(set) var aiSettings: AISettings = .default

    /// Set when no database could be opened at all, so nothing is being persisted. Surfaced
    /// rather than crashed on: a crash at launch tells the user nothing about how to fix it.
    private(set) var startupError: String?

    /// Set when data *is* being saved, but to the app's own container rather than the shared one —
    /// so the widget won't show anything. Less severe than `startupError`, and worth saying
    /// out loud rather than leaving as a mysteriously blank widget.
    private(set) var storageNotice: String?

    /// Rebuilt whenever settings change, because the model and key can both be edited.
    private(set) var parser: any NutritionParser

    /// Banners the user has closed under this build. Mirrored in memory as well as on disk
    /// because `@Observable` can't see a write to `UserDefaults`, and the banner has to go the
    /// moment it's tapped.
    private(set) var dismissedBanners: Set<StorageBanner.Severity> = []
    private let bannerDismissals: BannerDismissals

    var selectedTab: DeepLink.Tab = .today
    /// Set by a deep link so the Log screen knows which compose mode to open in. Read through
    /// ``takePendingLogMode()``, which is why nothing outside this class may clear it.
    private(set) var pendingLogMode: DeepLink.LogMode?
    var isShowingSettings = false

    /// True when launched by a UI test. Those runs use in-memory storage and a stub parser, so a
    /// test never touches the user's real data and never depends on the network or an API key —
    /// a UI test that calls a live API is a test that fails for reasons unrelated to the app.
    static var isUITesting: Bool {
        ProcessInfo.processInfo.arguments.contains("--uitesting")
    }

    init() {
        // UI tests get a memory-only store, for the reason given in `BannerDismissals`.
        let dismissals = BannerDismissals(defaults: Self.isUITesting ? nil : .standard)
        self.bannerDismissals = dismissals
        self.dismissedBanners = Set(
            dismissals.dismissed().compactMap(StorageBanner.Severity.init(rawValue:))
        )

        if Self.isUITesting {
            self.stores = StoreBundle.inMemory()
            self.parser = StubNutritionParser()
            return
        }

        // Before anything reads a key: an install that predates configurable providers has one
        // sitting under the old single-provider name, and losing it would mean sending the user
        // back to a console to mint another.
        KeychainAPIKeyStore.migrateLegacyAnthropicKey()

        // Prefers the shared App Group container and falls back to the app's own, so a fresh
        // clone runs on a simulator without first registering an App Group. The fallback still
        // persists to a file; only the widget loses out, and `storageNotice` says so.
        do {
            let opened = try TallyDatabase.open()
            self.stores = opened.stores
            if case .appPrivate(let reason) = opened.location {
                self.storageNotice = reason
            }
        } catch {
            // Couldn't open any database at all. Keep the app navigable so the message can be
            // read, but be explicit that nothing is being kept.
            self.stores = StoreBundle.inMemory()
            self.startupError = """
                Tally couldn't open its database, so nothing you log will be saved. \
                \(error)
                """
        }

        let settings = (try? stores.settings.aiSettings()) ?? .default
        self.aiSettings = settings
        self.parser = ParserFactory.make(settings)
    }

    /// For previews and UI tests: entirely in memory, with a stub parser.
    init(previewStores: StoreBundle, parser: any NutritionParser = StubNutritionParser()) {
        self.stores = previewStores
        self.parser = parser
        self.bannerDismissals = BannerDismissals(defaults: nil)
    }

    // MARK: Banners

    /// The banner to show above the tabs, if there is one the user hasn't closed.
    ///
    /// The two severities are tracked separately: closing "the widget won't show your data"
    /// must not pre-dismiss a later "entries are not being saved", which is a different and far
    /// worse problem.
    var visibleBanner: (detail: String, severity: StorageBanner.Severity)? {
        if let startupError, !dismissedBanners.contains(.notSaving) {
            return (startupError, .notSaving)
        }
        if let storageNotice, !dismissedBanners.contains(.widgetOnly) {
            return (storageNotice, .widgetOnly)
        }
        return nil
    }

    /// Hides a banner until the app is updated — see ``BannerDismissals``.
    func dismissBanner(_ severity: StorageBanner.Severity) {
        dismissedBanners.insert(severity)
        bannerDismissals.dismiss(severity.rawValue)
    }

    /// Applies a provider or model change from Settings.
    ///
    /// Persists first, then rebuilds. The parser is a value built from the settings, so there is
    /// no state to keep in step — a changed provider is simply a different parser from the next
    /// call onward.
    func updateAISettings(_ settings: AISettings) throws {
        try stores.settings.save(settings)
        aiSettings = settings
        parser = ParserFactory.make(settings)
    }

    /// The keychain item for one provider. Each has its own, so switching between them doesn't
    /// mean pasting a key in again — and no provider can read a key entered for another.
    func keyStore(for providerID: String) -> KeychainAPIKeyStore {
        KeychainAPIKeyStore.forCurrentBundle(providerID: providerID)
    }

    // MARK: Health import

    /// Imports weight and workouts from Apple Health.
    ///
    /// - Returns: a sentence to show the user. Reports "nothing new" rather than success on an
    ///   empty import, because HealthKit deliberately never reveals whether a *read* was denied —
    ///   so zero records could equally mean "no new data" or "permission refused", and claiming
    ///   success would be a guess.
    func importFromHealth() async -> String {
        guard HealthKitImporter.isAvailable else {
            return HealthImportError.unavailable.userMessage
        }

        let importer = HealthKitImporter()
        do {
            try await importer.requestAuthorization()
            let count = try await importer.importRecent(into: stores)
            guard count > 0 else {
                return "Nothing new to import. If you haven't granted access, check Settings › Health."
            }
            return "Imported \(count) record\(count == 1 ? "" : "s") from Health."
        } catch let error as HealthImportError {
            return error.userMessage
        } catch {
            return "Couldn't read from Health: \(error.localizedDescription)"
        }
    }

    /// Hands the requested compose mode to the Log screen, clearing it in the same step.
    ///
    /// Taking rather than reading is what makes the screen safe to ask twice — once when it
    /// appears, because a widget button sets the mode *before* the screen exists, and once on
    /// change, for a tap that arrives while it is already up. Only one of the two can win.
    ///
    /// It also guarantees the mode is never left set, which matters more than it looks: a mode
    /// still sitting here reads as "a deep link is steering this screen", so a stale one keeps
    /// the keyboard shut on every later visit to Log.
    func takePendingLogMode() -> DeepLink.LogMode? {
        defer { pendingLogMode = nil }
        return pendingLogMode
    }

    /// Picks up a destination set by an App Intent before the app was foregrounded.
    func consumePendingIntentLink() {
        guard let link = OpenQuickLogIntent.pendingLink else { return }
        OpenQuickLogIntent.pendingLink = nil

        selectedTab = link.tab
        if case .log(let mode) = link { pendingLogMode = mode }
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

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

    /// Held for as long as measured activity is switched on. Nil is the honest signal that
    /// nothing is observing Health — see ``startActivityMonitor()``.
    private var activityMonitor: HealthActivityMonitor?

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

    /// The one environment this process runs on.
    ///
    /// The scene used to own it outright, which is fine right up until there is no scene: iOS
    /// wakes Tally for a Health update by *launching* it, and a background launch connects no
    /// window at all. Anything reachable only from a view therefore doesn't exist on the launches
    /// that keep the widgets honest — see ``handleLaunch()``. Shared rather than built twice so
    /// the launch and the window are looking at one set of stores, not two connections to the
    /// same file with two change broadcasters between them.
    static let shared = AppEnvironment()

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

    // MARK: Launch

    /// The work a launch owes whether or not a window ever appears.
    ///
    /// Registering the Health observer is the part that cannot wait for a scene, and that is the
    /// whole reason this exists. Background delivery — what the entitlement notes in the README
    /// describe as letting "iOS wake Tally when Health data changes, so the day's movement reaches
    /// your target and your widgets without opening the app" — delivers by launching the app with
    /// no scene attached. Started from a view's `.task`, as it was, the observer was therefore
    /// never registered on precisely the launches it was written for: the update went unhandled,
    /// nothing was written, no reload was sent, and every widget went on showing the numbers from
    /// before the workout until the app was next opened by hand.
    ///
    /// The Lock Screen is where that shows up, because it is the one surface people read without
    /// opening anything — the Home Screen tiles are usually seen just after a visit to the app,
    /// which is what had already brought them up to date.
    ///
    /// Registering is enough on its own: an observer that comes up with an update outstanding
    /// fires immediately, which runs the sync and reloads the widgets. This launch's *own*
    /// reading stays with the scene, where there is a screen waiting for it.
    ///
    /// A no-op unless the user switched measured activity on.
    func handleLaunch() async {
        await startActivityMonitorIfEnabled()
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

    // MARK: Health

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

        do {
            let profile = try stores.settings.profile()
            guard profile.health.isEnabled else {
                return HealthImportError.switchedOff.userMessage
            }

            let importer = HealthKitImporter()
            try await importer.requestAuthorization(profile: profile)
            let count = try await importer.sync(into: stores, profile: profile)
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

    /// Brings today's activity up to date.
    ///
    /// Called on every foreground and from the background observer, so it has to be cheap and
    /// silent: it reads a week of daily totals, writes only the days whose figure actually
    /// moved, and says nothing when there is nothing to say. Failures are swallowed on purpose —
    /// there is no user standing in front of this, and an alert about a Health read that didn't
    /// come back would arrive with no question the user could answer.
    func refreshHealthActivity() async {
        guard HealthKitImporter.isAvailable,
              let profile = try? stores.settings.profile(),
              profile.usesMeasuredActivity
        else { return }

        let count = try? await HealthKitImporter().sync(
            days: HealthKitImporter.activityRefreshDays,
            into: stores,
            profile: profile
        )

        // A background wake has no scene behind it, so the widget subscription set up at the
        // scene root may never have been started. Reloading here is what makes the ring on the
        // Home Screen the thing that actually moves. `WidgetRefresher` sends the reload; going
        // through it rather than `WidgetCenter` keeps the one seam the app's tests can observe.
        if let count, count > 0 { WidgetRefresher().reload() }
    }

    /// Turns the whole Health integration on or off.
    ///
    /// Switching on asks for authorization straight away: the prompt belongs to the moment the
    /// user asked for Health, not to some later import they may not connect with it.
    ///
    /// Switching off withdraws everything Tally is doing — the observer, background delivery,
    /// and the activity entries it synthesised — but **keeps the weights and workouts already
    /// imported**. Those are records of things that happened, and deleting a month of the user's
    /// log because a switch moved would be taking their data away from them.
    ///
    /// - Returns: a sentence to show the user, or nil when there is nothing worth saying.
    @discardableResult
    func setHealthEnabled(_ isEnabled: Bool) async -> String? {
        do {
            var profile = try stores.settings.profile()
            profile.health.isEnabled = isEnabled

            if isEnabled {
                try saveProfile(profile)
                try await HealthKitImporter().requestAuthorization(profile: profile)
                return nil
            }

            let trackedFrom = profile.health.activityTrackingStartDay
            profile.health.usesActivityForExpenditure = false
            profile.health.activityTrackingStartDay = nil
            try saveProfile(profile)

            await stopActivityMonitor()
            let removed = try removeActivityEntries(since: trackedFrom)
            return removed > 0
                ? "Apple Health switched off. Your imported weights and workouts were kept."
                : nil
        } catch let error as HealthImportError {
            return error.userMessage
        } catch {
            return "Couldn't update Apple Health settings: \(error.localizedDescription)"
        }
    }

    /// Switches measured activity — the Move figure driving the calorie target — on or off.
    ///
    /// On: records today as the day the numbers changed meaning (see
    /// `GoalCalculator.Inputs.netCaloriesValidFrom`), starts the observer, and pulls the day's
    /// activity in immediately so the target reflects it before the user leaves Settings.
    ///
    /// Off: removes the synthesised activity entries. They cannot be left behind — the activity
    /// multiplier comes back at the same moment, and the two together would count the same
    /// movement twice, in the user's history as well as today.
    ///
    /// - Returns: a sentence to show the user, or nil when there is nothing worth saying.
    @discardableResult
    func setMeasuredActivity(_ isOn: Bool) async -> String? {
        do {
            var profile = try stores.settings.profile()
            guard profile.health.isEnabled else { return HealthImportError.switchedOff.userMessage }

            if isOn {
                profile.health.usesActivityForExpenditure = true
                profile.health.activityTrackingStartDay = Day.today()
                try saveProfile(profile)

                try await startActivityMonitor()
                await refreshHealthActivity()
                return nil
            }

            let trackedFrom = profile.health.activityTrackingStartDay
            profile.health.usesActivityForExpenditure = false
            profile.health.activityTrackingStartDay = nil
            try saveProfile(profile)

            await stopActivityMonitor()
            _ = try removeActivityEntries(since: trackedFrom)
            return nil
        } catch let error as HealthImportError {
            return error.userMessage
        } catch {
            return "Couldn't update Apple Health settings: \(error.localizedDescription)"
        }
    }

    /// Starts the observer if the user's switches call for it. Safe to call on every launch.
    func startActivityMonitorIfEnabled() async {
        guard let profile = try? stores.settings.profile(), profile.usesMeasuredActivity else {
            return
        }
        try? await startActivityMonitor()
    }

    private func startActivityMonitor() async throws {
        guard HealthKitImporter.isAvailable else { throw HealthImportError.unavailable }
        guard activityMonitor == nil else { return }

        let monitor = HealthActivityMonitor { [weak self] in
            guard let self else { return }
            await self.refreshHealthActivity()
        }
        activityMonitor = monitor

        do {
            try await monitor.start()
        } catch {
            // Nothing is observing, so nothing should claim to be. Foregrounding still
            // refreshes, which is the part the user notices.
            activityMonitor = nil
            throw error
        }
    }

    private func stopActivityMonitor() async {
        guard let monitor = activityMonitor else { return }
        activityMonitor = nil
        await monitor.stop()
    }

    /// Removes the everyday-activity entries Tally synthesised, from `start` onward.
    ///
    /// Scoped to the tracked range rather than to all of history, so this can only ever reach
    /// rows this app wrote for this feature. Falls back to the goal engine's own window when the
    /// start day is missing, which is as far back as an activity entry could be affecting a
    /// number the user sees.
    private func removeActivityEntries(since start: Day?) throws -> Int {
        let today = Day.today()
        let from = start
            ?? today.adding(days: -GoalCalculator.Inputs.netCalorieWindowDays)
        let stale = try stores.entries.entries(from: from, through: today)
            .filter { HealthImport.isActivityIdentifier($0.externalIdentifier ?? "") }

        for entry in stale {
            try stores.entries.delete(id: entry.id)
        }
        return stale.count
    }

    private func saveProfile(_ profile: UserProfile) throws {
        // The store broadcasts `.settings` itself, which is what makes every screen's goal
        // recompute against the new multiplier without Settings having to tell them.
        try stores.settings.save(profile)
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

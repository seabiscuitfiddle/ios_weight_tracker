import Foundation
import Testing
import TallyCore
@testable import Tally

/// Tests for the app target itself.
///
/// Deliberately thin. Everything decidable lives in TallyCore and is tested there, on any
/// platform; what's left here is the glue that can only exist inside an app — deep-link routing
/// into view state, and the view models' interaction with the stores.
@MainActor
@Suite("App environment")
struct AppEnvironmentTests {
    private func environment() -> AppEnvironment {
        AppEnvironment(previewStores: .inMemory())
    }

    @Test("a widget quick-log URL selects the Log tab and its compose mode")
    func widgetDeepLinkRouting() throws {
        let environment = environment()
        let url = try #require(URL(string: "tally://log?mode=voice"))

        environment.handle(url)

        #expect(environment.selectedTab == .log)
        #expect(environment.pendingLogMode == .voice)
    }

    @Test("a settings link opens settings over the Progress tab")
    func settingsDeepLink() throws {
        let environment = environment()
        let url = try #require(URL(string: "tally://settings"))

        environment.handle(url)

        #expect(environment.isShowingSettings)
        #expect(environment.selectedTab == .progress)
    }

    @Test("an unrecognised URL changes nothing")
    func ignoresForeignURLs() throws {
        let environment = environment()
        environment.selectedTab = .history
        let url = try #require(URL(string: "https://example.com/log"))

        environment.handle(url)

        #expect(environment.selectedTab == .history)
        #expect(environment.pendingLogMode == nil)
    }
}

@MainActor
@Suite("Today model")
struct TodayModelTests {
    private let day = Day.today()

    @Test("totals the day and reports what's left against the goal")
    func totalsAndRemaining() throws {
        let stores = StoreBundle.inMemory(
            entries: [
                Entry(kind: .food, label: "Lunch", calories: 640, proteinGrams: 48, day: Day.today()),
                Entry(kind: .exercise, label: "Run", calories: 320,
                      exerciseKind: .cardio, day: Day.today()),
            ],
            weights: [WeightSample(day: Day.today(), pounds: 168.4)],
            profile: UserProfile(
                birthDate: Calendar.current.date(byAdding: .year, value: -35, to: Date()),
                heightCentimeters: 178,
                biologicalSex: .male
            ),
            goal: GoalSettings(targetPounds: 155)
        )

        let model = TodayModel(stores: stores)
        model.load()

        #expect(model.totals.netCalories == 320)
        #expect(model.entries.count == 2)
        #expect(model.needsGoalSetup == false)
        #expect(model.remaining == (model.goal?.calories ?? 0) - 320)
    }

    /// With no profile and no weight there is nothing to compute a goal from, and the screen
    /// must ask rather than draw a ring around an invented number.
    @Test("asks for setup when no goal can be computed")
    func promptsForSetup() {
        let model = TodayModel(stores: .inMemory())
        model.load()

        #expect(model.needsGoalSetup)
        #expect(model.goal == nil)
        #expect(model.remaining == nil)
    }

    @Test("deleting an entry removes it from the day")
    func deletion() throws {
        let entry = Entry(kind: .food, label: "Toast", calories: 200, day: Day.today())
        let stores = StoreBundle.inMemory(entries: [entry])
        let model = TodayModel(stores: stores)
        model.load()
        #expect(model.entries.count == 1)

        model.delete(entry)
        model.load()

        #expect(model.entries.isEmpty)
        #expect(model.totals.netCalories == 0)
    }
}

@MainActor
@Suite("Log model")
struct LogModelTests {
    @Test("saves what the parser returns and shows it as just added")
    func savesParsedItems() async throws {
        let stores = StoreBundle.inMemory()
        let model = LogModel(stores: stores, parser: StubNutritionParser())

        await model.log(text: "two eggs and toast")

        #expect(model.justAdded.count == 1)
        #expect(model.errorMessage == nil)
        // And it really reached storage, not just the view state.
        #expect(try stores.entries.entries(on: Day.today()).count == 1)
    }

    @Test("keeps the user's own words on the saved entry")
    func retainsTranscript() async throws {
        let stores = StoreBundle.inMemory()
        let model = LogModel(stores: stores, parser: StubNutritionParser())

        await model.log(text: "two eggs and toast")

        #expect(model.justAdded.first?.rawInput == "two eggs and toast")
        #expect(model.justAdded.first?.source == .llmText)
    }

    /// A failure has to be actionable: the message the user sees, and whether the UI should
    /// offer "try again" or send them to Settings.
    @Test("surfaces a parser failure with the right follow-up action")
    func surfacesErrors() async throws {
        let stores = StoreBundle.inMemory()
        let parser = StubNutritionParser(error: NutritionParserError.missingAPIKey)
        let model = LogModel(stores: stores, parser: parser)

        await model.log(text: "toast")

        #expect(model.errorMessage == NutritionParserError.missingAPIKey.userMessage)
        #expect(model.needsAPIKey)
        #expect(model.canRetry == false)
        #expect(model.justAdded.isEmpty)
        #expect(try stores.entries.entries(on: Day.today()).isEmpty)
    }

    @Test("offers a retry for a transient failure")
    func retryableErrors() async throws {
        let parser = StubNutritionParser(error: NutritionParserError.overloaded)
        let model = LogModel(stores: .inMemory(), parser: parser)

        await model.log(text: "toast")

        #expect(model.canRetry)
        #expect(model.needsAPIKey == false)
    }
}

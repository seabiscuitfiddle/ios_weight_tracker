import AppIntents
import Foundation
import TallyCore
import TallyStore

/// Builds the app's services outside the UI.
///
/// App Intents run without a view hierarchy — Siri may invoke one while the app isn't even in the
/// foreground — so they cannot reach `AppEnvironment`. Both go through this, so there is one
/// definition of "how Tally is wired up" rather than two that can drift.
enum TallyServices {
    static func stores() throws -> StoreBundle {
        try TallyDatabase.stores(forAppGroup: AppEnvironment.appGroupID)
    }

    static func parser(model: String = ParserConfiguration.default.model) -> any NutritionParser {
        AnthropicNutritionParser(
            transport: URLSessionTransport.makeDefault(),
            keyStore: KeychainAPIKeyStore(),
            configuration: ParserConfiguration(
                model: model,
                effort: ParserConfiguration.default.effort,
                maxTokens: ParserConfiguration.default.maxTokens,
                baseURL: ParserConfiguration.default.baseURL
            )
        )
    }

    /// Today's goal, or nil when there isn't enough set up to compute one.
    static func todaysGoal(_ stores: StoreBundle, calendar: Calendar = .current) throws -> DailyGoal? {
        let today = Day.today(calendar: calendar)
        return GoalCalculator.dailyGoal(GoalCalculator.Inputs(
            profile: try stores.settings.profile(),
            settings: try stores.settings.goalSettings(),
            weightSamples: try stores.weights.allSamples(),
            dailyNetCalories: try stores.entries
                .totals(from: today.adding(days: -365, calendar: calendar), through: today)
                .mapValues(\.netCalories),
            today: today,
            now: Date(),
            calendar: calendar
        ))
    }
}

/// "Hey Siri, log food with Tally."
///
/// Runs without opening the app. That is the whole value: logging a meal out loud while your
/// hands are busy is the case voice input exists for, and bouncing the user into the app to
/// confirm would remove the benefit.
struct LogFoodOrExerciseIntent: AppIntent {
    static let title: LocalizedStringResource = "Log food or exercise"
    static let description = IntentDescription(
        "Describe what you ate or did and Tally will work out the calories and macros.",
        categoryName: "Logging"
    )

    @Parameter(
        title: "Description",
        requestValueDialog: "What did you eat or do?"
    )
    var text: String

    static var parameterSummary: some ParameterSummary {
        Summary("Log \(\.$text) in Tally")
    }

    func perform() async throws -> some IntentResult & ProvidesDialog {
        let stores = try TallyServices.stores()

        // Body weight materially changes exercise estimates, so pass it along as the app does.
        let today = Day.today()
        let context = ParseContext(
            bodyWeightPounds: try? stores.weights.latestSample(onOrBefore: today)?.pounds
        )

        let result: ParseResult
        do {
            result = try await TallyServices.parser().parse(.text(text), context: context)
        } catch let error as NutritionParserError {
            // Surfaced as spoken dialog rather than thrown, so Siri says something useful
            // instead of "there was a problem with the app".
            return .result(dialog: IntentDialog(stringLiteral: error.userMessage))
        }

        let now = Date()
        let entries = result.items.map {
            $0.entry(on: today, loggedAt: now, source: .llmVoice, rawInput: text)
        }
        try stores.entries.save(entries)

        // Confirm with the number that was actually recorded — a bare "done" gives the user no
        // way to notice a wrong estimate while they can still fix it easily.
        let net = entries.reduce(0) { $0 + $1.signedCalories }
        let names = entries.map(\.label).joined(separator: ", ")

        if let goal = try TallyServices.todaysGoal(stores) {
            let remaining = try stores.entries.totals(on: today).remaining(against: goal.calories)
            return .result(dialog: """
                Logged \(names), \(abs(net)) calories. \
                You have \(remaining) left today.
                """)
        }
        return .result(dialog: "Logged \(names), \(abs(net)) calories.")
    }
}

/// "Hey Siri, log my weight with Tally."
struct LogWeightIntent: AppIntent {
    static let title: LocalizedStringResource = "Log weight"
    static let description = IntentDescription(
        "Record today's weight.",
        categoryName: "Logging"
    )

    @Parameter(title: "Weight", requestValueDialog: "What do you weigh?")
    var weight: Double

    static var parameterSummary: some ParameterSummary {
        Summary("Log \(\.$weight) as today's weight in Tally")
    }

    func perform() async throws -> some IntentResult & ProvidesDialog {
        let stores = try TallyServices.stores()
        let profile = try stores.settings.profile()

        // The spoken number is in whatever unit the user has chosen, so convert to canonical
        // pounds on the way in — otherwise "seventy-six" would be stored as 76 lb.
        let pounds = profile.massUnit.pounds(from: weight)
        guard pounds > 0, pounds < 1500 else {
            return .result(dialog: "That doesn't look like a weight I can record.")
        }

        try stores.weights.save(WeightSample(
            day: Day.today(), pounds: pounds, measuredAt: Date(), source: .manual
        ))

        let formatted = TallyFormat.weightWithUnit(pounds: pounds, unit: profile.massUnit)
        return .result(dialog: "Recorded \(formatted).")
    }
}

/// "Hey Siri, how many calories do I have left?"
///
/// Answers out loud without opening the app, since the question is the whole interaction.
struct RemainingCaloriesIntent: AppIntent {
    static let title: LocalizedStringResource = "Check calories remaining"
    static let description = IntentDescription(
        "Ask how many calories are left today.",
        categoryName: "Today"
    )

    func perform() async throws -> some IntentResult & ProvidesDialog {
        let stores = try TallyServices.stores()
        let today = Day.today()
        let totals = try stores.entries.totals(on: today)

        guard let goal = try TallyServices.todaysGoal(stores) else {
            return .result(dialog: """
                Tally doesn't have a calorie goal yet. \
                Open the app and add your height and a goal weight.
                """)
        }

        let remaining = totals.remaining(against: goal.calories)
        if remaining >= 0 {
            return .result(dialog: """
                You have \(remaining) calories left today, out of \(goal.calories).
                """)
        }
        return .result(dialog: """
            You're \(abs(remaining)) calories over your goal of \(goal.calories) today.
            """)
    }
}

/// Opens the app on the quick-log screen. The one intent that must foreground the app, because
/// typing and photos need a UI.
struct OpenQuickLogIntent: AppIntent {
    static let title: LocalizedStringResource = "Open quick log"
    static let description = IntentDescription("Open Tally ready to log.", categoryName: "Logging")
    static let openAppWhenRun = true

    func perform() async throws -> some IntentResult {
        // Routed through the same deep link the widget's buttons use, so there is one path into
        // the Log screen rather than a second mechanism to keep in step.
        await MainActor.run {
            OpenQuickLogIntent.pendingLink = DeepLink.log(mode: .text)
        }
        return .result()
    }

    /// Read by the app on launch. Static because an intent instance does not outlive `perform()`.
    @MainActor static var pendingLink: DeepLink?
}

/// The phrases Siri and Spotlight recognise without the user setting anything up.
struct TallyShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: LogFoodOrExerciseIntent(),
            phrases: [
                "Log food in \(.applicationName)",
                "Log a meal in \(.applicationName)",
                "Log exercise in \(.applicationName)",
                "Add to \(.applicationName)",
            ],
            shortTitle: "Log food or exercise",
            systemImageName: "fork.knife"
        )

        AppShortcut(
            intent: RemainingCaloriesIntent(),
            phrases: [
                "How many calories do I have left in \(.applicationName)",
                "Calories left in \(.applicationName)",
                "Check my \(.applicationName)",
            ],
            shortTitle: "Calories left",
            systemImageName: "chart.pie"
        )

        AppShortcut(
            intent: LogWeightIntent(),
            phrases: [
                "Log my weight in \(.applicationName)",
                "Record my weight in \(.applicationName)",
            ],
            shortTitle: "Log weight",
            systemImageName: "scalemass"
        )
    }
}

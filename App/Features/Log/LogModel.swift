import Foundation
import Observation
import TallyCore

/// Drives the quick-log screen: parse, save, and report failures usefully.
@Observable
@MainActor
final class LogModel {
    private let stores: StoreBundle
    private let parser: any NutritionParser
    private let calendar: Calendar

    private(set) var justAdded: [Entry] = []
    private(set) var isParsing = false
    private(set) var errorMessage: String?
    private(set) var canRetry = false
    private(set) var needsAPIKey = false
    private(set) var goal: DailyGoal?
    private(set) var remaining: Int?

    /// Kept so "Try again" can resend without making the user retype.
    private var lastInput: ParseInput?

    init(stores: StoreBundle, parser: any NutritionParser, calendar: Calendar = .current) {
        self.stores = stores
        self.parser = parser
        self.calendar = calendar
    }

    func load() {
        let day = Day.today(calendar: calendar)
        do {
            let totals = try stores.entries.totals(on: day)
            goal = try currentGoal(day: day)
            remaining = goal.map { totals.remaining(against: $0.calories) }
        } catch {
            errorMessage = String(describing: error)
        }
    }

    func log(text: String) async {
        await run(.text(text))
    }

    func log(image: Data, mediaType: ParseInput.ImageMediaType, note: String?) async {
        await run(.image(data: image, mediaType: mediaType, note: note))
    }

    func retry() async {
        guard let lastInput else { return }
        await run(lastInput)
    }

    private func run(_ input: ParseInput) async {
        lastInput = input
        isParsing = true
        errorMessage = nil
        canRetry = false
        needsAPIKey = false
        defer { isParsing = false }

        // Body weight materially changes exercise estimates, so send it when we have it.
        let day = Day.today(calendar: calendar)
        let context = ParseContext(
            bodyWeightPounds: try? stores.weights.latestSample(onOrBefore: day)?.pounds
        )

        do {
            let result = try await parser.parse(input, context: context)
            let now = Date()
            let entries = result.items.map {
                $0.entry(
                    on: day,
                    loggedAt: now,
                    source: source(for: input),
                    rawInput: input.transcript,
                    calendar: calendar
                )
            }

            try stores.entries.save(entries)
            // Newest first, matching every other list in the app.
            justAdded.insert(contentsOf: entries, at: 0)
            load()
        } catch let error as NutritionParserError {
            errorMessage = error.userMessage
            canRetry = error.isRetryable
            needsAPIKey = error == .missingAPIKey || error == .invalidAPIKey
        } catch {
            errorMessage = String(describing: error)
            canRetry = true
        }
    }

    func delete(_ entry: Entry) {
        do {
            try stores.entries.delete(id: entry.id)
            justAdded.removeAll { $0.id == entry.id }
            load()
        } catch {
            errorMessage = String(describing: error)
        }
    }

    private func source(for input: ParseInput) -> RecordSource {
        switch input {
        case .text: .llmText
        case .image: .llmPhoto
        }
    }

    private func currentGoal(day: Day) throws -> DailyGoal? {
        let windowStart = day.adding(days: -365, calendar: calendar)
        return GoalCalculator.dailyGoal(GoalCalculator.Inputs(
            profile: try stores.settings.profile(),
            settings: try stores.settings.goalSettings(),
            weightSamples: try stores.weights.allSamples(),
            dailyNetCalories: try stores.entries
                .totals(from: windowStart, through: day)
                .mapValues(\.netCalories),
            today: day,
            now: Date(),
            calendar: calendar
        ))
    }
}

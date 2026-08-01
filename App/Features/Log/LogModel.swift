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
    private var lastWasSpoken = false

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

    /// - Parameter spoken: true when the text came from voice transcription rather than the
    ///   keyboard, so the entry records `.llmVoice` and the UI can show its provenance.
    func log(text: String, spoken: Bool = false) async {
        await run(.text(text), spoken: spoken)
    }

    func log(image: Data, mediaType: ParseInput.ImageMediaType, note: String?) async {
        await run(.image(data: image, mediaType: mediaType, note: note))
    }

    func retry() async {
        guard let lastInput else { return }
        await run(lastInput, spoken: lastWasSpoken)
    }

    private func run(_ input: ParseInput, spoken: Bool = false) async {
        lastInput = input
        lastWasSpoken = spoken
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
            // One send is usually several things, and each becomes a card that is corrected on
            // its own — so each carries the part of the description it came from. The whole
            // transcript is only the fallback, for a photo or a parser that named no fragment.
            let entries = result.items.map {
                $0.entry(
                    on: day,
                    loggedAt: now,
                    source: source(for: input, spoken: spoken),
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

    /// Re-reads the just-added cards, dropping any that have since gone.
    ///
    /// The entry editor writes through the store rather than through this model, so once it
    /// closes these cards are the only copies left showing the numbers from before the edit.
    func refreshJustAdded() {
        justAdded = justAdded.compactMap { (try? stores.entries.entry(id: $0.id)) ?? nil }
        load()
    }

    private func source(for input: ParseInput, spoken: Bool) -> RecordSource {
        switch input {
        case .text: spoken ? .llmVoice : .llmText
        case .image: .llmPhoto
        }
    }

    private func currentGoal(day: Day) throws -> DailyGoal? {
        GoalCalculator.dailyGoal(
            try GoalCalculator.Inputs(stores: stores, today: day, calendar: calendar)
        )
    }
}

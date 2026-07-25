import Foundation
import Observation
import TallyCore

/// Everything the Today screen shows, loaded from the stores.
///
/// The view holds no logic beyond layout: it reads these properties and draws them. That split is
/// what keeps the untestable half of the app (SwiftUI, which needs Xcode) as thin as possible,
/// with the decisions living in TallyCore where they are covered by tests.
@Observable
@MainActor
final class TodayModel {
    private let stores: StoreBundle
    private let calendar: Calendar

    private(set) var day: Day
    private(set) var totals: DayTotals = .empty
    private(set) var entries: [Entry] = []
    private(set) var goal: DailyGoal?
    private(set) var goalSettings: GoalSettings = .default
    private(set) var loadError: String?

    init(stores: StoreBundle, calendar: Calendar = .current, today: Day? = nil) {
        self.stores = stores
        self.calendar = calendar
        self.day = today ?? Day.today(calendar: calendar)
    }

    /// Calories left against the goal, or nil when there is no goal to measure against.
    var remaining: Int? {
        goal.map { totals.remaining(against: $0.calories) }
    }

    /// Ring fill, 0...1.
    var progress: Double {
        guard let goal else { return 0 }
        return totals.progress(against: goal.calories)
    }

    /// True when the user has not given us enough to compute a goal. The screen then asks for
    /// what's missing instead of drawing a ring around an invented number.
    var needsGoalSetup: Bool { goal == nil }

    func load() {
        // The day can change while the app sits in the background overnight.
        day = Day.today(calendar: calendar)

        do {
            entries = try stores.entries.entries(on: day)
            totals = DayTotals.summing(entries)
            goalSettings = try stores.settings.goalSettings()
            goal = try computeGoal()
            loadError = nil
        } catch {
            loadError = String(describing: error)
        }
    }

    /// Reloads whenever anything is written, from any screen or from a Siri intent.
    func observeChanges() async {
        for await _ in stores.changes.stream(for: [.entries, .weights, .settings]) {
            load()
        }
    }

    func delete(_ entry: Entry) {
        do {
            try stores.entries.delete(id: entry.id)
        } catch {
            loadError = String(describing: error)
        }
    }

    private func computeGoal() throws -> DailyGoal? {
        let profile = try stores.settings.profile()
        let settings = try stores.settings.goalSettings()
        let samples = try stores.weights.allSamples()

        // The observed-expenditure estimate needs per-day net intake across the window it
        // measures. Bounded to a year so this stays a fixed-size read however long the user has
        // been logging.
        let windowStart = day.adding(days: -365, calendar: calendar)
        let dailyTotals = try stores.entries.totals(from: windowStart, through: day)

        return GoalCalculator.dailyGoal(GoalCalculator.Inputs(
            profile: profile,
            settings: settings,
            weightSamples: samples,
            dailyNetCalories: dailyTotals.mapValues(\.netCalories),
            today: day,
            now: Date(),
            calendar: calendar
        ))
    }
}

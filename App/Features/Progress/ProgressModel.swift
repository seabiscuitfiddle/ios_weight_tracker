import Foundation
import Observation
import TallyCore

@Observable
@MainActor
final class ProgressModel {
    private let stores: StoreBundle
    private let calendar: Calendar

    /// The chart window, and the period the headline change is measured over.
    static let windowDays = 30

    private(set) var unit: MassUnit = .pounds
    private(set) var trend = WeightTrend(samples: [])
    private(set) var goal: DailyGoal?
    private(set) var targetPounds: Double?

    /// The value the stepper is currently showing, in canonical pounds.
    private(set) var draftPounds: Double = 170

    init(stores: StoreBundle, calendar: Calendar = .current) {
        self.stores = stores
        self.calendar = calendar
    }

    var currentTrendPounds: Double? { trend.currentTrendPounds }

    var changeOverWindow: Double? {
        trend.trendChange(overLast: Self.windowDays, calendar: calendar)
    }

    var windowWeeks: Int { Self.windowDays / 7 }

    /// Trend values inside the window, oldest first, for the chart.
    var chartPoints: [Double] {
        let today = Day.today(calendar: calendar)
        let start = today.adding(days: -Self.windowDays, calendar: calendar)
        return trend.points.filter { $0.day >= start }.map(\.trendPounds)
    }

    /// "173 → 168.4", the caption the design puts above the chart.
    var chartRangeLabel: String? {
        let points = chartPoints
        guard let first = points.first, let last = points.last, points.count >= 2 else {
            return nil
        }
        return "\(TallyFormat.weight(pounds: first, unit: unit)) → \(TallyFormat.weight(pounds: last, unit: unit))"
    }

    func load() {
        do {
            let profile = try stores.settings.profile()
            let settings = try stores.settings.goalSettings()
            unit = profile.massUnit
            targetPounds = settings.targetPounds

            let samples = try stores.weights.allSamples()
            trend = WeightTrend(samples: samples)

            let today = Day.today(calendar: calendar)
            // Seed the stepper from today's reading if there is one, otherwise the most recent —
            // someone correcting today's entry shouldn't have to dial back from a default.
            draftPounds = try stores.weights.sample(on: today)?.pounds
                ?? stores.weights.latestSample(onOrBefore: today)?.pounds
                ?? 170

            goal = GoalCalculator.dailyGoal(GoalCalculator.Inputs(
                profile: profile,
                settings: settings,
                weightSamples: samples,
                dailyNetCalories: try stores.entries
                    .totals(from: today.adding(days: -365, calendar: calendar), through: today)
                    .mapValues(\.netCalories),
                today: today,
                now: Date(),
                calendar: calendar
            ))
        } catch {
            trend = WeightTrend(samples: [])
            goal = nil
        }
    }

    func observeChanges() async {
        for await _ in stores.changes.stream(for: [.weights, .entries, .settings]) {
            load()
        }
    }

    /// Steps the draft by `delta` **in the displayed unit**, so a tap moves the number the user
    /// sees by a consistent amount rather than by a converted fraction.
    func adjustDraft(by delta: Double) {
        let displayed = unit.value(fromPounds: draftPounds) + delta
        draftPounds = max(0, unit.pounds(from: displayed))
    }

    func logDraft() {
        let today = Day.today(calendar: calendar)
        try? stores.weights.save(WeightSample(
            day: today,
            pounds: draftPounds,
            measuredAt: Date(),
            source: .manual,
            calendar: calendar
        ))
        load()
    }
}

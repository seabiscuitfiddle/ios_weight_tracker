import Foundation

extension GoalCalculator.Inputs {
    /// How far back the per-day net calories are read.
    ///
    /// The observed estimate only looks at the last few weeks, but the trust ramp and any
    /// future window change want more than that to hand. A year bounds the read to a fixed size
    /// however long the user has been logging.
    public static let netCalorieWindowDays = 365

    /// Everything the goal engine needs, read from storage in one place.
    ///
    /// Five call sites built this by hand — Today, Progress, Log, the App Intents, and the
    /// widget's timeline provider — which meant five chances for them to disagree about the
    /// window, or to miss a new input and quietly compute a different goal on one screen than
    /// on another. `netCaloriesValidFrom` is exactly such an input, and deriving it here is what
    /// guarantees every surface applies it.
    ///
    /// Throwing rather than degrading: a caller that can tolerate a failed read (the widget)
    /// can say so with `try?`, and one that can't gets told.
    public init(
        stores: StoreBundle,
        today: Day,
        now: Date = Date(),
        calendar: Calendar = .current
    ) throws {
        let profile = try stores.settings.profile()
        let windowStart = today.adding(days: -Self.netCalorieWindowDays, calendar: calendar)

        self.init(
            profile: profile,
            settings: try stores.settings.goalSettings(),
            weightSamples: try stores.weights.allSamples(),
            dailyNetCalories: try stores.entries
                .totals(from: windowStart, through: today)
                .mapValues(\.netCalories),
            // Only while measured activity is actually in effect. A user who switched Health
            // off left the start day behind them, and their recent days are modelled again —
            // honouring it then would throw away history that is once more comparable.
            netCaloriesValidFrom: profile.usesMeasuredActivity
                ? profile.health.activityTrackingStartDay
                : nil,
            today: today,
            now: now,
            calendar: calendar
        )
    }
}

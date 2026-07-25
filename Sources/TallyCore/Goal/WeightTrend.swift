import Foundation

/// A smoothed weight line computed from raw weigh-ins.
///
/// Body weight swings by pounds day to day on water, salt, and gut contents — swings much larger
/// than the ~0.14 lb/day that a 500 kcal deficit actually produces. So the raw series is nearly
/// useless both for showing progress and for driving the goal, and Tally never uses it for
/// either. Everything reads the exponentially-weighted trend instead:
///
///     trend[0] = weight[0]
///     trend[i] = α · weight[i] + (1 − α) · trend[i − 1]
///
/// This is the "Hacker's Diet" moving average. At α = 0.1 a reading takes roughly ten weigh-ins
/// to be fully absorbed, which is slow enough to ignore a salty dinner and fast enough to show a
/// real change within a week or two.
///
/// The recursion runs over readings in order, not over calendar days, so gaps don't insert
/// phantom data. The cost is that someone who weighs in weekly gets less smoothing per elapsed
/// day than someone daily — acceptable, and better than interpolating weight the user never
/// stepped on a scale for.
public struct WeightTrend: Hashable, Sendable {
    /// One point on the trend line, paired with the reading that produced it.
    public struct Point: Hashable, Sendable {
        public let day: Day
        /// The raw weigh-in, in pounds.
        public let pounds: Double
        /// The smoothed value, in pounds.
        public let trendPounds: Double

        public init(day: Day, pounds: Double, trendPounds: Double) {
            self.day = day
            self.pounds = pounds
            self.trendPounds = trendPounds
        }
    }

    /// Default smoothing factor. See the type-level discussion for why 0.1.
    public static let defaultAlpha = 0.1

    /// Trend points, oldest first. Empty when there were no samples.
    public let points: [Point]

    /// Builds the trend from `samples`, which need not be sorted.
    public init(samples: [WeightSample], alpha: Double = WeightTrend.defaultAlpha) {
        let alpha = min(1, max(0.001, alpha))
        // Sorting here rather than trusting the caller: the recursion is order-dependent, and
        // an unsorted input would silently produce a wrong line rather than an obvious error.
        let ordered = samples.sorted { $0.day < $1.day }

        var points: [Point] = []
        points.reserveCapacity(ordered.count)
        var trend: Double?

        for sample in ordered {
            // Seeding with the first reading rather than with zero: seeding at zero would take
            // dozens of weigh-ins to climb to body weight, showing a wildly wrong line for
            // weeks. The cost is that the first point carries the first reading's noise.
            let updated = trend.map { alpha * sample.pounds + (1 - alpha) * $0 } ?? sample.pounds
            trend = updated
            points.append(Point(day: sample.day, pounds: sample.pounds, trendPounds: updated))
        }

        self.points = points
    }

    public var isEmpty: Bool { points.isEmpty }

    /// The most recent smoothed weight — what the UI should call "current weight".
    public var currentTrendPounds: Double? { points.last?.trendPounds }

    /// The most recent raw weigh-in.
    public var latestPounds: Double? { points.last?.pounds }

    public var firstDay: Day? { points.first?.day }
    public var lastDay: Day? { points.last?.day }

    /// The trend value at or before `day`, or nil if nothing had been recorded yet.
    public func trendPounds(onOrBefore day: Day) -> Double? {
        points.last { $0.day <= day }?.trendPounds
    }

    /// Change in trend weight across the window ending at the latest reading and starting
    /// `days` days earlier. Negative means weight came down.
    ///
    /// Returns nil unless there is a reading at or before the window's start, since otherwise
    /// the "change" would just be the seeding artefact of the first point.
    public func trendChange(overLast days: Int, calendar: Calendar = .current) -> Double? {
        guard let last = points.last, days > 0 else { return nil }
        let start = last.day.adding(days: -days, calendar: calendar)
        guard let startTrend = trendPounds(onOrBefore: start) else { return nil }
        return last.trendPounds - startTrend
    }

    /// Average change in trend weight per week over the window, for "↓ 4.6 lb in 5 weeks"
    /// style copy. Negative means loss.
    public func poundsPerWeek(overLast days: Int, calendar: Calendar = .current) -> Double? {
        guard days > 0, let change = trendChange(overLast: days, calendar: calendar)
        else { return nil }
        return change / (Double(days) / 7)
    }

    /// The number of days actually spanned by the readings, which is what the observed
    /// expenditure estimate must be divided by — not the number of readings, and not the
    /// nominal window the caller asked for.
    public func spannedDays(calendar: Calendar = .current) -> Int {
        guard let first = points.first, let last = points.last else { return 0 }
        return first.day.days(until: last.day, calendar: calendar)
    }
}

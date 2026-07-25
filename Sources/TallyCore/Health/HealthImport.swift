import Foundation

/// A body-mass reading as it arrives from Health, reduced to the fields Tally needs.
///
/// Deliberately not an `HKQuantitySample`: keeping the import rules expressed over plain values
/// means the interesting part — deduplication, which readings win, day bucketing — is testable
/// on any platform, and the HealthKit-specific code shrinks to a type conversion.
public struct HealthWeightReading: Hashable, Sendable {
    /// The HealthKit sample UUID, recorded on whatever Tally creates so the same reading is
    /// never imported twice.
    public var externalIdentifier: String
    public var date: Date
    public var pounds: Double

    public init(externalIdentifier: String, date: Date, pounds: Double) {
        self.externalIdentifier = externalIdentifier
        self.date = date
        self.pounds = pounds
    }
}

/// A workout as it arrives from Health.
public struct HealthWorkoutReading: Hashable, Sendable {
    public var externalIdentifier: String
    public var start: Date
    public var end: Date
    /// Active energy burned. Tally only ever imports the *active* figure, never total: total
    /// includes the basal calories the user would have burned lying still, and those are already
    /// accounted for in their expenditure estimate. Importing total would double-count them.
    public var activeCalories: Int
    /// Human-readable activity name, e.g. "Running".
    public var activityName: String
    public var kind: ExerciseKind

    public init(
        externalIdentifier: String,
        start: Date,
        end: Date,
        activeCalories: Int,
        activityName: String,
        kind: ExerciseKind
    ) {
        self.externalIdentifier = externalIdentifier
        self.start = start
        self.end = end
        self.activeCalories = activeCalories
        self.activityName = activityName
        self.kind = kind
    }

    public var durationMinutes: Int {
        max(0, Int((end.timeIntervalSince(start) / 60).rounded()))
    }
}

/// What an import would write. Returned rather than applied so the caller can save it in one
/// transaction, and so the decision-making is separable from the side effects.
public struct HealthImportPlan: Hashable, Sendable {
    public var weights: [WeightSample]
    public var entries: [Entry]

    public init(weights: [WeightSample] = [], entries: [Entry] = []) {
        self.weights = weights
        self.entries = entries
    }

    public var isEmpty: Bool { weights.isEmpty && entries.isEmpty }
    public var count: Int { weights.count + entries.count }
}

/// Decides what to bring across from Health.
public enum HealthImport {
    /// Workouts below this contribute nothing meaningful to a day's net and would clutter the
    /// log. Standing up counts as a workout to some devices.
    public static let minimumWorkoutCalories = 15

    /// Builds the set of records to write.
    ///
    /// The rules, and why:
    ///
    /// - **Anything already imported is skipped**, matched on `externalIdentifier`. The store
    ///   enforces this too with a unique index, but discovering it here means an import is
    ///   idempotent rather than merely safe — running it twice is a no-op, not an error.
    /// - **A manual weight reading is never overwritten.** If the user typed a number for a day,
    ///   that is the number they meant; silently replacing it with what the scale told Health
    ///   would be taking their data away from them.
    /// - **One weight per day, the earliest.** Weight is a morning measurement by convention and
    ///   the earliest reading is the most comparable across days; a late-evening reading on one
    ///   day and a morning one on the next would manufacture a swing that didn't happen.
    /// - **Trivial workouts are dropped**, see ``minimumWorkoutCalories``.
    ///
    /// - Parameters:
    ///   - existingExternalIdentifiers: identifiers Tally has already recorded.
    ///   - daysWithManualWeight: days whose weight the user entered by hand.
    public static func plan(
        weights: [HealthWeightReading],
        workouts: [HealthWorkoutReading],
        existingExternalIdentifiers: Set<String>,
        daysWithManualWeight: Set<Day>,
        calendar: Calendar = .current
    ) -> HealthImportPlan {
        var plan = HealthImportPlan()

        // MARK: Weights

        // Group by day, then take the earliest reading in each.
        var earliestByDay: [Day: HealthWeightReading] = [:]
        for reading in weights {
            guard reading.pounds > 0 else { continue }
            guard !existingExternalIdentifiers.contains(reading.externalIdentifier) else { continue }

            let day = Day(date: reading.date, calendar: calendar)
            guard !daysWithManualWeight.contains(day) else { continue }

            if let existing = earliestByDay[day], existing.date <= reading.date { continue }
            earliestByDay[day] = reading
        }

        plan.weights = earliestByDay
            .map { day, reading in
                WeightSample(
                    day: day,
                    pounds: reading.pounds,
                    measuredAt: reading.date,
                    source: .healthKit,
                    externalIdentifier: reading.externalIdentifier,
                    calendar: calendar
                )
            }
            .sorted { $0.day < $1.day }

        // MARK: Workouts

        plan.entries = workouts
            .filter { !existingExternalIdentifiers.contains($0.externalIdentifier) }
            .filter { $0.activeCalories >= minimumWorkoutCalories }
            .map { workout in
                Entry(
                    kind: .exercise,
                    label: label(for: workout),
                    calories: workout.activeCalories,
                    exerciseKind: workout.kind,
                    durationMinutes: workout.durationMinutes > 0 ? workout.durationMinutes : nil,
                    // Bucketed by when the workout *started*. A run beginning at 11:40pm belongs
                    // to the day the user thinks they ran, not to the day it happened to finish.
                    loggedAt: workout.start,
                    day: Day(date: workout.start, calendar: calendar),
                    source: .healthKit,
                    externalIdentifier: workout.externalIdentifier,
                    calendar: calendar
                )
            }
            .sorted { $0.loggedAt < $1.loggedAt }

        return plan
    }

    /// "Running · 38 min", or just the activity when the duration is unknown.
    static func label(for workout: HealthWorkoutReading) -> String {
        let name = workout.activityName.trimmingCharacters(in: .whitespacesAndNewlines)
        let activity = name.isEmpty ? "Workout" : name
        guard workout.durationMinutes > 0 else { return activity }
        return "\(activity) · \(workout.durationMinutes) min"
    }
}

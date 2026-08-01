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

/// A day's total active energy as Apple Health reports it.
///
/// This is the Move figure: everything burned above resting, workouts included. The planner
/// subtracts the workouts it logs separately, so what lands in the log beside them is the
/// movement that never belonged to a workout.
public struct HealthActivityReading: Hashable, Sendable {
    public var day: Day
    /// Total active energy for the whole day, in kilocalories.
    public var activeCalories: Int

    public init(day: Day, activeCalories: Int) {
        self.day = day
        self.activeCalories = activeCalories
    }
}

/// What an import would write. Returned rather than applied so the caller can save it in one
/// transaction, and so the decision-making is separable from the side effects.
public struct HealthImportPlan: Hashable, Sendable {
    public var weights: [WeightSample]
    public var entries: [Entry]
    /// Everyday-activity entries that should no longer exist — a day whose residual fell back
    /// under the threshold, or one Tally is no longer tracking. Only ever entries Tally wrote
    /// itself; a workout or a meal is never in here.
    public var deletions: [Entry.ID]

    public init(weights: [WeightSample] = [], entries: [Entry] = [], deletions: [Entry.ID] = []) {
        self.weights = weights
        self.entries = entries
        self.deletions = deletions
    }

    public var isEmpty: Bool { weights.isEmpty && entries.isEmpty && deletions.isEmpty }
    public var count: Int { weights.count + entries.count + deletions.count }
}

/// Decides what to bring across from Health.
public enum HealthImport {
    /// Workouts below this contribute nothing meaningful to a day's net and would clutter the
    /// log. Standing up counts as a workout to some devices. The same threshold applies to a
    /// day's leftover activity, for the same reason.
    public static let minimumWorkoutCalories = 15

    /// What the everyday-activity entry is called in the log.
    public static let activityLabel = "Everyday activity"

    /// External identifiers for the entries Tally synthesises from a day's activity.
    ///
    /// Derived from the day rather than from a HealthKit sample UUID, because there is no one
    /// sample behind it — the figure is a whole day's total, and it changes as the day goes on.
    /// A stable identifier per day is what lets the same row be rewritten instead of a new one
    /// piling up every hour.
    public static let activityIdentifierPrefix = "health.activity."

    public static func activityIdentifier(for day: Day) -> String {
        "\(activityIdentifierPrefix)\(day)"
    }

    public static func isActivityIdentifier(_ identifier: String) -> Bool {
        identifier.hasPrefix(activityIdentifierPrefix)
    }

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
    /// - **A day's leftover activity becomes one entry**, rewritten in place as the day goes on
    ///   rather than added to. See ``activityResidual(activeCalories:loggedWorkoutCalories:)``
    ///   for why it cannot simply be the day's active energy.
    /// - **A day Health reports nothing for is left alone.** No activity reading is not the same
    ///   as an activity reading of zero — a declined permission looks exactly like a still day —
    ///   and an entry is only removed on a reading that says it should be.
    ///
    /// - Parameters:
    ///   - activity: per-day active energy totals. Empty when the user hasn't switched measured
    ///     activity on, or for a range the app isn't tracking.
    ///   - existingEntries: the entries Tally already holds for the range being imported. Both
    ///     the deduplication of workouts and the rewriting of activity entries read from this.
    ///   - existingWeightIdentifiers: identifiers of weight samples already recorded.
    ///   - daysWithManualWeight: days whose weight the user entered by hand.
    ///   - activityTrackingStartDay: the day measured activity was switched on. Nil means the
    ///     planner has no opinion about activity entries at all — it neither writes nor removes
    ///     them, leaving any cleanup to the caller that turned the feature off.
    public static func plan(
        weights: [HealthWeightReading],
        workouts: [HealthWorkoutReading],
        activity: [HealthActivityReading] = [],
        existingEntries: [Entry],
        existingWeightIdentifiers: Set<String>,
        daysWithManualWeight: Set<Day>,
        activityTrackingStartDay: Day? = nil,
        calendar: Calendar = .current
    ) -> HealthImportPlan {
        var plan = HealthImportPlan()
        let existingExternalIdentifiers = Set(existingEntries.compactMap(\.externalIdentifier))

        // MARK: Weights

        // Group by day, then take the earliest reading in each.
        var earliestByDay: [Day: HealthWeightReading] = [:]
        for reading in weights {
            guard reading.pounds > 0 else { continue }
            guard !existingWeightIdentifiers.contains(reading.externalIdentifier) else { continue }

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

        // MARK: Everyday activity

        guard let trackingStart = activityTrackingStartDay else { return plan }

        let existingActivity = Dictionary(
            existingEntries.filter { isActivityIdentifier($0.externalIdentifier ?? "") }
                .map { ($0.day, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        let loggedWorkoutCalories = workoutCaloriesByDay(
            planned: plan.entries,
            existing: existingEntries
        )

        for reading in activity.sorted(by: { $0.day < $1.day }) where reading.day >= trackingStart {
            let existing = existingActivity[reading.day]
            let residual = activityResidual(
                activeCalories: reading.activeCalories,
                loggedWorkoutCalories: loggedWorkoutCalories[reading.day] ?? 0
            )

            guard residual >= minimumWorkoutCalories else {
                // Nothing worth showing. Any row from when there was gets taken away, so the
                // log doesn't keep claiming activity that Health no longer reports.
                if let existing { plan.deletions.append(existing.id) }
                continue
            }

            // An unchanged figure is not a write. This runs on every foreground and on every
            // background delivery, and a save would broadcast a data change and wake every
            // widget timeline for a number that didn't move.
            guard existing?.calories != residual else { continue }

            plan.entries.append(
                Entry(
                    // Reusing the row's own id is what makes this a rewrite. A fresh id would
                    // collide on the unique index over `externalIdentifier` instead.
                    id: existing?.id ?? UUID(),
                    kind: .exercise,
                    label: activityLabel,
                    calories: residual,
                    exerciseKind: .other,
                    // Sorts to the bottom of the day. This is ambient, not something that
                    // happened at a moment, and it would otherwise jump to the top of the log
                    // every time it was refreshed.
                    loggedAt: reading.day.startOfDay(calendar: calendar)
                        ?? reading.day.noon(calendar: calendar)
                        ?? Date(),
                    day: reading.day,
                    source: .healthKit,
                    externalIdentifier: activityIdentifier(for: reading.day),
                    calendar: calendar
                )
            )
        }

        return plan
    }

    /// The part of a day's active energy that no logged workout accounts for.
    ///
    /// Apple's Move figure includes workout calories, and Tally logs those workouts as their own
    /// entries. Crediting the day's whole active energy on top would count every workout twice —
    /// so what gets logged beside them is the remainder.
    ///
    /// Clamped at zero because the two figures come from different places and need not agree: a
    /// third-party app can write a workout whose energy never appears in the day's active-energy
    /// samples, which would otherwise leave a negative "activity" adding calories to the day.
    public static func activityResidual(activeCalories: Int, loggedWorkoutCalories: Int) -> Int {
        max(0, activeCalories - loggedWorkoutCalories)
    }

    /// Workout calories per day as they will stand once this plan is written.
    ///
    /// Both halves matter. Reading only the planned entries would miss workouts imported on an
    /// earlier run and subtract too little; reading only the stored ones would miss the workouts
    /// about to be written. Workouts below ``minimumWorkoutCalories`` appear in neither, and
    /// that is correct — they were never logged, so their calories legitimately stay in the
    /// residual rather than vanishing from the day.
    static func workoutCaloriesByDay(planned: [Entry], existing: [Entry]) -> [Day: Int] {
        var seen: Set<String> = []
        var totals: [Day: Int] = [:]

        for entry in planned + existing
        where entry.kind == .exercise
            && entry.source == .healthKit
            && !isActivityIdentifier(entry.externalIdentifier ?? "")
        {
            // Deduplicated by identifier: a workout already stored is also in the fetch that
            // produced the planned entries, and it must only be subtracted once.
            if let identifier = entry.externalIdentifier {
                guard seen.insert(identifier).inserted else { continue }
            }
            totals[entry.day, default: 0] += entry.calories
        }

        return totals
    }

    /// "Running · 38 min", or just the activity when the duration is unknown.
    static func label(for workout: HealthWorkoutReading) -> String {
        let name = workout.activityName.trimmingCharacters(in: .whitespacesAndNewlines)
        let activity = name.isEmpty ? "Workout" : name
        guard workout.durationMinutes > 0 else { return activity }
        return "\(activity) · \(workout.durationMinutes) min"
    }
}

import Foundation
import Testing
@testable import TallyCore

private let utc: Calendar = {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: "UTC")!
    return calendar
}()

private let jan1 = Day(year: 2026, month: 1, day: 1)
private let jan2 = Day(year: 2026, month: 1, day: 2)

private func at(_ day: Day, _ hour: Int, _ minute: Int = 0) -> Date {
    utc.date(from: DateComponents(
        year: day.year, month: day.month, day: day.day, hour: hour, minute: minute
    ))!
}

private func weight(
    _ id: String, _ date: Date, _ pounds: Double
) -> HealthWeightReading {
    HealthWeightReading(externalIdentifier: id, date: date, pounds: pounds)
}

private func workout(
    _ id: String,
    start: Date,
    minutes: Int = 38,
    calories: Int = 320,
    name: String = "Running",
    kind: ExerciseKind = .cardio
) -> HealthWorkoutReading {
    HealthWorkoutReading(
        externalIdentifier: id,
        start: start,
        end: start.addingTimeInterval(Double(minutes) * 60),
        activeCalories: calories,
        activityName: name,
        kind: kind
    )
}

private func activity(_ day: Day, _ calories: Int) -> HealthActivityReading {
    HealthActivityReading(day: day, activeCalories: calories)
}

/// A workout Tally imported on an earlier run.
private func importedWorkout(
    _ id: String,
    day: Day,
    calories: Int = 320,
    at hour: Int = 6
) -> Entry {
    Entry(
        kind: .exercise,
        label: "Run · 38 min",
        calories: calories,
        exerciseKind: .cardio,
        loggedAt: at(day, hour),
        day: day,
        source: .healthKit,
        externalIdentifier: id,
        calendar: utc
    )
}

/// An everyday-activity entry Tally wrote for a day, as it would come back out of the store.
private func importedActivity(_ day: Day, calories: Int, id: UUID = UUID()) -> Entry {
    Entry(
        id: id,
        kind: .exercise,
        label: HealthImport.activityLabel,
        calories: calories,
        exerciseKind: .other,
        loggedAt: at(day, 0),
        day: day,
        source: .healthKit,
        externalIdentifier: HealthImport.activityIdentifier(for: day),
        calendar: utc
    )
}

private func plan(
    weights: [HealthWeightReading] = [],
    workouts: [HealthWorkoutReading] = [],
    activity: [HealthActivityReading] = [],
    existingEntries: [Entry] = [],
    existingWeights: Set<String> = [],
    manualDays: Set<Day> = [],
    trackingStart: Day? = nil
) -> HealthImportPlan {
    HealthImport.plan(
        weights: weights,
        workouts: workouts,
        activity: activity,
        existingEntries: existingEntries,
        existingWeightIdentifiers: existingWeights,
        daysWithManualWeight: manualDays,
        activityTrackingStartDay: trackingStart,
        calendar: utc
    )
}

@Suite("Health import — weights")
struct HealthWeightImportTests {
    @Test("imports a reading as a HealthKit-sourced sample")
    func importsWeight() throws {
        let result = plan(weights: [weight("hk-1", at(jan1, 7), 168.4)])

        #expect(result.weights.count == 1)
        let sample = try #require(result.weights.first)
        #expect(sample.day == jan1)
        #expect(sample.pounds == 168.4)
        #expect(sample.source == .healthKit)
        #expect(sample.externalIdentifier == "hk-1")
    }

    /// Running an import twice must be a no-op, not merely safe. The store's unique index would
    /// also catch this, but noticing it here is what makes the operation idempotent.
    @Test("skips readings already imported")
    func skipsAlreadyImported() {
        let result = plan(
            weights: [weight("hk-1", at(jan1, 7), 168.4)],
            existingWeights: ["hk-1"]
        )
        #expect(result.isEmpty)
    }

    /// If the user typed a number for a day, that is the number they meant. Replacing it with
    /// whatever the scale told Health would be taking their own data away from them.
    @Test("never overwrites a manually entered weight")
    func respectsManualEntries() {
        let result = plan(
            weights: [weight("hk-1", at(jan1, 7), 168.4)],
            manualDays: [jan1]
        )
        #expect(result.weights.isEmpty)
    }

    @Test("still imports days the user hasn't entered by hand")
    func fillsUnenteredDays() {
        let result = plan(
            weights: [
                weight("hk-1", at(jan1, 7), 168.4),
                weight("hk-2", at(jan2, 7), 168.0),
            ],
            manualDays: [jan1]
        )

        #expect(result.weights.map(\.day) == [jan2])
    }

    /// A late-evening reading one day and a morning one the next would manufacture a swing that
    /// never happened, so the earliest reading in each day wins.
    @Test("keeps only the earliest reading of a day")
    func earliestReadingWins() throws {
        let result = plan(weights: [
            weight("evening", at(jan1, 21), 171.0),
            weight("morning", at(jan1, 6, 30), 168.4),
            weight("midday", at(jan1, 13), 169.5),
        ])

        #expect(result.weights.count == 1)
        let sample = try #require(result.weights.first)
        #expect(sample.pounds == 168.4)
        #expect(sample.externalIdentifier == "morning")
    }

    @Test("handles several days at once, oldest first")
    func multipleDaysOrdered() {
        let result = plan(weights: [
            weight("b", at(jan2, 7), 168.0),
            weight("a", at(jan1, 7), 168.4),
        ])

        #expect(result.weights.map(\.day) == [jan1, jan2])
    }

    @Test("ignores nonsensical weights")
    func ignoresNonsense() {
        let result = plan(weights: [
            weight("zero", at(jan1, 7), 0),
            weight("negative", at(jan2, 7), -10),
        ])
        #expect(result.weights.isEmpty)
    }

    /// The day a reading belongs to depends on the user's timezone, and this is where that
    /// gets decided — an instant late at night must not land on tomorrow.
    @Test("buckets a reading into the local day")
    func localDayBucketing() {
        let newYork: Calendar = {
            var calendar = Calendar(identifier: .gregorian)
            calendar.timeZone = TimeZone(identifier: "America/New_York")!
            return calendar
        }()

        // 2026-01-01 23:30 in New York is 2026-01-02 04:30 UTC.
        let lateEvening = newYork.date(from: DateComponents(
            year: 2026, month: 1, day: 1, hour: 23, minute: 30
        ))!

        let inNewYork = HealthImport.plan(
            weights: [weight("hk-1", lateEvening, 168.4)],
            workouts: [], existingEntries: [], existingWeightIdentifiers: [],
            daysWithManualWeight: [], calendar: newYork
        )
        #expect(inNewYork.weights.first?.day == jan1)

        let inUTC = plan(weights: [weight("hk-1", lateEvening, 168.4)])
        #expect(inUTC.weights.first?.day == jan2)
    }
}

@Suite("Health import — workouts")
struct HealthWorkoutImportTests {
    @Test("imports a workout as an exercise entry")
    func importsWorkout() throws {
        let result = plan(workouts: [workout("hk-w1", start: at(jan1, 6, 30))])

        #expect(result.entries.count == 1)
        let entry = try #require(result.entries.first)
        #expect(entry.kind == .exercise)
        #expect(entry.calories == 320)
        #expect(entry.exerciseKind == .cardio)
        #expect(entry.durationMinutes == 38)
        #expect(entry.source == .healthKit)
        #expect(entry.externalIdentifier == "hk-w1")
        // Exercise subtracts from the day's net.
        #expect(entry.signedCalories == -320)
    }

    @Test("labels a workout with its activity and duration")
    func labelling() {
        #expect(HealthImport.label(for: workout("x", start: at(jan1, 6), minutes: 38))
            == "Running · 38 min")

        // No duration to report.
        #expect(HealthImport.label(for: workout("x", start: at(jan1, 6), minutes: 0))
            == "Running")

        // Missing activity name still produces something readable.
        #expect(HealthImport.label(for: workout("x", start: at(jan1, 6), minutes: 20, name: "  "))
            == "Workout · 20 min")
    }

    @Test("skips workouts already imported")
    func skipsAlreadyImported() {
        let result = plan(
            workouts: [workout("hk-w1", start: at(jan1, 6))],
            existingEntries: [importedWorkout("hk-w1", day: jan1)]
        )
        #expect(result.isEmpty)
    }

    /// Some devices log standing up as a workout. A 3-calorie entry contributes nothing to the
    /// net and makes the day's log unreadable.
    @Test("drops trivial workouts")
    func dropsTrivialWorkouts() {
        let result = plan(workouts: [
            workout("tiny", start: at(jan1, 6), calories: 3),
            workout("real", start: at(jan1, 7), calories: 320),
        ])

        #expect(result.entries.map(\.externalIdentifier) == ["real"])
    }

    @Test("keeps a workout exactly at the threshold")
    func keepsThresholdWorkout() {
        let result = plan(workouts: [
            workout("edge", start: at(jan1, 6), calories: HealthImport.minimumWorkoutCalories)
        ])
        #expect(result.entries.count == 1)
    }

    /// A run beginning at 11:40pm belongs to the day the user thinks they ran, not the day it
    /// happened to finish.
    @Test("buckets a workout by when it started, not when it ended")
    func bucketsByStart() {
        let nearMidnight = at(jan1, 23, 40)
        let result = plan(workouts: [
            workout("overnight", start: nearMidnight, minutes: 40)
        ])

        #expect(result.entries.first?.day == jan1)
    }

    @Test("orders entries chronologically")
    func chronologicalOrder() {
        let result = plan(workouts: [
            workout("later", start: at(jan1, 18)),
            workout("earlier", start: at(jan1, 6)),
        ])

        #expect(result.entries.map(\.externalIdentifier) == ["earlier", "later"])
    }

    @Test("preserves the workout kind", arguments: [
        ExerciseKind.cardio, .strength, .other,
    ])
    func preservesKind(_ kind: ExerciseKind) {
        let result = plan(workouts: [workout("x", start: at(jan1, 6), kind: kind)])
        #expect(result.entries.first?.exerciseKind == kind)
    }
}

@Suite("Health import — everyday activity")
struct HealthActivityImportTests {
    /// The whole point of the feature: the movement that wasn't a workout reaches the day's net.
    @Test("logs a day's activity as one entry")
    func logsActivity() throws {
        let result = plan(activity: [activity(jan1, 480)], trackingStart: jan1)

        #expect(result.entries.count == 1)
        let entry = try #require(result.entries.first)
        #expect(entry.kind == .exercise)
        #expect(entry.calories == 480)
        #expect(entry.label == HealthImport.activityLabel)
        #expect(entry.exerciseKind == .other)
        #expect(entry.day == jan1)
        #expect(entry.source == .healthKit)
        #expect(entry.externalIdentifier == HealthImport.activityIdentifier(for: jan1))
        #expect(entry.signedCalories == -480)
    }

    /// The double-count check, and the reason this can't simply be the day's active energy:
    /// Apple's Move figure already contains every workout Tally logs beside it.
    @Test("subtracts workouts this plan is about to write")
    func subtractsPlannedWorkouts() {
        let result = plan(
            workouts: [workout("run", start: at(jan1, 6), calories: 320)],
            activity: [activity(jan1, 480)],
            trackingStart: jan1
        )

        let activityEntry = result.entries.first { $0.label == HealthImport.activityLabel }
        #expect(activityEntry?.calories == 160)
    }

    /// A workout imported on an earlier run is not in this plan's entries, but its calories are
    /// still in the day's Move total and still in the log.
    @Test("subtracts workouts imported earlier")
    func subtractsStoredWorkouts() {
        let result = plan(
            workouts: [workout("run", start: at(jan1, 6), calories: 320)],
            activity: [activity(jan1, 480)],
            existingEntries: [importedWorkout("run", day: jan1, calories: 320)],
            trackingStart: jan1
        )

        #expect(result.entries.count == 1)
        #expect(result.entries.first?.calories == 160)
    }

    /// A workout in both places must only come off once, or the residual is understated by a
    /// whole workout.
    @Test("does not subtract the same workout twice")
    func subtractsOnce() {
        let stored = importedWorkout("run", day: jan1, calories: 320)
        let result = plan(
            workouts: [workout("run", start: at(jan1, 6), calories: 320)],
            activity: [activity(jan1, 480)],
            existingEntries: [stored],
            trackingStart: jan1
        )

        #expect(result.entries.first?.calories == 160)
    }

    /// A workout too small to log keeps its calories in the residual — they happened, and the
    /// day's Move figure counted them.
    @Test("keeps a trivial workout's calories in the residual")
    func trivialWorkoutStaysInResidual() {
        let result = plan(
            workouts: [workout("tiny", start: at(jan1, 6), calories: 3)],
            activity: [activity(jan1, 480)],
            trackingStart: jan1
        )

        #expect(result.entries.map(\.externalIdentifier)
            == [HealthImport.activityIdentifier(for: jan1)])
        #expect(result.entries.first?.calories == 480)
    }

    /// The two figures come from different places and need not agree. A negative residual would
    /// be an exercise entry that *adds* calories to the day.
    @Test("clamps a negative residual to nothing")
    func clampsNegative() {
        let result = plan(
            workouts: [workout("long", start: at(jan1, 6), calories: 900)],
            activity: [activity(jan1, 480)],
            trackingStart: jan1
        )

        #expect(result.entries.map(\.externalIdentifier) == ["long"])
        #expect(result.deletions.isEmpty)
    }

    @Test("drops a residual too small to be worth a row")
    func dropsTrivialResidual() {
        let result = plan(
            workouts: [workout("run", start: at(jan1, 6), calories: 470)],
            activity: [activity(jan1, 480)],
            trackingStart: jan1
        )

        #expect(result.entries.map(\.externalIdentifier) == ["run"])
    }

    /// The identity that makes an hourly refresh sustainable: the row is rewritten, not added to.
    @Test("rewrites the existing entry rather than adding one")
    func rewritesInPlace() throws {
        let existing = importedActivity(jan1, calories: 300)
        let result = plan(
            activity: [activity(jan1, 480)],
            existingEntries: [existing],
            trackingStart: jan1
        )

        #expect(result.entries.count == 1)
        let entry = try #require(result.entries.first)
        // Same row: the store upserts on id, and a fresh one would collide on the unique index
        // over externalIdentifier instead.
        #expect(entry.id == existing.id)
        #expect(entry.calories == 480)
    }

    /// This runs on every foreground and every background delivery. A write that changes nothing
    /// still broadcasts a data change and wakes every widget timeline.
    @Test("writes nothing when the figure hasn't moved")
    func skipsUnchanged() {
        let result = plan(
            activity: [activity(jan1, 480)],
            existingEntries: [importedActivity(jan1, calories: 480)],
            trackingStart: jan1
        )

        #expect(result.isEmpty)
    }

    @Test("removes an entry whose activity fell away")
    func removesStaleEntry() {
        let existing = importedActivity(jan1, calories: 300)
        let result = plan(
            workouts: [workout("run", start: at(jan1, 6), calories: 470)],
            activity: [activity(jan1, 480)],
            existingEntries: [existing],
            trackingStart: jan1
        )

        #expect(result.deletions == [existing.id])
        #expect(result.entries.map(\.externalIdentifier) == ["run"])
    }

    /// Days before the switch was thrown were logged without any activity credit. Writing one
    /// for them now would rewrite history the user's weight trend was measured against.
    @Test("ignores days before tracking started")
    func ignoresDaysBeforeStart() {
        let result = plan(
            activity: [activity(jan1, 480), activity(jan2, 500)],
            trackingStart: jan2
        )

        #expect(result.entries.map(\.day) == [jan2])
    }

    /// No reading is not a reading of zero — a declined permission looks exactly like a still
    /// day, and taking an entry away on that evidence would be guessing.
    @Test("leaves a day Health said nothing about alone")
    func leavesSilentDaysAlone() {
        let existing = importedActivity(jan1, calories: 300)
        let result = plan(
            activity: [activity(jan2, 500)],
            existingEntries: [existing],
            trackingStart: jan1
        )

        #expect(result.deletions.isEmpty)
        #expect(result.entries.map(\.day) == [jan2])
    }

    /// With the feature off the planner has no opinion at all: it neither writes activity nor
    /// takes it away, so switching off is the caller's to handle deliberately.
    @Test("does nothing with activity while tracking is off")
    func inertWhenNotTracking() {
        let result = plan(
            activity: [activity(jan1, 480)],
            existingEntries: [importedActivity(jan1, calories: 300)]
        )

        #expect(result.isEmpty)
    }

    @Test("counts a removal towards the plan's size")
    func deletionsCount() {
        let result = plan(
            activity: [activity(jan1, 5)],
            existingEntries: [importedActivity(jan1, calories: 300)],
            trackingStart: jan1
        )

        #expect(result.isEmpty == false)
        #expect(result.count == 1)
    }
}

@Suite("Health import — combined")
struct HealthImportCombinedTests {
    @Test("plans weights and workouts together")
    func combined() {
        let result = plan(
            weights: [weight("hk-1", at(jan1, 7), 168.4)],
            workouts: [workout("hk-w1", start: at(jan1, 6, 30))]
        )

        #expect(result.weights.count == 1)
        #expect(result.entries.count == 1)
        #expect(result.count == 2)
        #expect(result.isEmpty == false)
    }

    @Test("an empty source produces an empty plan")
    func emptyInput() {
        #expect(plan().isEmpty)
        #expect(plan().count == 0)
    }

    /// The property that matters most for a repeated background import: applying a plan and
    /// re-planning with those identifiers recorded yields nothing.
    @Test("is idempotent once identifiers are recorded")
    func idempotent() {
        let weights = [weight("hk-1", at(jan1, 7), 168.4)]
        let workouts = [workout("hk-w1", start: at(jan1, 6, 30))]

        let first = plan(weights: weights, workouts: workouts)
        #expect(first.count == 2)

        let second = plan(
            weights: weights,
            workouts: workouts,
            existingEntries: first.entries,
            existingWeights: Set(first.weights.compactMap(\.externalIdentifier))
        )

        #expect(second.isEmpty)
    }
}

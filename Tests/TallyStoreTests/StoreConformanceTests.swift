import Foundation
import Testing
import TallyCore
@testable import TallyStore

/// Which conformance is under test.
///
/// Every test in this suite runs against both. The in-memory stores define the reference
/// semantics and SQLite has to match them — running one suite over both is what stops the two
/// from quietly diverging, which would otherwise show up as tests passing while the shipping
/// app misbehaves.
enum StoreImplementation: String, CaseIterable, Sendable, CustomTestStringConvertible {
    case inMemory
    case sqlite

    func makeStores() throws -> StoreBundle {
        switch self {
        case .inMemory: StoreBundle.inMemory()
        case .sqlite: try TallyDatabase.inMemoryStores()
        }
    }

    var testDescription: String { rawValue }
}

// Fixed reference days, so nothing depends on when the suite runs.
private let jan1 = Day(year: 2026, month: 1, day: 1)
private let jan2 = Day(year: 2026, month: 1, day: 2)
private let jan3 = Day(year: 2026, month: 1, day: 3)
private let dec31 = Day(year: 2025, month: 12, day: 31)

private func at(_ day: Day, hour: Int, minute: Int = 0) -> Date {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: "UTC")!
    return calendar.date(from: DateComponents(
        year: day.year, month: day.month, day: day.day, hour: hour, minute: minute
    ))!
}

@Suite("Entry store")
struct EntryStoreTests {
    @Test("preserves every field through a save and fetch", arguments: StoreImplementation.allCases)
    func roundTrip(_ implementation: StoreImplementation) throws {
        let store = try implementation.makeStores().entries
        let original = Entry(
            kind: .exercise,
            label: "Zone 2 run · 38 min",
            calories: 320,
            exerciseKind: .cardio,
            durationMinutes: 38,
            loggedAt: at(jan2, hour: 6, minute: 30),
            day: jan2,
            source: .llmVoice,
            rawInput: "ran about 38 minutes, easy pace",
            confidence: .medium,
            externalIdentifier: "healthkit-abc"
        )

        try store.save(original)
        let fetched = try store.entry(id: original.id)

        #expect(fetched == original)
    }

    @Test("saving the same id twice updates rather than duplicates",
          arguments: StoreImplementation.allCases)
    func upsertById(_ implementation: StoreImplementation) throws {
        let store = try implementation.makeStores().entries
        var entry = Entry(kind: .food, label: "Toast", calories: 200, day: jan1)

        try store.save(entry)
        entry.label = "Sourdough toast with butter"
        entry.calories = 340
        try store.save(entry)

        let onDay = try store.entries(on: jan1)
        #expect(onDay.count == 1)
        #expect(onDay.first?.label == "Sourdough toast with butter")
        #expect(onDay.first?.calories == 340)
    }

    @Test("deletes only the requested entry", arguments: StoreImplementation.allCases)
    func delete(_ implementation: StoreImplementation) throws {
        let store = try implementation.makeStores().entries
        let keep = Entry(kind: .food, label: "Keep", calories: 100, day: jan1)
        let remove = Entry(kind: .food, label: "Remove", calories: 200, day: jan1)
        try store.save([keep, remove])

        try store.delete(id: remove.id)

        #expect(try store.entries(on: jan1).map(\.label) == ["Keep"])
        #expect(try store.entry(id: remove.id) == nil)
    }

    @Test("deleting an absent id is a no-op rather than an error",
          arguments: StoreImplementation.allCases)
    func deleteMissing(_ implementation: StoreImplementation) throws {
        let store = try implementation.makeStores().entries
        try store.delete(id: UUID())
    }

    @Test("returns a day's entries newest first", arguments: StoreImplementation.allCases)
    func displayOrdering(_ implementation: StoreImplementation) throws {
        let store = try implementation.makeStores().entries
        try store.save([
            Entry(kind: .food, label: "breakfast", calories: 280,
                  loggedAt: at(jan1, hour: 8), day: jan1),
            Entry(kind: .exercise, label: "run", calories: 320,
                  exerciseKind: .cardio, loggedAt: at(jan1, hour: 6), day: jan1),
            Entry(kind: .food, label: "lunch", calories: 640,
                  loggedAt: at(jan1, hour: 12), day: jan1),
        ])

        #expect(try store.entries(on: jan1).map(\.label) == ["lunch", "breakfast", "run"])
    }

    @Test("scopes a day query to that day", arguments: StoreImplementation.allCases)
    func dayScoping(_ implementation: StoreImplementation) throws {
        let store = try implementation.makeStores().entries
        try store.save([
            Entry(kind: .food, label: "on jan 1", calories: 100, day: jan1),
            Entry(kind: .food, label: "on jan 2", calories: 200, day: jan2),
        ])

        #expect(try store.entries(on: jan1).map(\.label) == ["on jan 1"])
        #expect(try store.entries(on: jan2).map(\.label) == ["on jan 2"])
        #expect(try store.entries(on: jan3).isEmpty)
    }

    /// Days are stored as "YYYY-MM-DD" text, and range queries compare them as strings. That
    /// only works because the format is zero-padded and big-endian — this pins it, including
    /// across a year boundary where a naive format would break.
    @Test("range queries are inclusive and order correctly across a year boundary",
          arguments: StoreImplementation.allCases)
    func rangeAcrossYearBoundary(_ implementation: StoreImplementation) throws {
        let store = try implementation.makeStores().entries
        try store.save([
            Entry(kind: .food, label: "dec 31", calories: 100, day: dec31),
            Entry(kind: .food, label: "jan 1", calories: 200, day: jan1),
            Entry(kind: .food, label: "jan 2", calories: 300, day: jan2),
            Entry(kind: .food, label: "jan 3", calories: 400, day: jan3),
        ])

        let inRange = try store.entries(from: dec31, through: jan2)
        #expect(Set(inRange.map(\.label)) == ["dec 31", "jan 1", "jan 2"])

        // Single-day range includes that day.
        #expect(try store.entries(from: jan1, through: jan1).map(\.label) == ["jan 1"])
        // Inverted range yields nothing rather than everything.
        #expect(try store.entries(from: jan3, through: jan1).isEmpty)
    }

    @Test("totals subtract exercise and count macros from food only",
          arguments: StoreImplementation.allCases)
    func totalsArithmetic(_ implementation: StoreImplementation) throws {
        let store = try implementation.makeStores().entries
        try store.save([
            Entry(kind: .food, label: "yogurt", calories: 280,
                  proteinGrams: 24, fiberGrams: 4, day: jan1),
            Entry(kind: .food, label: "chicken bowl", calories: 640,
                  proteinGrams: 48, fiberGrams: 9, day: jan1),
            Entry(kind: .food, label: "eggs", calories: 340,
                  proteinGrams: 18, fiberGrams: 3, day: jan1),
            Entry(kind: .food, label: "apple & almonds", calories: 280,
                  proteinGrams: 6, fiberGrams: 6, day: jan1),
            Entry(kind: .exercise, label: "run", calories: 320,
                  exerciseKind: .cardio, day: jan1),
        ])

        let totals = try store.totals(on: jan1)

        // Mirrors the design's Today screen: food 1,540, exercise −320, net 1,220.
        #expect(totals.foodCalories == 1540)
        #expect(totals.exerciseCalories == 320)
        #expect(totals.netCalories == 1220)
        #expect(totals.proteinGrams == 96)
        #expect(totals.fiberGrams == 22)
        #expect(totals.entryCount == 5)
    }

    @Test("an empty day totals to zero, not to nil", arguments: StoreImplementation.allCases)
    func totalsForEmptyDay(_ implementation: StoreImplementation) throws {
        let store = try implementation.makeStores().entries
        #expect(try store.totals(on: jan1) == .empty)
        #expect(try store.totals(on: jan1).isEmpty)
    }

    /// Exercise-only days are the case a naive `SUM(calories)` gets wrong: the net has to go
    /// negative, not report the exercise as intake.
    @Test("an exercise-only day nets negative", arguments: StoreImplementation.allCases)
    func exerciseOnlyDay(_ implementation: StoreImplementation) throws {
        let store = try implementation.makeStores().entries
        try store.save(Entry(kind: .exercise, label: "run", calories: 500,
                             exerciseKind: .cardio, day: jan1))

        let totals = try store.totals(on: jan1)
        #expect(totals.foodCalories == 0)
        #expect(totals.exerciseCalories == 500)
        #expect(totals.netCalories == -500)
        #expect(totals.proteinGrams == 0)
    }

    @Test("range totals group by day and omit days with no entries",
          arguments: StoreImplementation.allCases)
    func rangeTotals(_ implementation: StoreImplementation) throws {
        let store = try implementation.makeStores().entries
        try store.save([
            Entry(kind: .food, label: "a", calories: 500, proteinGrams: 30, day: jan1),
            Entry(kind: .exercise, label: "b", calories: 100,
                  exerciseKind: .cardio, day: jan1),
            // jan2 deliberately left empty.
            Entry(kind: .food, label: "c", calories: 700, proteinGrams: 40, day: jan3),
        ])

        let totals = try store.totals(from: jan1, through: jan3)

        #expect(totals.count == 2)
        #expect(totals[jan1]?.netCalories == 400)
        #expect(totals[jan1]?.proteinGrams == 30)
        #expect(totals[jan3]?.netCalories == 700)
        // Absent rather than zero — callers supply their own default.
        #expect(totals[jan2] == nil)
    }

    @Test("reports external identifiers so an import can skip what it already brought across",
          arguments: StoreImplementation.allCases)
    func externalIdentifiers(_ implementation: StoreImplementation) throws {
        let store = try implementation.makeStores().entries
        try store.save([
            Entry(kind: .exercise, label: "imported", calories: 300, exerciseKind: .cardio,
                  day: jan1, source: .healthKit, externalIdentifier: "hk-1"),
            Entry(kind: .exercise, label: "also imported", calories: 200, exerciseKind: .strength,
                  day: jan2, source: .healthKit, externalIdentifier: "hk-2"),
            Entry(kind: .food, label: "typed by hand", calories: 100, day: jan1),
        ])

        #expect(try store.externalIdentifiers(from: jan1, through: jan2) == ["hk-1", "hk-2"])
        #expect(try store.externalIdentifiers(from: jan1, through: jan1) == ["hk-1"])
        #expect(try store.externalIdentifiers(from: jan3, through: jan3).isEmpty)
    }

    @Test("saving an empty batch is a no-op", arguments: StoreImplementation.allCases)
    func emptyBatch(_ implementation: StoreImplementation) throws {
        let store = try implementation.makeStores().entries
        try store.save([])
        #expect(try store.entries(on: jan1).isEmpty)
    }
}

@Suite("Weight store")
struct WeightStoreTests {
    @Test("preserves every field through a save and fetch", arguments: StoreImplementation.allCases)
    func roundTrip(_ implementation: StoreImplementation) throws {
        let store = try implementation.makeStores().weights
        let sample = WeightSample(
            day: jan1,
            pounds: 168.4,
            measuredAt: at(jan1, hour: 7),
            source: .healthKit,
            externalIdentifier: "hk-weight-1"
        )

        try store.save(sample)

        #expect(try store.sample(on: jan1) == sample)
    }

    /// The design offers a single "log today's weight" action. Using it twice should correct
    /// today's number, not stack two readings — and the caller shouldn't have to find the
    /// existing row's id to make that happen.
    @Test("a second reading for a day replaces the first",
          arguments: StoreImplementation.allCases)
    func oneSamplePerDay(_ implementation: StoreImplementation) throws {
        let store = try implementation.makeStores().weights
        try store.save(WeightSample(day: jan1, pounds: 170.0, measuredAt: at(jan1, hour: 7)))
        try store.save(WeightSample(day: jan1, pounds: 168.2, measuredAt: at(jan1, hour: 19)))

        let samples = try store.samples(from: jan1, through: jan1)
        #expect(samples.count == 1)
        #expect(samples.first?.pounds == 168.2)
    }

    @Test("returns samples oldest first", arguments: StoreImplementation.allCases)
    func chronologicalOrder(_ implementation: StoreImplementation) throws {
        let store = try implementation.makeStores().weights
        try store.save(WeightSample(day: jan3, pounds: 168.0))
        try store.save(WeightSample(day: dec31, pounds: 170.0))
        try store.save(WeightSample(day: jan1, pounds: 169.5))

        #expect(try store.allSamples().map(\.pounds) == [170.0, 169.5, 168.0])
        #expect(try store.samples(from: dec31, through: jan1).map(\.pounds) == [170.0, 169.5])
    }

    /// "Current weight" has to survive a day with no reading — most people don't weigh in daily.
    @Test("finds the most recent reading at or before a day",
          arguments: StoreImplementation.allCases)
    func latestOnOrBefore(_ implementation: StoreImplementation) throws {
        let store = try implementation.makeStores().weights
        try store.save(WeightSample(day: dec31, pounds: 170.0))
        try store.save(WeightSample(day: jan2, pounds: 168.4))

        #expect(try store.latestSample(onOrBefore: jan3)?.pounds == 168.4)
        // Falls back past a day with no reading.
        #expect(try store.latestSample(onOrBefore: jan1)?.pounds == 170.0)
        // Inclusive of the day itself.
        #expect(try store.latestSample(onOrBefore: jan2)?.pounds == 168.4)
        // Nothing recorded yet at that point in time.
        #expect(try store.latestSample(onOrBefore: Day(year: 2020, month: 1, day: 1)) == nil)
    }

    @Test("deletes by id", arguments: StoreImplementation.allCases)
    func delete(_ implementation: StoreImplementation) throws {
        let store = try implementation.makeStores().weights
        let sample = WeightSample(day: jan1, pounds: 168.4)
        try store.save(sample)

        try store.delete(id: sample.id)

        #expect(try store.sample(on: jan1) == nil)
        #expect(try store.allSamples().isEmpty)
    }

    @Test("has no samples when empty", arguments: StoreImplementation.allCases)
    func emptyStore(_ implementation: StoreImplementation) throws {
        let store = try implementation.makeStores().weights
        #expect(try store.allSamples().isEmpty)
        #expect(try store.sample(on: jan1) == nil)
    }
}

@Suite("Settings store")
struct SettingsStoreTests {
    @Test("returns defaults before anything is written",
          arguments: StoreImplementation.allCases)
    func defaultsWhenEmpty(_ implementation: StoreImplementation) throws {
        let store = try implementation.makeStores().settings
        #expect(try store.profile() == .default)
        #expect(try store.goalSettings() == .default)
    }

    @Test("round-trips a profile", arguments: StoreImplementation.allCases)
    func profileRoundTrip(_ implementation: StoreImplementation) throws {
        let store = try implementation.makeStores().settings
        let profile = UserProfile(
            birthDate: at(Day(year: 1990, month: 6, day: 15), hour: 12),
            heightCentimeters: 178,
            biologicalSex: .female,
            activityLevel: .moderate,
            massUnit: .kilograms,
            activityLevelIncludesLoggedExercise: true
        )

        try store.save(profile)

        #expect(try store.profile() == profile)
    }

    @Test("round-trips goal settings", arguments: StoreImplementation.allCases)
    func goalRoundTrip(_ implementation: StoreImplementation) throws {
        let store = try implementation.makeStores().settings
        let goal = GoalSettings(
            targetPounds: 155,
            rate: .aggressive,
            proteinTargetGrams: 160,
            fiberTargetGrams: 40,
            manualCalorieGoal: 2000
        )

        try store.save(goal)

        #expect(try store.goalSettings() == goal)
    }

    /// Both settings objects share one row, so a partial write is the obvious way to lose data.
    @Test("writing one settings object leaves the other intact",
          arguments: StoreImplementation.allCases)
    func partialWritesPreserveTheOther(_ implementation: StoreImplementation) throws {
        let store = try implementation.makeStores().settings
        let profile = UserProfile(heightCentimeters: 180, biologicalSex: .male)
        let goal = GoalSettings(targetPounds: 155, rate: .gentle)

        try store.save(profile)
        try store.save(goal)
        #expect(try store.profile() == profile)
        #expect(try store.goalSettings() == goal)

        // Now overwrite just the profile; the goal must survive.
        let updated = UserProfile(heightCentimeters: 181, biologicalSex: .male)
        try store.save(updated)
        #expect(try store.profile() == updated)
        #expect(try store.goalSettings() == goal)
    }

    @Test("a nil target weight survives the round trip",
          arguments: StoreImplementation.allCases)
    func nilTargetSurvives(_ implementation: StoreImplementation) throws {
        let store = try implementation.makeStores().settings
        let goal = GoalSettings(targetPounds: nil, manualCalorieGoal: nil)
        try store.save(goal)

        let loaded = try store.goalSettings()
        #expect(loaded.targetPounds == nil)
        #expect(loaded.manualCalorieGoal == nil)
    }
}

@Suite("Change notifications")
struct ChangeNotificationTests {
    @Test("an entry write notifies entry listeners",
          arguments: StoreImplementation.allCases)
    func entryWriteNotifies(_ implementation: StoreImplementation) async throws {
        let stores = try implementation.makeStores()
        var iterator = stores.changes.stream(for: [.entries]).makeAsyncIterator()

        try stores.entries.save(Entry(kind: .food, label: "toast", calories: 200, day: jan1))

        #expect(await iterator.next() == .entries)
    }

    /// Cross-screen freshness depends on this: logging a weight on Progress has to be able to
    /// wake Today, and the three stores share one broadcaster to make that possible.
    @Test("a weight write notifies weight listeners",
          arguments: StoreImplementation.allCases)
    func weightWriteNotifies(_ implementation: StoreImplementation) async throws {
        let stores = try implementation.makeStores()
        var iterator = stores.changes.stream(for: [.weights]).makeAsyncIterator()

        try stores.weights.save(WeightSample(day: jan1, pounds: 168.4))

        #expect(await iterator.next() == .weights)
    }

    @Test("a settings write notifies settings listeners",
          arguments: StoreImplementation.allCases)
    func settingsWriteNotifies(_ implementation: StoreImplementation) async throws {
        let stores = try implementation.makeStores()
        var iterator = stores.changes.stream(for: [.settings]).makeAsyncIterator()

        try stores.settings.save(GoalSettings(targetPounds: 155))

        #expect(await iterator.next() == .settings)
    }

    /// A listener watching one kind must not be woken by another, or every screen redraws on
    /// every write.
    @Test("an entry write does not notify a weight-only listener",
          arguments: StoreImplementation.allCases)
    func filteringAcrossStores(_ implementation: StoreImplementation) async throws {
        let stores = try implementation.makeStores()
        var iterator = stores.changes.stream(for: [.weights]).makeAsyncIterator()

        try stores.entries.save(Entry(kind: .food, label: "toast", calories: 200, day: jan1))
        try stores.weights.save(WeightSample(day: jan1, pounds: 168.4))

        // The entry write is filtered out, so the first delivered change is the weight one.
        #expect(await iterator.next() == .weights)
    }

    @Test("listeners filtered to one kind ignore the others")
    func filteringIgnoresOtherKinds() async throws {
        let broadcaster = DataChangeBroadcaster()
        var iterator = broadcaster.stream(for: [.weights]).makeAsyncIterator()

        broadcaster.send(.entries)
        broadcaster.send(.settings)
        broadcaster.send(.weights)

        #expect(await iterator.next() == .weights)
    }
}

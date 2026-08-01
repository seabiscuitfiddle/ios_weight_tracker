import Foundation
import HealthKit
import TallyCore

/// Brings weight and workouts across from Apple Health.
///
/// Read-only: Tally never writes to Health. It also never *syncs* — this is a one-directional
/// import the user triggers, so the app's promise that nothing leaves the device holds.
///
/// This type is only the HealthKit half: querying, and converting `HKSample` into plain values.
/// Every decision about what to keep — deduplication, which reading of a day wins, not clobbering
/// a manual entry — lives in ``HealthImport`` in TallyCore, where it is unit-tested. That split is
/// deliberate: HealthKit cannot be exercised in tests, so as little logic as possible lives here.
@MainActor
final class HealthKitImporter {
    private let store = HKHealthStore()

    /// False on devices without Health, such as iPad. Callers should hide the feature entirely
    /// rather than offering something that cannot work.
    static var isAvailable: Bool { HKHealthStore.isHealthDataAvailable() }

    private var bodyMassType: HKQuantityType { HKQuantityType(.bodyMass) }
    private var activeEnergyType: HKQuantityType { HKQuantityType(.activeEnergyBurned) }

    private var readTypes: Set<HKObjectType> {
        [bodyMassType, activeEnergyType, HKObjectType.workoutType()]
    }

    /// Asks for read access.
    ///
    /// Note that HealthKit deliberately does not tell you whether the user said yes to *reads* —
    /// that would itself leak health information. So this cannot be checked, only attempted: a
    /// declined type simply returns no samples, which is indistinguishable from having none.
    /// That is why the UI reports "nothing new" rather than claiming success.
    ///
    /// Guarded on the master switch as well as on availability. The prompt this raises is the
    /// most visible thing the integration does, and a user who hasn't switched Health on should
    /// never see it.
    func requestAuthorization(profile: UserProfile) async throws {
        guard profile.health.isEnabled else { throw HealthImportError.switchedOff }
        guard Self.isAvailable else { throw HealthImportError.unavailable }
        try await store.requestAuthorization(toShare: [], read: readTypes)
    }

    /// How far back the Settings button reaches.
    static let manualImportDays = 90

    /// How far back an activity refresh reaches.
    ///
    /// Today is the day that matters, but a watch that spent the evening off the wrist writes
    /// yesterday's calories later, and a rewrite is cheap: one statistics query and, for days
    /// whose figure hasn't moved, no write at all.
    static let activityRefreshDays = 7

    /// Brings Health and Tally into step over `days` of history, and returns how many records
    /// changed.
    ///
    /// - Parameters:
    ///   - days: how far back to look.
    ///   - profile: read for the two Health switches. Nothing is queried while the master
    ///     switch is off, and the day's activity is only reconciled while measured activity is
    ///     on — see ``UserProfile/usesMeasuredActivity``.
    /// - Returns: the number of records written or removed, which may legitimately be zero —
    ///   either because there is nothing new or because the user declined access.
    @discardableResult
    func sync(
        days: Int = HealthKitImporter.manualImportDays,
        into stores: StoreBundle,
        profile: UserProfile
    ) async throws -> Int {
        guard profile.health.isEnabled else { throw HealthImportError.switchedOff }
        guard Self.isAvailable else { throw HealthImportError.unavailable }

        let calendar = Calendar.current
        let today = Day.today(calendar: calendar)
        let start = today.adding(days: -days, calendar: calendar)
        guard let startDate = start.startOfDay(calendar: calendar) ?? start.noon(calendar: calendar)
        else { throw HealthImportError.unavailable }

        let weights = try await fetchWeights(since: startDate)
        let workouts = try await fetchWorkouts(since: startDate)
        let activity = profile.usesMeasuredActivity
            ? try await fetchDailyActiveEnergy(from: start, through: today, calendar: calendar)
            : []

        // Everything Tally already knows, so the import is idempotent.
        let existingEntries = try stores.entries.entries(from: start, through: today)
        let storedWeights = try stores.weights.samples(from: start, through: today)
        let manualDays = Set(storedWeights.filter { $0.source != .healthKit }.map(\.day))

        let plan = HealthImport.plan(
            weights: weights,
            workouts: workouts,
            activity: activity,
            existingEntries: existingEntries,
            existingWeightIdentifiers: Set(storedWeights.compactMap(\.externalIdentifier)),
            daysWithManualWeight: manualDays,
            activityTrackingStartDay: profile.usesMeasuredActivity
                ? profile.health.activityTrackingStartDay
                : nil,
            calendar: calendar
        )

        for sample in plan.weights {
            try stores.weights.save(sample)
        }
        if !plan.entries.isEmpty {
            try stores.entries.save(plan.entries)
        }
        for id in plan.deletions {
            try stores.entries.delete(id: id)
        }

        return plan.count
    }

    // MARK: Queries

    private func fetchWeights(since startDate: Date) async throws -> [HealthWeightReading] {
        let predicate = HKQuery.predicateForSamples(withStart: startDate, end: nil)
        let descriptor = HKSampleQueryDescriptor(
            predicates: [.quantitySample(type: bodyMassType, predicate: predicate)],
            sortDescriptors: [SortDescriptor(\.startDate)]
        )

        return try await descriptor.result(for: store).map { sample in
            HealthWeightReading(
                externalIdentifier: sample.uuid.uuidString,
                date: sample.startDate,
                pounds: sample.quantity.doubleValue(for: .pound())
            )
        }
    }

    /// Active energy totalled per day.
    ///
    /// A statistics collection rather than the raw samples: the Watch writes active energy in
    /// short bursts, so a busy week is thousands of rows to fetch and add up by hand, and
    /// HealthKit will do exactly that sum in the daily buckets the log is organised by anyway.
    private func fetchDailyActiveEnergy(
        from start: Day,
        through end: Day,
        calendar: Calendar
    ) async throws -> [HealthActivityReading] {
        guard let anchor = start.startOfDay(calendar: calendar),
              let endDate = end.adding(days: 1, calendar: calendar).startOfDay(calendar: calendar)
        else { return [] }

        let descriptor = HKStatisticsCollectionQueryDescriptor(
            predicate: .quantitySample(
                type: activeEnergyType,
                predicate: HKQuery.predicateForSamples(withStart: anchor, end: endDate)
            ),
            options: .cumulativeSum,
            anchorDate: anchor,
            intervalComponents: DateComponents(day: 1)
        )

        let collection = try await descriptor.result(for: store)
        return collection.statistics().compactMap { statistics in
            guard let sum = statistics.sumQuantity() else { return nil }
            let calories = Int(sum.doubleValue(for: .kilocalorie()).rounded())
            guard calories > 0 else { return nil }
            // Bucketed by the interval's start, which is the local midnight the anchor fixed —
            // the same day boundary every entry in the log already uses.
            return HealthActivityReading(
                day: Day(date: statistics.startDate, calendar: calendar),
                activeCalories: calories
            )
        }
    }

    private func fetchWorkouts(since startDate: Date) async throws -> [HealthWorkoutReading] {
        let predicate = HKQuery.predicateForSamples(withStart: startDate, end: nil)
        let descriptor = HKSampleQueryDescriptor(
            predicates: [.workout(predicate)],
            sortDescriptors: [SortDescriptor(\.startDate)]
        )

        return try await descriptor.result(for: store).map { workout in
            HealthWorkoutReading(
                externalIdentifier: workout.uuid.uuidString,
                start: workout.startDate,
                end: workout.endDate,
                activeCalories: Self.activeCalories(of: workout, type: activeEnergyType),
                activityName: Self.name(for: workout.workoutActivityType),
                kind: Self.kind(for: workout.workoutActivityType)
            )
        }
    }

    /// Active energy only — never total.
    ///
    /// Total energy includes the basal calories the user would have burned lying still, and those
    /// are already inside their expenditure estimate. Importing total would count them twice and
    /// inflate every workout by roughly a calorie a minute.
    private static func activeCalories(of workout: HKWorkout, type: HKQuantityType) -> Int {
        guard let sum = workout.statistics(for: type)?.sumQuantity() else { return 0 }
        return max(0, Int(sum.doubleValue(for: .kilocalorie()).rounded()))
    }

    // MARK: Activity mapping

    /// Classifies an activity so the design's cardio/strength distinction survives the import.
    static func kind(for activity: HKWorkoutActivityType) -> ExerciseKind {
        switch activity {
        case .running, .walking, .cycling, .swimming, .rowing, .elliptical, .stairClimbing,
             .hiking, .highIntensityIntervalTraining, .jumpRope, .stairs, .stepTraining,
             .mixedCardio, .crossCountrySkiing, .downhillSkiing, .skatingSports, .paddleSports,
             .surfingSports, .soccer, .basketball, .tennis, .badminton, .racquetball, .squash,
             .tableTennis, .pickleball, .handball, .hockey, .rugby, .americanFootball,
             .australianFootball, .volleyball, .cricket, .lacrosse, .softball, .baseball,
             .golf, .boxing, .martialArts, .kickboxing, .wrestling, .dance, .cardioDance,
             .barre, .pilates, .waterFitness, .waterPolo, .waterSports, .snowSports,
             .snowboarding, .cooldown:
            .cardio
        case .traditionalStrengthTraining, .functionalStrengthTraining, .coreTraining,
             .crossTraining, .gymnastics, .climbing, .equestrianSports:
            .strength
        default:
            .other
        }
    }

    /// A readable activity name. HealthKit exposes no localized display name for these, so the
    /// common ones are spelled out and the rest fall back to "Workout" — which reads better in a
    /// log than a raw enum case would.
    static func name(for activity: HKWorkoutActivityType) -> String {
        switch activity {
        case .running: "Run"
        case .walking: "Walk"
        case .cycling: "Ride"
        case .swimming: "Swim"
        case .rowing: "Row"
        case .hiking: "Hike"
        case .elliptical: "Elliptical"
        case .stairClimbing, .stairs, .stepTraining: "Stairs"
        case .highIntensityIntervalTraining: "HIIT"
        case .traditionalStrengthTraining: "Weights"
        case .functionalStrengthTraining: "Strength training"
        case .coreTraining: "Core"
        case .crossTraining: "Cross training"
        case .yoga: "Yoga"
        case .pilates: "Pilates"
        case .barre: "Barre"
        case .dance, .cardioDance: "Dance"
        case .boxing: "Boxing"
        case .kickboxing: "Kickboxing"
        case .martialArts: "Martial arts"
        case .climbing: "Climbing"
        case .soccer: "Soccer"
        case .basketball: "Basketball"
        case .tennis: "Tennis"
        case .golf: "Golf"
        case .pickleball: "Pickleball"
        case .volleyball: "Volleyball"
        case .mixedCardio: "Cardio"
        case .jumpRope: "Jump rope"
        case .downhillSkiing: "Skiing"
        case .snowboarding: "Snowboarding"
        case .crossCountrySkiing: "Cross-country skiing"
        case .cooldown: "Cooldown"
        default: "Workout"
        }
    }
}

enum HealthImportError: Error, CustomStringConvertible {
    case unavailable
    /// The user has Apple Health switched off in Settings. Reaching HealthKit anyway would be
    /// ignoring the one promise the switch makes.
    case switchedOff

    var description: String { userMessage }

    var userMessage: String {
        switch self {
        case .unavailable: "Apple Health isn't available on this device."
        case .switchedOff: "Apple Health is switched off in Tally's settings."
        }
    }
}

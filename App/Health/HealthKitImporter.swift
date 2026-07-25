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
    func requestAuthorization() async throws {
        guard Self.isAvailable else { throw HealthImportError.unavailable }
        try await store.requestAuthorization(toShare: [], read: readTypes)
    }

    /// Imports the last `days` days and returns how many records were written.
    ///
    /// - Returns: the number of new records, which may legitimately be zero — either because
    ///   there is nothing new or because the user declined access.
    func importRecent(days: Int = 90, into stores: StoreBundle) async throws -> Int {
        guard Self.isAvailable else { throw HealthImportError.unavailable }

        let calendar = Calendar.current
        let today = Day.today(calendar: calendar)
        let start = today.adding(days: -days, calendar: calendar)
        guard let startDate = start.startOfDay(calendar: calendar) ?? start.noon(calendar: calendar)
        else { throw HealthImportError.unavailable }

        let weights = try await fetchWeights(since: startDate)
        let workouts = try await fetchWorkouts(since: startDate)

        // Everything Tally already knows, so the import is idempotent.
        let existing = try stores.entries.externalIdentifiers(from: start, through: today)
        let existingWeightIdentifiers = Set(
            try stores.weights.samples(from: start, through: today).compactMap(\.externalIdentifier)
        )
        let manualDays = Set(
            try stores.weights.samples(from: start, through: today)
                .filter { $0.source != .healthKit }
                .map(\.day)
        )

        let plan = HealthImport.plan(
            weights: weights,
            workouts: workouts,
            existingExternalIdentifiers: existing.union(existingWeightIdentifiers),
            daysWithManualWeight: manualDays,
            calendar: calendar
        )

        for sample in plan.weights {
            try stores.weights.save(sample)
        }
        if !plan.entries.isEmpty {
            try stores.entries.save(plan.entries)
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

    var description: String {
        "Apple Health isn't available on this device."
    }

    var userMessage: String {
        switch self {
        case .unavailable: "Apple Health isn't available on this device."
        }
    }
}

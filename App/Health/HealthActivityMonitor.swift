import Foundation
import HealthKit
import TallyCore

/// Keeps today's activity in step with Apple Health without the user opening Tally.
///
/// A calorie target driven by movement is only worth having if it moves. The import button
/// answers "what happened", which is enough for weight and for finished workouts; the Move
/// figure is a number that grows all day, and one that is hours stale on the widget is worse
/// than useless — it reads as wrong rather than as old.
///
/// So this is the one part of the integration that runs unprompted. It is also the part with
/// teeth: background delivery outlives the app, so registering it is a promise that has to be
/// withdrawn explicitly when the user switches the feature off. ``stop()`` is not a tidy-up,
/// it is the other half of ``start()``.
///
/// Nothing here decides anything. The observer fires, the injected closure syncs, and every
/// rule about what that writes lives in `HealthImport` where it can be tested.
@MainActor
final class HealthActivityMonitor {
    /// What to run when Health says something changed.
    ///
    /// Injected rather than called directly: `HKObserverQuery` needs a real device and a real
    /// Watch to fire, so a test that wants to prove what happens *after* an update has no other
    /// way in. Matches `WidgetRefresher`'s closure-injection for the same reason.
    private let sync: @Sendable () async -> Void

    private let store = HKHealthStore()
    private var queries: [HKObserverQuery] = []

    /// Active energy is the number that moves; workouts matter because a finished workout
    /// changes how much of the day's activity is already accounted for, and the leftover has to
    /// be recomputed against it.
    private static var observedTypes: [HKSampleType] {
        [HKQuantityType(.activeEnergyBurned), HKObjectType.workoutType()]
    }

    /// The best HealthKit offers for this data. `.immediate` is accepted for a handful of types
    /// and quietly downgraded for the rest, so asking for it here would only make the code look
    /// like it promised something it doesn't.
    private static let frequency: HKUpdateFrequency = .hourly

    init(sync: @escaping @Sendable () async -> Void) {
        self.sync = sync
    }

    var isRunning: Bool { !queries.isEmpty }

    func start() async throws {
        guard HKHealthStore.isHealthDataAvailable() else { throw HealthImportError.unavailable }
        guard queries.isEmpty else { return }

        let sync = self.sync
        for type in Self.observedTypes {
            let query = HKObserverQuery(sampleType: type, predicate: nil) { _, completion, error in
                // The completion handler is not optional courtesy: leave it uncalled and
                // HealthKit assumes the app failed to handle the update and throttles delivery
                // until it stops arriving. It runs even on an error, when there is nothing to
                // do but acknowledge.
                guard error == nil else { return completion() }

                // HealthKit hands back a plain block, which cannot be carried into a task on
                // its own account. Calling it exactly once, after the work, is the contract
                // being kept here — acknowledging early would let the system suspend the app
                // mid-write.
                let acknowledge = Acknowledgement(completion)
                Task {
                    await sync()
                    acknowledge()
                }
            }
            store.execute(query)
            queries.append(query)
        }

        for type in Self.observedTypes {
            try await store.enableBackgroundDelivery(for: type, frequency: Self.frequency)
        }
    }

    /// Stops observing and withdraws background delivery.
    ///
    /// Both halves matter. Stopping the queries ends this process's interest; leaving background
    /// delivery registered would keep the system waking Tally for a feature the user turned off,
    /// across launches, until the app is deleted.
    func stop() async {
        for query in queries { store.stop(query) }
        queries = []

        guard HKHealthStore.isHealthDataAvailable() else { return }
        for type in Self.observedTypes {
            try? await store.disableBackgroundDelivery(for: type)
        }
    }
}

/// HealthKit's "I've handled that" block, carried across a task boundary.
///
/// The block is thread-safe — calling it from another queue is exactly what HealthKit expects —
/// but it arrives as a bare closure with nothing to say so. This asserts what the framework
/// already guarantees rather than restructuring the callback around the type system.
private struct Acknowledgement: @unchecked Sendable {
    private let handler: () -> Void

    init(_ handler: @escaping () -> Void) { self.handler = handler }

    func callAsFunction() { handler() }
}

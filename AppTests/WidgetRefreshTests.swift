import Foundation
import Testing
import TallyCore
@testable import Tally

/// Counts reload requests. A class with a lock, and outside the suite rather than nested in it,
/// because the observer records from a task that is deliberately not on the main actor while the
/// test reads from one that is.
private final class Reloads: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0

    func record() {
        lock.lock()
        defer { lock.unlock() }
        count += 1
    }

    var recorded: Int {
        lock.lock()
        defer { lock.unlock() }
        return count
    }

    /// Waits for `target` reloads to arrive. Bounded, so a regression fails this test in about a
    /// second rather than hanging the run.
    func settle(atLeast target: Int = 1) async -> Int {
        for _ in 0..<100 where recorded < target {
            try? await Task.sleep(for: .milliseconds(10))
        }
        return recorded
    }
}

/// The widget builds a timeline, reads the shared database once, and then sleeps until midnight.
/// So "does a write ask WidgetKit to reload?" is the whole of whether the Lock Screen and Home
/// Screen widgets are ever right — and it is the one thing about them a test can reach, since
/// `WidgetCenter` needs a real widget host to observe.
@MainActor
@Suite("Widget refresh")
struct WidgetRefreshTests {
    /// Starts an observer over `stores`, subscribing before it returns so a write in the test
    /// body cannot outrun it. Cancel the returned task when the test is done with it.
    private func observe(_ stores: StoreBundle, into reloads: Reloads) -> Task<Void, Never> {
        let stream = stores.changes.stream()
        let refresher = WidgetRefresher { reloads.record() }
        return Task { await refresher.observe(stream) }
    }

    /// The reported bug: setup values reached the widget, but food logged afterwards never did.
    @Test("logging food asks the widgets to reload")
    func loggingFoodReloads() async throws {
        let stores = StoreBundle.inMemory()
        let reloads = Reloads()
        let observer = observe(stores, into: reloads)
        defer { observer.cancel() }

        let model = LogModel(stores: stores, parser: StubNutritionParser())
        await model.log(text: "two eggs and toast")

        #expect(await reloads.settle() >= 1)
    }

    /// A deleted entry has to leave the widget too, or it keeps counting food the user removed.
    @Test("deleting an entry asks the widgets to reload")
    func deletingReloads() async throws {
        let entry = Entry(kind: .food, label: "Toast", calories: 200, day: Day.today())
        let stores = StoreBundle.inMemory(entries: [entry])
        let reloads = Reloads()
        let observer = observe(stores, into: reloads)
        defer { observer.cancel() }

        try stores.entries.delete(id: entry.id)

        #expect(await reloads.settle() >= 1)
    }

    /// Weight and goal settings both move the number the widget's ring is drawn against, so they
    /// are widget changes as much as an entry is.
    @Test("a weight or goal change asks the widgets to reload")
    func goalInputsReload() async throws {
        let stores = StoreBundle.inMemory()
        let reloads = Reloads()
        let observer = observe(stores, into: reloads)
        defer { observer.cancel() }

        try stores.weights.save(WeightSample(day: Day.today(), pounds: 168.4))
        try stores.settings.save(GoalSettings(targetPounds: 155))

        #expect(await reloads.settle(atLeast: 2) >= 2)
    }

    /// The observer outlives whichever tab is on screen, so it has to stop with the scene rather
    /// than leak a task that goes on reloading.
    @Test("cancelling the observer stops the reloads")
    func cancellationStops() async throws {
        let stores = StoreBundle.inMemory()
        let reloads = Reloads()
        let observer = observe(stores, into: reloads)

        try stores.entries.save(Entry(kind: .food, label: "Toast", calories: 200, day: Day.today()))
        #expect(await reloads.settle() >= 1)

        observer.cancel()
        await observer.value
        let afterCancelling = reloads.recorded

        try stores.entries.save(Entry(kind: .food, label: "Jam", calories: 60, day: Day.today()))
        try? await Task.sleep(for: .milliseconds(50))

        #expect(reloads.recorded == afterCancelling)
    }
}

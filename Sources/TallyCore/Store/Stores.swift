import Foundation

/// The complete storage surface the rest of Tally is allowed to see.
///
/// Feature code, view models, widgets and intents depend on these protocols and never on a
/// database type. The SQLite implementations live in the separate `TallyStore` target, which
/// is the only thing that links GRDB — so "don't reach past the abstraction" is enforced by
/// the module graph, not by discipline. Replacing SQLite means writing new conformances and
/// changing one composition root.
///
/// The methods are synchronous and throwing. For a single-user on-device SQLite database
/// holding at most a few thousand rows, a read is microseconds; wrapping that in async would
/// add ceremony and an actor hop without buying anything. Writes that fan out (a HealthKit
/// import) are the caller's job to move off the main thread.
public protocol EntryStore: Sendable {
    func entries(on day: Day) throws -> [Entry]
    func entries(from start: Day, through end: Day) throws -> [Entry]
    func entry(id: Entry.ID) throws -> Entry?

    /// Inserts, or replaces the existing row with the same `id`.
    func save(_ entry: Entry) throws
    func save(_ entries: [Entry]) throws
    func delete(id: Entry.ID) throws

    func totals(on day: Day) throws -> DayTotals
    /// Totals for every day in the range that has at least one entry. Days with no entries
    /// are absent from the result rather than present-and-zero, so callers must supply their
    /// own default — `totals[day] ?? .empty`.
    func totals(from start: Day, through end: Day) throws -> [Day: DayTotals]

    /// External identifiers already recorded in the range. The HealthKit importer reads this
    /// to skip samples it has brought across before.
    func externalIdentifiers(from start: Day, through end: Day) throws -> Set<String>
}

/// At most one sample per day — ``save(_:)`` replaces any existing sample for that day.
public protocol WeightStore: Sendable {
    func sample(on day: Day) throws -> WeightSample?
    func samples(from start: Day, through end: Day) throws -> [WeightSample]
    /// All samples, oldest first. The trend calculation needs full history to be stable.
    func allSamples() throws -> [WeightSample]
    /// The most recent sample at or before `day`, used for "current weight" when today has
    /// no reading yet.
    func latestSample(onOrBefore day: Day) throws -> WeightSample?

    func save(_ sample: WeightSample) throws
    func delete(id: WeightSample.ID) throws
}

public protocol SettingsStore: Sendable {
    func profile() throws -> UserProfile
    func save(_ profile: UserProfile) throws
    func goalSettings() throws -> GoalSettings
    func save(_ goal: GoalSettings) throws
}

/// The three stores plus a change signal, passed around as one value so call sites take a
/// single dependency instead of four.
public struct StoreBundle: Sendable {
    public let entries: any EntryStore
    public let weights: any WeightStore
    public let settings: any SettingsStore
    public let changes: DataChangeBroadcaster

    public init(
        entries: any EntryStore,
        weights: any WeightStore,
        settings: any SettingsStore,
        changes: DataChangeBroadcaster = DataChangeBroadcaster()
    ) {
        self.entries = entries
        self.weights = weights
        self.settings = settings
        self.changes = changes
    }
}

/// What changed, so a listener can ignore signals it doesn't care about.
public enum DataChange: Hashable, Sendable {
    case entries
    case weights
    case settings
}

/// Broadcasts "something was written" to any number of listeners.
///
/// Deliberately storage-agnostic: writers call ``send(_:)`` after a successful write and
/// screens observe ``stream(for:)``, so cross-screen freshness doesn't depend on a database
/// feature like GRDB's `ValueObservation`. Swapping the storage layer leaves this untouched.
public final class DataChangeBroadcaster: Sendable {
    private struct State {
        var listeners: [UUID: AsyncStream<DataChange>.Continuation] = [:]
    }

    private let state = Mutex(State())

    public init() {}

    public func send(_ change: DataChange) {
        let listeners = state.withLock { Array($0.listeners.values) }
        for listener in listeners { listener.yield(change) }
    }

    /// A stream of changes matching `kinds`. Cancelling the consuming task unsubscribes.
    public func stream(for kinds: Set<DataChange> = [.entries, .weights, .settings])
        -> AsyncStream<DataChange>
    {
        let id = UUID()
        return AsyncStream { continuation in
            state.withLock { $0.listeners[id] = continuation }
            continuation.onTermination = { [state] _ in
                state.withLock { $0.listeners[id] = nil }
            }
        }
        .filter { kinds.contains($0) }
    }
}

/// Minimal mutual-exclusion box.
///
/// Swift 6.2 ships `Synchronization.Mutex`, but importing it here would raise the package's
/// platform floor above what the app targets, so this stands in. Not public — nothing outside
/// TallyCore should be reaching for a lock.
struct Mutex<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private let storage: Storage

    private final class Storage {
        var value: Value
        init(_ value: Value) { self.value = value }
    }

    init(_ value: Value) { self.storage = Storage(value) }

    func withLock<Result>(_ body: (inout Value) throws -> Result) rethrows -> Result {
        lock.lock()
        defer { lock.unlock() }
        return try body(&storage.value)
    }
}

/// `AsyncStream` has no `filter` that keeps the stream type, so this bridges to
/// `AsyncFilterSequence` and back into something callers can `for await` over directly.
extension AsyncStream {
    fileprivate func filter(
        _ isIncluded: @escaping @Sendable (Element) -> Bool
    ) -> AsyncStream<Element> where Element: Sendable {
        AsyncStream<Element> { continuation in
            let task = Task {
                for await element in self where isIncluded(element) {
                    continuation.yield(element)
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}

import Foundation

/// In-memory conformances of the three store protocols.
///
/// These are not only test doubles — they are the reference semantics. Where the SQLite
/// implementation and these disagree, these are right, and the same test suite runs against
/// both to keep them honest. Having them also means the goal engine and view models can be
/// tested without a database at all.
public final class InMemoryEntryStore: EntryStore {
    private let state = Mutex<[Entry.ID: Entry]>([:])

    public init(_ entries: [Entry] = []) {
        state.withLock { store in
            for entry in entries { store[entry.id] = entry }
        }
    }

    public func entries(on day: Day) throws -> [Entry] {
        state.withLock { $0.values.filter { $0.day == day } }.sortedForDisplay()
    }

    public func entries(from start: Day, through end: Day) throws -> [Entry] {
        state.withLock { $0.values.filter { $0.day >= start && $0.day <= end } }
            .sortedForDisplay()
    }

    public func entry(id: Entry.ID) throws -> Entry? {
        state.withLock { $0[id] }
    }

    public func save(_ entry: Entry) throws {
        state.withLock { $0[entry.id] = entry }
    }

    public func save(_ entries: [Entry]) throws {
        state.withLock { store in
            for entry in entries { store[entry.id] = entry }
        }
    }

    public func delete(id: Entry.ID) throws {
        state.withLock { $0[id] = nil }
    }

    public func totals(on day: Day) throws -> DayTotals {
        DayTotals.summing(try entries(on: day))
    }

    public func totals(from start: Day, through end: Day) throws -> [Day: DayTotals] {
        Dictionary(grouping: try entries(from: start, through: end), by: \.day)
            .mapValues(DayTotals.summing)
    }

    public func externalIdentifiers(from start: Day, through end: Day) throws -> Set<String> {
        Set(try entries(from: start, through: end).compactMap(\.externalIdentifier))
    }
}

public final class InMemoryWeightStore: WeightStore {
    // Keyed by day, which is what enforces "at most one sample per day".
    private let state = Mutex<[Day: WeightSample]>([:])

    public init(_ samples: [WeightSample] = []) {
        state.withLock { store in
            for sample in samples { store[sample.day] = sample }
        }
    }

    public func sample(on day: Day) throws -> WeightSample? {
        state.withLock { $0[day] }
    }

    public func samples(from start: Day, through end: Day) throws -> [WeightSample] {
        state.withLock { $0.values.filter { $0.day >= start && $0.day <= end } }
            .sorted { $0.day < $1.day }
    }

    public func allSamples() throws -> [WeightSample] {
        state.withLock { Array($0.values) }.sorted { $0.day < $1.day }
    }

    public func latestSample(onOrBefore day: Day) throws -> WeightSample? {
        state.withLock { $0.values.filter { $0.day <= day } }
            .max { $0.day < $1.day }
    }

    public func save(_ sample: WeightSample) throws {
        state.withLock { $0[sample.day] = sample }
    }

    public func delete(id: WeightSample.ID) throws {
        state.withLock { store in
            if let key = store.first(where: { $0.value.id == id })?.key {
                store[key] = nil
            }
        }
    }
}

public final class InMemorySettingsStore: SettingsStore {
    private struct State {
        var profile: UserProfile
        var goal: GoalSettings
    }

    private let state: Mutex<State>

    public init(profile: UserProfile = .default, goal: GoalSettings = .default) {
        self.state = Mutex(State(profile: profile, goal: goal))
    }

    public func profile() throws -> UserProfile { state.withLock { $0.profile } }
    public func save(_ profile: UserProfile) throws { state.withLock { $0.profile = profile } }
    public func goalSettings() throws -> GoalSettings { state.withLock { $0.goal } }
    public func save(_ goal: GoalSettings) throws { state.withLock { $0.goal = goal } }
}

extension StoreBundle {
    /// A fully in-memory bundle, for tests and SwiftUI previews.
    public static func inMemory(
        entries: [Entry] = [],
        weights: [WeightSample] = [],
        profile: UserProfile = .default,
        goal: GoalSettings = .default
    ) -> StoreBundle {
        StoreBundle(
            entries: InMemoryEntryStore(entries),
            weights: InMemoryWeightStore(weights),
            settings: InMemorySettingsStore(profile: profile, goal: goal)
        )
    }
}

extension Sequence<Entry> {
    /// Newest first within a day, which is the order the History and Today lists read in.
    /// Ties break on `id` so the order is stable across runs rather than dictionary-dependent.
    func sortedForDisplay() -> [Entry] {
        sorted {
            if $0.day != $1.day { return $0.day > $1.day }
            if $0.loggedAt != $1.loggedAt { return $0.loggedAt > $1.loggedAt }
            return $0.id.uuidString < $1.id.uuidString
        }
    }
}

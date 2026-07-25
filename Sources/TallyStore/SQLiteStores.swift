import Foundation
import GRDB
import TallyCore

/// Thrown when a write is attempted through a read-only connection.
///
/// Reaching this is a programming error rather than a user-facing condition — the widget is the
/// only read-only consumer, and it has nothing to write. It exists so that mistake surfaces as a
/// clear error instead of a crash inside GRDB.
public enum StoreWriteError: Error, CustomStringConvertible {
    case readOnlyConnection

    public var description: String {
        "This store was opened read-only and cannot be written to."
    }
}

/// SQLite-backed ``EntryStore``.
///
/// The aggregate queries (`totals`) are computed in SQL rather than by fetching rows and
/// summing in Swift. Not for speed at this data size — it's so that the widget, which wants one
/// number and nothing else, doesn't have to read and decode a day's worth of rows to get it.
public final class SQLiteEntryStore: EntryStore {
    private let reader: any DatabaseReader
    /// Nil for a read-only connection, such as the widget's. Writes then throw rather than
    /// failing silently or crashing.
    private let writer: (any DatabaseWriter)?
    private let changes: DataChangeBroadcaster

    public init(writer: any DatabaseWriter, changes: DataChangeBroadcaster = DataChangeBroadcaster()) {
        self.reader = writer
        self.writer = writer
        self.changes = changes
    }

    public init(reader: any DatabaseReader, changes: DataChangeBroadcaster = DataChangeBroadcaster()) {
        self.reader = reader
        self.writer = nil
        self.changes = changes
    }

    private func requireWriter() throws -> any DatabaseWriter {
        guard let writer else { throw StoreWriteError.readOnlyConnection }
        return writer
    }

    // Newest first within a day, matching the in-memory store and the order the design's
    // lists read in. The id tiebreak keeps ordering stable when two entries share a timestamp.
    private static let displayOrder = "ORDER BY day DESC, loggedAt DESC, id ASC"

    public func entries(on day: Day) throws -> [Entry] {
        try reader.read { db in
            try Row
                .fetchAll(db, sql: "SELECT * FROM entry WHERE day = :day \(Self.displayOrder)",
                          arguments: ["day": day.description])
                .map(Entry.init(row:))
        }
    }

    public func entries(from start: Day, through end: Day) throws -> [Entry] {
        try reader.read { db in
            try Row
                .fetchAll(db, sql: """
                    SELECT * FROM entry WHERE day >= :start AND day <= :end \(Self.displayOrder)
                    """,
                          arguments: ["start": start.description, "end": end.description])
                .map(Entry.init(row:))
        }
    }

    public func entry(id: Entry.ID) throws -> Entry? {
        try reader.read { db in
            try Row
                .fetchOne(db, sql: "SELECT * FROM entry WHERE id = :id",
                          arguments: ["id": id.uuidString])
                .map(Entry.init(row:))
        }
    }

    public func save(_ entry: Entry) throws {
        try save([entry])
    }

    public func save(_ entries: [Entry]) throws {
        guard !entries.isEmpty else { return }
        try requireWriter().write { db in
            for entry in entries {
                try db.execute(sql: Self.upsertSQL, arguments: entry.databaseArguments)
            }
        }
        changes.send(.entries)
    }

    public func delete(id: Entry.ID) throws {
        try requireWriter().write { db in
            try db.execute(sql: "DELETE FROM entry WHERE id = :id",
                           arguments: ["id": id.uuidString])
        }
        changes.send(.entries)
    }

    public func totals(on day: Day) throws -> DayTotals {
        try reader.read { db in
            let row = try Row.fetchOne(db, sql: """
                \(Self.totalsSelect) FROM entry WHERE day = :day
                """, arguments: ["day": day.description])
            return row.map(Self.totals(from:)) ?? .empty
        }
    }

    public func totals(from start: Day, through end: Day) throws -> [Day: DayTotals] {
        try reader.read { db in
            let rows = try Row.fetchAll(db, sql: """
                SELECT day, \(Self.totalsColumns) FROM entry
                WHERE day >= :start AND day <= :end
                GROUP BY day
                """, arguments: ["start": start.description, "end": end.description])

            return try rows.reduce(into: [:]) { result, row in
                result[try row.day("day")] = Self.totals(from: row)
            }
        }
    }

    public func externalIdentifiers(from start: Day, through end: Day) throws -> Set<String> {
        try reader.read { db in
            Set(try String.fetchAll(db, sql: """
                SELECT externalIdentifier FROM entry
                WHERE day >= :start AND day <= :end AND externalIdentifier IS NOT NULL
                """, arguments: ["start": start.description, "end": end.description]))
        }
    }

    // MARK: SQL

    private static let upsertSQL = """
        INSERT INTO entry (
            id, kind, label, calories, proteinGrams, fiberGrams, exerciseKind,
            durationMinutes, loggedAt, day, source, rawInput, confidence, externalIdentifier
        ) VALUES (
            :id, :kind, :label, :calories, :proteinGrams, :fiberGrams, :exerciseKind,
            :durationMinutes, :loggedAt, :day, :source, :rawInput, :confidence, :externalIdentifier
        )
        ON CONFLICT(id) DO UPDATE SET
            kind = :kind, label = :label, calories = :calories,
            proteinGrams = :proteinGrams, fiberGrams = :fiberGrams,
            exerciseKind = :exerciseKind, durationMinutes = :durationMinutes,
            loggedAt = :loggedAt, day = :day, source = :source, rawInput = :rawInput,
            confidence = :confidence, externalIdentifier = :externalIdentifier
        """

    /// Macros are summed only over food rows: an exercise entry has no macros to contribute,
    /// and letting a stray value through would inflate the protein bar.
    private static let totalsColumns = """
        COALESCE(SUM(CASE WHEN kind = 'food'     THEN calories END), 0) AS foodCalories,
        COALESCE(SUM(CASE WHEN kind = 'exercise' THEN calories END), 0) AS exerciseCalories,
        COALESCE(SUM(CASE WHEN kind = 'food'     THEN proteinGrams END), 0) AS proteinGrams,
        COALESCE(SUM(CASE WHEN kind = 'food'     THEN fiberGrams END), 0) AS fiberGrams,
        COUNT(*) AS entryCount
        """

    private static let totalsSelect = "SELECT \(totalsColumns)"

    private static func totals(from row: Row) -> DayTotals {
        DayTotals(
            foodCalories: row["foodCalories"],
            exerciseCalories: row["exerciseCalories"],
            proteinGrams: row["proteinGrams"],
            fiberGrams: row["fiberGrams"],
            entryCount: row["entryCount"]
        )
    }
}

/// SQLite-backed ``WeightStore``. One sample per day, enforced by a UNIQUE index on `day`.
public final class SQLiteWeightStore: WeightStore {
    private let reader: any DatabaseReader
    private let writer: (any DatabaseWriter)?
    private let changes: DataChangeBroadcaster

    public init(writer: any DatabaseWriter, changes: DataChangeBroadcaster = DataChangeBroadcaster()) {
        self.reader = writer
        self.writer = writer
        self.changes = changes
    }

    public init(reader: any DatabaseReader, changes: DataChangeBroadcaster = DataChangeBroadcaster()) {
        self.reader = reader
        self.writer = nil
        self.changes = changes
    }

    private func requireWriter() throws -> any DatabaseWriter {
        guard let writer else { throw StoreWriteError.readOnlyConnection }
        return writer
    }

    public func sample(on day: Day) throws -> WeightSample? {
        try reader.read { db in
            try Row.fetchOne(db, sql: "SELECT * FROM weightSample WHERE day = :day",
                             arguments: ["day": day.description])
                .map(WeightSample.init(row:))
        }
    }

    public func samples(from start: Day, through end: Day) throws -> [WeightSample] {
        try reader.read { db in
            try Row.fetchAll(db, sql: """
                SELECT * FROM weightSample
                WHERE day >= :start AND day <= :end ORDER BY day ASC
                """, arguments: ["start": start.description, "end": end.description])
                .map(WeightSample.init(row:))
        }
    }

    public func allSamples() throws -> [WeightSample] {
        try reader.read { db in
            try Row.fetchAll(db, sql: "SELECT * FROM weightSample ORDER BY day ASC")
                .map(WeightSample.init(row:))
        }
    }

    public func latestSample(onOrBefore day: Day) throws -> WeightSample? {
        try reader.read { db in
            try Row.fetchOne(db, sql: """
                SELECT * FROM weightSample WHERE day <= :day ORDER BY day DESC LIMIT 1
                """, arguments: ["day": day.description])
                .map(WeightSample.init(row:))
        }
    }

    /// Upserts on `day`, not on `id`. Logging today's weight twice should correct today's
    /// reading, not accumulate two rows — and the caller shouldn't have to look up the existing
    /// row's id to achieve that.
    public func save(_ sample: WeightSample) throws {
        try requireWriter().write { db in
            try db.execute(sql: """
                INSERT INTO weightSample (id, day, pounds, measuredAt, source, externalIdentifier)
                VALUES (:id, :day, :pounds, :measuredAt, :source, :externalIdentifier)
                ON CONFLICT(day) DO UPDATE SET
                    pounds = :pounds, measuredAt = :measuredAt, source = :source,
                    externalIdentifier = :externalIdentifier
                """, arguments: sample.databaseArguments)
        }
        changes.send(.weights)
    }

    public func delete(id: WeightSample.ID) throws {
        try requireWriter().write { db in
            try db.execute(sql: "DELETE FROM weightSample WHERE id = :id",
                           arguments: ["id": id.uuidString])
        }
        changes.send(.weights)
    }
}

/// SQLite-backed ``SettingsStore``, holding both settings objects as JSON in one row.
public final class SQLiteSettingsStore: SettingsStore {
    private let reader: any DatabaseReader
    private let writer: (any DatabaseWriter)?
    private let changes: DataChangeBroadcaster

    public init(writer: any DatabaseWriter, changes: DataChangeBroadcaster = DataChangeBroadcaster()) {
        self.reader = writer
        self.writer = writer
        self.changes = changes
    }

    public init(reader: any DatabaseReader, changes: DataChangeBroadcaster = DataChangeBroadcaster()) {
        self.reader = reader
        self.writer = nil
        self.changes = changes
    }

    private func requireWriter() throws -> any DatabaseWriter {
        guard let writer else { throw StoreWriteError.readOnlyConnection }
        return writer
    }

    public func profile() throws -> UserProfile {
        try load()?.profile ?? .default
    }

    public func goalSettings() throws -> GoalSettings {
        try load()?.goal ?? .default
    }

    public func save(_ profile: UserProfile) throws {
        let existing = try load()
        try store(profile: profile, goal: existing?.goal ?? .default, ai: existing?.ai)
        changes.send(.settings)
    }

    public func save(_ goal: GoalSettings) throws {
        let existing = try load()
        try store(profile: existing?.profile ?? .default, goal: goal, ai: existing?.ai)
        changes.send(.settings)
    }

    public func aiSettings() throws -> AISettings {
        try load()?.ai ?? .default
    }

    public func save(_ ai: AISettings) throws {
        let existing = try load()
        try store(profile: existing?.profile ?? .default, goal: existing?.goal ?? .default, ai: ai)
        changes.send(.settings)
    }

    // MARK: Private

    private typealias Stored = (profile: UserProfile, goal: GoalSettings, ai: AISettings?)

    private func load() throws -> Stored? {
        try reader.read { db in
            guard let row = try Row.fetchOne(db, sql: "SELECT * FROM settings WHERE id = 1")
            else { return nil }

            let decoder = JSONDecoder()
            let profileJSON: String = row["profileJSON"]
            let goalJSON: String = row["goalJSON"]
            // Null until the user has chosen a provider, which is not the same as having chosen
            // the default one — and a row written before the column existed reads as null too.
            let aiJSON: String? = row["aiJSON"]

            do {
                return (
                    try decoder.decode(UserProfile.self, from: Data(profileJSON.utf8)),
                    try decoder.decode(GoalSettings.self, from: Data(goalJSON.utf8)),
                    try aiJSON.map { try decoder.decode(AISettings.self, from: Data($0.utf8)) }
                )
            } catch {
                throw StoreDecodingError.malformedSettingsJSON(String(describing: error))
            }
        }
    }

    private func store(profile: UserProfile, goal: GoalSettings, ai: AISettings?) throws {
        let encoder = JSONEncoder()
        // Sorted keys so an unchanged settings object serialises byte-identically, which keeps
        // diffs and any future change detection meaningful.
        encoder.outputFormatting = [.sortedKeys]
        let profileJSON = String(decoding: try encoder.encode(profile), as: UTF8.self)
        let goalJSON = String(decoding: try encoder.encode(goal), as: UTF8.self)
        let aiJSON = try ai.map { String(decoding: try encoder.encode($0), as: UTF8.self) }

        try requireWriter().write { db in
            try db.execute(sql: """
                INSERT INTO settings (id, profileJSON, goalJSON, aiJSON)
                VALUES (1, :profileJSON, :goalJSON, :aiJSON)
                ON CONFLICT(id) DO UPDATE SET
                    profileJSON = :profileJSON, goalJSON = :goalJSON, aiJSON = :aiJSON
                """, arguments: [
                    "profileJSON": profileJSON, "goalJSON": goalJSON, "aiJSON": aiJSON,
                ])
        }
    }
}

import Foundation
import GRDB

/// The on-disk schema, as a sequence of numbered migrations.
///
/// Written as explicit SQL rather than through GRDB's table-builder DSL. The schema is the part
/// of a local-first app that is hardest to change after users have data, so it is worth being
/// able to read exactly what will exist on disk — and a reviewer should not have to know a
/// Swift DSL to check a column type.
///
/// Migrations are append-only. Never edit a registered migration once it has shipped: someone's
/// device has already run it, and changing it means their schema and a fresh install's diverge.
/// Add another one instead.
enum Schema {
    static func migrator() -> DatabaseMigrator {
        var migrator = DatabaseMigrator()

        // Catches an edited migration during development, when it is still cheap to notice.
        #if DEBUG
        migrator.eraseDatabaseOnSchemaChange = true
        #endif

        migrator.registerMigration("v1.initial") { db in
            // Dates are stored as Unix epoch seconds (REAL). GRDB's default is a formatted
            // string, but epoch seconds compare and sort numerically and are unambiguous
            // about timezone, which matters because `day` is the only timezone-bearing
            // notion in the schema and it is deliberately kept as text.
            try db.execute(sql: """
                CREATE TABLE entry (
                    id                 TEXT    PRIMARY KEY NOT NULL,
                    kind               TEXT    NOT NULL,
                    label              TEXT    NOT NULL,
                    calories           INTEGER NOT NULL,
                    proteinGrams       REAL    NOT NULL DEFAULT 0,
                    fiberGrams         REAL    NOT NULL DEFAULT 0,
                    exerciseKind       TEXT,
                    durationMinutes    INTEGER,
                    loggedAt           REAL    NOT NULL,
                    day                TEXT    NOT NULL,
                    source             TEXT    NOT NULL,
                    rawInput           TEXT,
                    confidence         TEXT,
                    externalIdentifier TEXT
                )
                """)

            // Every entry read is scoped to a day or a day range, so this index carries
            // essentially all query traffic.
            try db.execute(sql: "CREATE INDEX entry_by_day ON entry(day)")

            // Makes double-importing a HealthKit workout impossible at the storage layer,
            // rather than relying on the importer to check first. Partial, so the many rows
            // with no external identifier don't collide with each other.
            try db.execute(sql: """
                CREATE UNIQUE INDEX entry_by_external_identifier
                ON entry(externalIdentifier) WHERE externalIdentifier IS NOT NULL
                """)

            // `day UNIQUE` is what enforces one weight reading per day. Weight is noisy
            // enough that a single daily number is all the signal there is.
            try db.execute(sql: """
                CREATE TABLE weightSample (
                    id                 TEXT PRIMARY KEY NOT NULL,
                    day                TEXT NOT NULL UNIQUE,
                    pounds             REAL NOT NULL,
                    measuredAt         REAL NOT NULL,
                    source             TEXT NOT NULL,
                    externalIdentifier TEXT
                )
                """)

            // Settings are stored as two JSON documents in a single row, deliberately.
            // They are read whole, never queried by field, and gain a field every time a
            // preference is added — as columns that would mean a migration per preference,
            // for no benefit. The CHECK pins the table to exactly one row.
            try db.execute(sql: """
                CREATE TABLE settings (
                    id          INTEGER PRIMARY KEY NOT NULL CHECK (id = 1),
                    profileJSON TEXT    NOT NULL,
                    goalJSON    TEXT    NOT NULL
                )
                """)
        }

        return migrator
    }
}

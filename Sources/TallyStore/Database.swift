import Foundation
import GRDB
import TallyCore

/// Opens the Tally database and hands back the three stores wired to it.
///
/// The app and the widget are separate processes reading one file, so the file lives in the
/// shared App Group container and is opened in WAL mode: the widget's reads never block the
/// app's writes, and vice versa. Outside an App Group (tests, previews, Linux) an in-memory
/// or temporary-file database is used instead.
public enum TallyDatabase {
    public static let filename = "tally.sqlite"

    /// Where the database lives for a given App Group.
    ///
    /// Returns nil when the group isn't configured or entitled — which in practice means the
    /// App Group ID in `project.yml` doesn't match the one registered in the developer portal,
    /// or isn't enabled on this target. Callers should treat nil as a setup error worth
    /// surfacing, not as "use a local file instead": silently falling back would give the app
    /// and the widget separate databases, and the bug would present much later as a widget
    /// that is permanently empty.
    public static func url(forAppGroup appGroupID: String) -> URL? {
        #if canImport(Darwin)
        FileManager.default
            .containerURL(forSecurityApplicationGroupIdentifier: appGroupID)?
            .appendingPathComponent(filename)
        #else
        // App Groups are an Apple sandboxing feature with no Linux equivalent. Reaching here
        // means non-Apple code asked for the shared container, which is a programming error
        // rather than a configuration one — tests and tooling should use `openInMemory()`.
        nil
        #endif
    }

    /// A read-write database at `url`, migrated to the current schema.
    ///
    /// Uses a pool rather than a queue so concurrent readers (the widget, a background
    /// HealthKit import) don't serialise behind each other.
    public static func openReadWrite(at url: URL) throws -> any DatabaseWriter {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )

        var configuration = Configuration()
        configuration.foreignKeysEnabled = true
        // 5s is long enough to ride out a competing write from the other process, and short
        // enough that a genuine deadlock surfaces as an error rather than a hang.
        configuration.busyMode = .timeout(5)

        let pool = try DatabasePool(path: url.path, configuration: configuration)
        try Schema.migrator().migrate(pool)
        return pool
    }

    /// A read-only view of an existing database, for the widget extension.
    ///
    /// Read-only on purpose: a widget timeline should never be able to migrate the schema or
    /// write a row. It also means the widget can't be the process that discovers a migration
    /// is needed, which it has no business doing.
    public static func openReadOnly(at url: URL) throws -> any DatabaseReader {
        var configuration = Configuration()
        configuration.readonly = true
        configuration.busyMode = .timeout(2)
        return try DatabasePool(path: url.path, configuration: configuration)
    }

    /// An empty in-memory database. Used by tests and SwiftUI previews.
    public static func openInMemory() throws -> any DatabaseWriter {
        let queue = try DatabaseQueue()
        try Schema.migrator().migrate(queue)
        return queue
    }

    // MARK: Store bundles

    /// The three stores plus a change broadcaster, backed by `writer`.
    public static func stores(writer: any DatabaseWriter) -> StoreBundle {
        let changes = DataChangeBroadcaster()
        return StoreBundle(
            entries: SQLiteEntryStore(writer: writer, changes: changes),
            weights: SQLiteWeightStore(writer: writer, changes: changes),
            settings: SQLiteSettingsStore(writer: writer, changes: changes),
            changes: changes
        )
    }

    /// Convenience for the app's composition root: open the shared database and wire the stores.
    public static func stores(forAppGroup appGroupID: String) throws -> StoreBundle {
        guard let url = url(forAppGroup: appGroupID) else {
            throw TallyDatabaseError.appGroupUnavailable(appGroupID)
        }
        return stores(writer: try openReadWrite(at: url))
    }

    /// Read-only stores for the widget extension.
    ///
    /// Every write through these throws ``StoreWriteError/readOnlyConnection``. The widget has
    /// nothing to write, so making that structural means a mistake shows up as a clear error
    /// rather than a crash — or worse, a widget process quietly migrating the schema out from
    /// under the running app.
    public static func readOnlyStores(reader: any DatabaseReader) -> StoreBundle {
        let changes = DataChangeBroadcaster()
        return StoreBundle(
            entries: SQLiteEntryStore(reader: reader, changes: changes),
            weights: SQLiteWeightStore(reader: reader, changes: changes),
            settings: SQLiteSettingsStore(reader: reader, changes: changes),
            changes: changes
        )
    }

    /// Convenience for tests and previews.
    public static func inMemoryStores() throws -> StoreBundle {
        stores(writer: try openInMemory())
    }
}

public enum TallyDatabaseError: Error, CustomStringConvertible {
    case appGroupUnavailable(String)

    public var description: String {
        switch self {
        case .appGroupUnavailable(let id):
            """
            The App Group "\(id)" is not available to this process. Check that the identifier \
            in project.yml matches the one registered in the Apple developer portal, and that \
            the App Groups capability is enabled on both the app and the widget target.
            """
        }
    }
}

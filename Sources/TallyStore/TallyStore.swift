import Foundation
import GRDB
import TallyCore

/// Namespace for the SQLite-backed store implementations.
public enum TallyStore {
    /// Bumped whenever the on-disk schema changes; surfaced in diagnostics.
    public static let schemaVersion = 1
}

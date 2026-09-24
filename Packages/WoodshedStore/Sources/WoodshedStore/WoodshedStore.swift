import Foundation
import GRDB
import WoodshedKit

// Issue #3: the store facade.

/// A Woodshed database plus its repositories.
///
/// Open once per app life (`WoodshedStore.open(at:)` for the on-disk
/// store, `WoodshedStore.inMemory()` for tests). The repository handles
/// are shared, value-typed wrappers over the same database connection
/// pool — safe to pass to views/services (all are `Sendable`).
public struct WoodshedStore: Sendable {
    public let db: any DatabaseWriter
    public let instruments: any InstrumentRepository
    public let pieces: any PieceRepository
    public let sessions: any SessionRepository
    public let tempoLogs: any TempoLogRepository
    public let practiceNotes: any PracticeNoteRepository

    public init(db: any DatabaseWriter) {
        self.db = db
        self.instruments = GRDBInstrumentRepository(db: db)
        self.pieces = GRDBPieceRepository(db: db)
        self.sessions = GRDBSessionRepository(db: db)
        self.tempoLogs = GRDBTempoLogRepository(db: db)
        self.practiceNotes = GRDBPracticeNoteRepository(db: db)
    }

    /// Opens (creating if needed) and migrates the store at `url`.
    public static func open(at url: URL) throws -> WoodshedStore {
        var config = Configuration()
        config.foreignKeysEnabled = true
        let db = try DatabaseQueue(path: url.path, configuration: config)
        try WoodshedStoreSchema.migrator.migrate(db)
        return WoodshedStore(db: db)
    }

    /// A migrated in-memory store (unit tests).
    public static func inMemory() throws -> WoodshedStore {
        var config = Configuration()
        config.foreignKeysEnabled = true
        let db = try DatabaseQueue(configuration: config)
        try WoodshedStoreSchema.migrator.migrate(db)
        return WoodshedStore(db: db)
    }

    /// Storage usage for a future settings screen: ledger row counts per
    /// table plus the on-disk database size in bytes.
    public func storageUsage() throws -> StorageUsage {
        try db.read { reader in
            func count(_ table: String) throws -> Int {
                try Int.fetchOne(reader, sql: "SELECT COUNT(*) FROM \(table)") ?? 0
            }
            let rows = StorageUsage.TableCounts(
                instruments: try count("instruments"),
                pieces: try count("pieces"),
                sessions: try count("sessions"),
                sessionSplits: try count("session_splits"),
                tempoLogs: try count("tempo_logs"),
                practiceNotes: try count("practice_notes")
            )
            let pageCount: Int = try Int.fetchOne(reader, sql: "PRAGMA page_count") ?? 0
            let pageSize: Int = try Int.fetchOne(reader, sql: "PRAGMA page_size") ?? 0
            return StorageUsage(rows: rows, databaseBytes: pageCount * pageSize)
        }
    }
}

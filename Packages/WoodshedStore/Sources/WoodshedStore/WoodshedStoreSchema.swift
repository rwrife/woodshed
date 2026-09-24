import Foundation
import GRDB

// Issue #3: schema + migrations.

public enum WoodshedStoreError: Error, Equatable, Sendable {
    /// A ledger payload row could not be decoded back into its `WoodshedKit`
    /// domain type. Reported with table + row id so corruption is diagnosable
    /// instead of silently defaulting.
    case corruptPayload(table: String, id: UUID, underlying: String)
    /// A parent row (piece / session / instrument) named by an insert does
    /// not exist. Checked before insert; foreign keys enforce it in the
    /// database too.
    case parentNotFound(table: String, id: UUID)
    /// A correction insert named an entity that has no prior ledger row.
    /// Corrections extend history; they cannot invent it.
    case correctionOfUnknownEntity(table: String, id: UUID)
    /// A tempo log append would break the monotonic tempo-history invariant
    /// (its `loggedAt` precedes the previous tempo log for the same piece).
    case tempoLogOutOfOrder(pieceID: UUID, loggedAt: Date, previousLoggedAt: Date)
    /// A session append has a split whose `startedAt` precedes the session
    /// start — the session row and its split rows are one atomic fact.
    case splitBeforeSessionStart(sessionID: UUID, splitID: UUID)
}

/// Schema identity. `v1` is frozen forever — never edit it in place; append
/// a `v2` migration and register it below when the schema evolves.
///
/// Schema v1 (mirror of the `WoodshedKit` domain, issue #2):
///
///   instruments(
///     id TEXT PRIMARY KEY,            -- UUID string
///     name TEXT NOT NULL,
///     committed_at DATETIME NOT NULL  -- guards against out-of-order events
///   )
///   pieces(
///     id TEXT PRIMARY KEY,
///     instrument_id TEXT NOT NULL REFERENCES instruments(id) ON DELETE CASCADE,
///     title TEXT NOT NULL,
///     status TEXT NOT NULL,           -- active | maintenance | retired
///     target_bpm INTEGER,             -- exact integer BPM, never float
///     committed_at DATETIME NOT NULL
///   )
///   sessions(
///     id TEXT PRIMARY KEY,
///     piece_id TEXT NOT NULL REFERENCES pieces(id) ON DELETE CASCADE,
///     started_at DATETIME NOT NULL,
///     ended_at DATETIME NOT NULL,
///     committed_at DATETIME NOT NULL
///   )
///   session_splits(
///     id TEXT PRIMARY KEY,
///     session_id TEXT NOT NULL, session_committed_at DATETIME NOT NULL,
///       FOREIGN KEY (session_id, session_committed_at)
///       REFERENCES sessions(id, committed_at) ON DELETE CASCADE,
///     label TEXT NOT NULL,
///     started_at DATETIME NOT NULL,
///     ended_at DATETIME NOT NULL,
///     committed_at DATETIME NOT NULL
///   )
///   -- primary key is (id, committed_at), like all event tables
///   tempo_logs(
///     id TEXT PRIMARY KEY,
///     piece_id TEXT NOT NULL REFERENCES pieces(id) ON DELETE CASCADE,
///     bpm INTEGER NOT NULL,
///     logged_at DATETIME NOT NULL,
///     committed_at DATETIME NOT NULL
///   )
///   practice_notes(
///     id TEXT PRIMARY KEY,
///     piece_id TEXT NOT NULL REFERENCES pieces(id) ON DELETE CASCADE,
///     text TEXT NOT NULL,
///     written_at DATETIME NOT NULL,
///     committed_at DATETIME NOT NULL
///   )
///
/// Design notes:
/// - `instruments` and `pieces` are the parent tables; entity *events* for
///   them are folded into the current row (an append with an existing id is
///   an UPSERT — "newest event per id wins" is exactly the row's content).
///   Their rows are still never exposed for UPDATE/DELETE through the
///   repository layer.
/// - `sessions`, `session_splits`, `tempo_logs`, `practice_notes` are
///   ledger event tables: one row per committed event, keyed by
///   `(table, id, committed_at)` so a correction is an additional row, not
///   a mutation. Readers resolve current state as MAX(committed_at) per id.
///   UPDATE and DELETE are not part of any repository protocol.
/// - FK `ON DELETE CASCADE` from events to pieces/sessions (and pieces to
///   instruments) is the only deletion path, reserved for future
///   user-driven prune/erase flows — it never runs during normal append use.
/// - Foreign keys are enforced (GRDB enables them per connection by
///   default), which is what makes the cascade semantics real.
public enum WoodshedStoreSchema {
    /// Stable, ordered migration identifiers. The count is the schema version.
    public static let migrationIdentifiers: [String] = ["v1"]

    /// Current schema version == number of registered migrations.
    public static var currentVersion: Int { migrationIdentifiers.count }

    public static let migrator: DatabaseMigrator = {
        var migrator = DatabaseMigrator()
        migrator.registerMigration("v1") { db in
            try db.create(table: "instruments") { table in
                table.column("id", .text).notNull().primaryKey()
                table.column("name", .text).notNull()
                table.column("committed_at", .datetime).notNull()
            }
            try db.create(table: "pieces") { table in
                table.column("id", .text).notNull().primaryKey()
                table.column("instrument_id", .text).notNull()
                    .references("instruments", onDelete: .cascade)
                table.column("title", .text).notNull()
                table.column("status", .text).notNull()
                table.column("target_bpm", .integer)
                table.column("committed_at", .datetime).notNull()
            }
            try db.create(table: "sessions") { table in
                table.column("id", .text).notNull()
                table.column("piece_id", .text).notNull()
                    .references("pieces", onDelete: .cascade)
                table.column("started_at", .datetime).notNull()
                table.column("ended_at", .datetime).notNull()
                table.column("committed_at", .datetime).notNull()
                table.primaryKey(["id", "committed_at"])
            }
            try db.create(
                index: "sessions_piece_start",
                on: "sessions",
                columns: ["piece_id", "started_at"]
            )
            try db.create(table: "session_splits") { table in
                table.column("id", .text).notNull()
                table.column("session_id", .text).notNull()
                table.column("session_committed_at", .datetime).notNull()
                table.foreignKey(
                    ["session_id", "session_committed_at"],
                    references: "sessions", columns: ["id", "committed_at"],
                    onDelete: .cascade
                )
                table.column("label", .text).notNull()
                table.column("started_at", .datetime).notNull()
                table.column("ended_at", .datetime).notNull()
                table.column("committed_at", .datetime).notNull()
                table.primaryKey(["id", "committed_at"])
            }
            try db.create(
                index: "session_splits_session",
                on: "session_splits",
                columns: ["session_id", "started_at"]
            )
            try db.create(table: "tempo_logs") { table in
                table.column("id", .text).notNull()
                table.column("piece_id", .text).notNull()
                    .references("pieces", onDelete: .cascade)
                table.column("bpm", .integer).notNull()
                table.column("logged_at", .datetime).notNull()
                table.column("committed_at", .datetime).notNull()
                table.primaryKey(["id", "committed_at"])
            }
            try db.create(
                index: "tempo_logs_piece_logged",
                on: "tempo_logs",
                columns: ["piece_id", "logged_at"]
            )
            try db.create(table: "practice_notes") { table in
                table.column("id", .text).notNull()
                table.column("piece_id", .text).notNull()
                    .references("pieces", onDelete: .cascade)
                table.column("text", .text).notNull()
                table.column("written_at", .datetime).notNull()
                table.column("committed_at", .datetime).notNull()
                table.primaryKey(["id", "committed_at"])
            }
            try db.create(
                index: "practice_notes_piece_written",
                on: "practice_notes",
                columns: ["piece_id", "written_at"]
            )
        }
        return migrator
    }()
}

/// Applied-schema version query (exposed for tests and future diagnostics):
/// number of registered migrations the database has applied.
public func woodshedStoreAppliedSchemaVersion(_ db: DatabaseReader) throws -> Int {
    try db.read { reader in
        try WoodshedStoreSchema.migrator.appliedMigrations(reader).count
    }
}

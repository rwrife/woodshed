import Foundation
import GRDB
import WoodshedKit

// Issue #3: repository protocols + GRDB implementations.
//
// The append-only promise from #2 is preserved AT THE REPOSITORY LAYER:
//
// - `instruments` and `pieces` are current-state projection tables (they
//   are FK targets, so their rows are keyed by entity id). Their repository
//   surface is `append(...)` — an UPSERT implementing the domain's own
//   "newest event per id wins" rule. No protocol method mutates or deletes
//   a row; corrections replace the current-state row exactly as the Ledger
//   resolves corrections.
// - `sessions`, `session_splits`, `tempo_logs`, and `practice_notes` are
//   true event tables keyed by (id, committed_at). Every protocol method is
//   INSERT-only; a correction is an additional row, and readers resolve
//   current state as MAX(committed_at) per id. UPDATE/DELETE appear in no
//   protocol — deletion happens only via FK CASCADE (tests issue raw SQL to
//   prove those semantics).

// MARK: - Protocols

public protocol InstrumentRepository: Sendable {
    /// Appends an instrument event (UPSERT on the current-state row).
    func append(_ instrument: Instrument, committedAt: Date) throws
    func instrument(id: UUID) throws -> Instrument?
    func allInstruments() throws -> [Instrument]
}

public protocol PieceRepository: Sendable {
    /// Appends a piece event (UPSERT on the current-state row). Throws
    /// `WoodshedStoreError.parentNotFound` when the instrument does not
    /// exist (checked before insert; foreign keys enforce it too).
    func append(_ piece: Piece, committedAt: Date) throws
    func piece(id: UUID) throws -> Piece?
    /// All current pieces, ordered by title.
    func allPieces() throws -> [Piece]
    func pieces(instrumentID: UUID) throws -> [Piece]
}

public protocol SessionRepository: Sendable {
    /// Inserts a session event row. Inserts only — corrections are further
    /// appends of the same id with a later `committedAt`.
    func append(_ session: Session, committedAt: Date) throws
    /// Inserts a split event row referencing the session event identified by
    /// `(sessionID, sessionCommittedAt)`. Throws
    /// `WoodshedStoreError.parentNotFound` when that event row is absent and
    /// `.splitBeforeSessionStart` when the split starts before its session.
    func append(split: SessionSplit, sessionCommittedAt: Date, committedAt: Date) throws
    /// Current sessions (newest event per id), oldest started first.
    func currentSessions() throws -> [Session]
    /// Current splits (newest event per split id) of current sessions,
    /// ordered by start.
    func currentSplits(sessionID: UUID) throws -> [SessionSplit]
}

public protocol TempoLogRepository: Sendable {
    /// Inserts a tempo event row. Throws `.tempoLogOutOfOrder` when
    /// `loggedAt` precedes the previous tempo log for the same piece
    /// (mirrors `Ledger`'s monotonicity rule); equal timestamps are allowed.
    func append(_ tempoLog: TempoLog, committedAt: Date) throws
    /// Every tempo log event for a piece, ordered by (loggedAt, append id).
    func tempoLogs(for pieceID: UUID) throws -> [TempoLog]
}

public protocol PracticeNoteRepository: Sendable {
    func append(_ note: PracticeNote, committedAt: Date) throws
    /// Current notes (newest event per id), newest writtenAt first.
    func notes(for pieceID: UUID) throws -> [PracticeNote]
}

// MARK: - Storage usage (exposed for a future settings screen)

public struct StorageUsage: Equatable, Sendable {
    public struct TableCounts: Equatable, Sendable {
        public var instruments: Int
        public var pieces: Int
        public var sessions: Int
        public var sessionSplits: Int
        public var tempoLogs: Int
        public var practiceNotes: Int

        public init(
            instruments: Int, pieces: Int, sessions: Int,
            sessionSplits: Int, tempoLogs: Int, practiceNotes: Int
        ) {
            self.instruments = instruments
            self.pieces = pieces
            self.sessions = sessions
            self.sessionSplits = sessionSplits
            self.tempoLogs = tempoLogs
            self.practiceNotes = practiceNotes
        }
    }

    public var rows: TableCounts
    /// On-disk database size in bytes (page_count × page_size). Zero for
    /// in-memory databases.
    public var databaseBytes: Int

    public init(rows: TableCounts, databaseBytes: Int) {
        self.rows = rows
        self.databaseBytes = databaseBytes
    }
}

// MARK: - GRDB implementations

public struct GRDBInstrumentRepository: InstrumentRepository {
    let db: any DatabaseWriter
    public init(db: any DatabaseWriter) { self.db = db }

    public func append(_ instrument: Instrument, committedAt: Date) throws {
        // Single-row current-state projection guarded by committed_at: an
        // older event can never roll state backwards (UPSERT ... WHERE).
        try db.write { writer in
            try writer.execute(
                sql: """
                INSERT INTO instruments (id, name, committed_at) VALUES (?, ?, ?)
                ON CONFLICT(id) DO UPDATE SET
                    name = excluded.name,
                    committed_at = excluded.committed_at
                WHERE instruments.committed_at <= excluded.committed_at
                """,
                arguments: [instrument.id.uuidString, instrument.name, committedAt]
            )
        }
    }

    public func instrument(id: UUID) throws -> Instrument? {
        try db.read { reader in
            guard let row = try Row.fetchOne(reader, sql: "SELECT * FROM instruments WHERE id = ?", arguments: [id.uuidString]) else { return nil }
            return Instrument(id: id, name: row["name"])
        }
    }

    public func allInstruments() throws -> [Instrument] {
        try db.read { reader in
            try Row
                .fetchAll(reader, sql: "SELECT id, name FROM instruments ORDER BY name COLLATE NOCASE")
                .map { row in Instrument(id: UUID(uuidString: row["id"])!, name: row["name"]) }
        }
    }
}

public struct GRDBPieceRepository: PieceRepository {
    let db: any DatabaseWriter
    public init(db: any DatabaseWriter) { self.db = db }

    public func append(_ piece: Piece, committedAt: Date) throws {
        try db.write { writer in
            guard try Int.fetchOne(
                writer,
                sql: "SELECT COUNT(*) FROM instruments WHERE id = ?",
                arguments: [piece.instrumentID.uuidString]
            ) == 1 else {
                throw WoodshedStoreError.parentNotFound(table: "instruments", id: piece.instrumentID)
            }
            try writer.execute(
                sql: """
                INSERT INTO pieces (id, instrument_id, title, status, target_bpm, committed_at)
                VALUES (?, ?, ?, ?, ?, ?)
                ON CONFLICT(id) DO UPDATE SET
                    instrument_id = excluded.instrument_id,
                    title = excluded.title,
                    status = excluded.status,
                    target_bpm = excluded.target_bpm,
                    committed_at = excluded.committed_at
                WHERE pieces.committed_at <= excluded.committed_at
                """,
                arguments: [
                    piece.id.uuidString, piece.instrumentID.uuidString, piece.title,
                    piece.status.rawValue, piece.targetBPM, committedAt,
                ]
            )
        }
    }

    public func piece(id: UUID) throws -> Piece? {
        try db.read { reader in
            guard let row = try Row.fetchOne(reader, sql: "SELECT * FROM pieces WHERE id = ?", arguments: [id.uuidString]) else { return nil }
            return Self.piece(from: row)
        }
    }

    public func allPieces() throws -> [Piece] {
        try db.read { reader in
            try Row.fetchAll(reader, sql: "SELECT * FROM pieces ORDER BY title COLLATE NOCASE").map(Self.piece(from:))
        }
    }

    public func pieces(instrumentID: UUID) throws -> [Piece] {
        try db.read { reader in
            try Row.fetchAll(
                reader,
                sql: "SELECT * FROM pieces WHERE instrument_id = ? ORDER BY title COLLATE NOCASE",
                arguments: [instrumentID.uuidString]
            ).map(Self.piece(from:))
        }
    }

    static func piece(from row: Row) -> Piece {
        Piece(
            id: UUID(uuidString: row["id"])!,
            instrumentID: UUID(uuidString: row["instrument_id"])!,
            title: row["title"],
            status: Piece.Status(rawValue: row["status"]) ?? .active,
            targetBPM: row["target_bpm"]
        )
    }
}

public struct GRDBSessionRepository: SessionRepository {
    let db: any DatabaseWriter
    public init(db: any DatabaseWriter) { self.db = db }

    public func append(_ session: Session, committedAt: Date) throws {
        try db.write { writer in
            guard try Int.fetchOne(
                writer,
                sql: "SELECT COUNT(*) FROM pieces WHERE id = ?",
                arguments: [session.pieceID.uuidString]
            ) == 1 else {
                throw WoodshedStoreError.parentNotFound(table: "pieces", id: session.pieceID)
            }
            try writer.execute(
                sql: """
                INSERT INTO sessions (id, piece_id, started_at, ended_at, committed_at)
                VALUES (?, ?, ?, ?, ?)
                """,
                arguments: [
                    session.id.uuidString, session.pieceID.uuidString,
                    session.startedAt, session.endedAt, committedAt,
                ]
            )
        }
    }

    public func append(split: SessionSplit, sessionCommittedAt: Date, committedAt: Date) throws {
        try db.write { writer in
            guard let sessionRow = try Row.fetchOne(
                writer,
                sql: "SELECT started_at FROM sessions WHERE id = ? AND committed_at = ?",
                arguments: [split.sessionID.uuidString, sessionCommittedAt]
            ) else {
                throw WoodshedStoreError.parentNotFound(table: "sessions", id: split.sessionID)
            }
            let sessionStartedAt: Date = sessionRow["started_at"]
            guard split.startedAt >= sessionStartedAt else {
                throw WoodshedStoreError.splitBeforeSessionStart(sessionID: split.sessionID, splitID: split.id)
            }
            try writer.execute(
                sql: """
                INSERT INTO session_splits (id, session_id, session_committed_at, label, started_at, ended_at, committed_at)
                VALUES (?, ?, ?, ?, ?, ?, ?)
                """,
                arguments: [
                    split.id.uuidString, split.sessionID.uuidString, sessionCommittedAt,
                    split.label, split.startedAt, split.endedAt, committedAt,
                ]
            )
        }
    }

    public func currentSessions() throws -> [Session] {
        try db.read { reader in
            // Newest event per session id.
            try Row.fetchAll(
                reader,
                sql: """
                SELECT s.* FROM sessions s
                WHERE s.committed_at = (SELECT MAX(c.committed_at) FROM sessions c WHERE c.id = s.id)
                ORDER BY s.started_at, s.id
                """
            ).map { row in
                Session(
                    id: UUID(uuidString: row["id"])!,
                    pieceID: UUID(uuidString: row["piece_id"])!,
                    startedAt: row["started_at"],
                    endedAt: row["ended_at"]
                )
            }
        }
    }

    public func currentSplits(sessionID: UUID) throws -> [SessionSplit] {
        try db.read { reader in
            // Splits of the CURRENT session event only: corrections to a
            // session re-append their own splits (newest split event per id).
            try Row.fetchAll(
                reader,
                sql: """
                SELECT sp.* FROM session_splits sp
                WHERE sp.session_id = ?
                  AND (sp.session_id, sp.session_committed_at) IN (
                      SELECT id, MAX(committed_at) FROM sessions WHERE id = ?
                  )
                  AND sp.committed_at = (SELECT MAX(c.committed_at) FROM session_splits c WHERE c.id = sp.id)
                ORDER BY sp.started_at, sp.id
                """,
                arguments: [sessionID.uuidString, sessionID.uuidString]
            ).map { row in
                SessionSplit(
                    id: UUID(uuidString: row["id"])!,
                    sessionID: UUID(uuidString: row["session_id"])!,
                    label: row["label"],
                    startedAt: row["started_at"],
                    endedAt: row["ended_at"]
                )
            }
        }
    }
}

public struct GRDBTempoLogRepository: TempoLogRepository {
    let db: any DatabaseWriter
    public init(db: any DatabaseWriter) { self.db = db }

    public func append(_ tempoLog: TempoLog, committedAt: Date) throws {
        try db.write { writer in
            guard try Int.fetchOne(
                writer,
                sql: "SELECT COUNT(*) FROM pieces WHERE id = ?",
                arguments: [tempoLog.pieceID.uuidString]
            ) == 1 else {
                throw WoodshedStoreError.parentNotFound(table: "pieces", id: tempoLog.pieceID)
            }
            let previous: Date? = try Date.fetchOne(
                writer,
                sql: "SELECT MAX(logged_at) FROM tempo_logs WHERE piece_id = ?",
                arguments: [tempoLog.pieceID.uuidString]
            )
            if let previous, tempoLog.loggedAt < previous {
                throw WoodshedStoreError.tempoLogOutOfOrder(
                    pieceID: tempoLog.pieceID,
                    loggedAt: tempoLog.loggedAt,
                    previousLoggedAt: previous
                )
            }
            try writer.execute(
                sql: """
                INSERT INTO tempo_logs (id, piece_id, bpm, logged_at, committed_at)
                VALUES (?, ?, ?, ?, ?)
                """,
                arguments: [
                    tempoLog.id.uuidString, tempoLog.pieceID.uuidString,
                    tempoLog.bpm, tempoLog.loggedAt, committedAt,
                ]
            )
        }
    }

    public func tempoLogs(for pieceID: UUID) throws -> [TempoLog] {
        try db.read { reader in
            try Row.fetchAll(
                reader,
                sql: "SELECT * FROM tempo_logs WHERE piece_id = ? ORDER BY logged_at, committed_at, id",
                arguments: [pieceID.uuidString]
            ).map { row in
                TempoLog(
                    id: UUID(uuidString: row["id"])!,
                    pieceID: UUID(uuidString: row["piece_id"])!,
                    bpm: row["bpm"],
                    loggedAt: row["logged_at"]
                )
            }
        }
    }
}

public struct GRDBPracticeNoteRepository: PracticeNoteRepository {
    let db: any DatabaseWriter
    public init(db: any DatabaseWriter) { self.db = db }

    public func append(_ note: PracticeNote, committedAt: Date) throws {
        try db.write { writer in
            guard try Int.fetchOne(
                writer,
                sql: "SELECT COUNT(*) FROM pieces WHERE id = ?",
                arguments: [note.pieceID.uuidString]
            ) == 1 else {
                throw WoodshedStoreError.parentNotFound(table: "pieces", id: note.pieceID)
            }
            try writer.execute(
                sql: """
                INSERT INTO practice_notes (id, piece_id, text, written_at, committed_at)
                VALUES (?, ?, ?, ?, ?)
                """,
                arguments: [
                    note.id.uuidString, note.pieceID.uuidString,
                    note.text, note.writtenAt, committedAt,
                ]
            )
        }
    }

    public func notes(for pieceID: UUID) throws -> [PracticeNote] {
        try db.read { reader in
            try Row.fetchAll(
                reader,
                sql: """
                SELECT n.* FROM practice_notes n
                WHERE n.piece_id = ?
                  AND n.committed_at = (SELECT MAX(c.committed_at) FROM practice_notes c WHERE c.id = n.id)
                ORDER BY n.written_at DESC, n.id
                """,
                arguments: [pieceID.uuidString]
            ).map { row in
                PracticeNote(
                    id: UUID(uuidString: row["id"])!,
                    pieceID: UUID(uuidString: row["piece_id"])!,
                    text: row["text"],
                    writtenAt: row["written_at"]
                )
            }
        }
    }
}

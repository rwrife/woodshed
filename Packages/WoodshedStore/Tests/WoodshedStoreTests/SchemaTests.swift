import Foundation
import GRDB
import Testing
import WoodshedKit
import WoodshedStore

// Issue #3: schema, migrator, and cascade-semantics tests.

@Suite("Schema v1")
struct SchemaTests {
    @Test("a fresh database reaches schema version 1")
    func freshVersion() throws {
        let store = try WoodshedStore.inMemory()
        let applied = try woodshedStoreAppliedSchemaVersion(store.db)
        #expect(applied == 1)
        #expect(applied == WoodshedStoreSchema.currentVersion)
    }

    @Test("migrating twice is a no-op (idempotent)")
    func idempotentMigration() throws {
        var config = Configuration()
        config.foreignKeysEnabled = true
        let db = try DatabaseQueue(configuration: config)
        try WoodshedStoreSchema.migrator.migrate(db)
        try WoodshedStoreSchema.migrator.migrate(db)
        let applied = try woodshedStoreAppliedSchemaVersion(db)
        #expect(applied == 1)
    }

    @Test("all six ledger tables exist with columns")
    func tablesExist() throws {
        let store = try WoodshedStore.inMemory()
        let columnsByTable: [String: [String]] = try store.db.read { reader in
            var result: [String: [String]] = [:]
            for table in ["instruments", "pieces", "sessions", "session_splits", "tempo_logs", "practice_notes"] {
                result[table] = try reader.columns(in: table).map(\.name)
            }
            return result
        }
        for table in ["instruments", "pieces", "sessions", "session_splits", "tempo_logs", "practice_notes"] {
            #expect(columnsByTable[table]?.isEmpty == false, "table \(table) missing or columnless")
        }
        #expect(columnsByTable["session_splits"]?.contains("session_committed_at") == true)
        #expect(columnsByTable["tempo_logs"]?.contains("bpm") == true)
    }

    @Test("event tables allow multiple rows per entity id keyed by committed_at")
    func eventTablesAreAppendOnly() throws {
        let store = try WoodshedStore.inMemory()
        let instrument = Instrument(name: "Guitar")
        let piece = Piece(instrumentID: instrument.id, title: "Étude")
        try store.instruments.append(instrument, committedAt: Date(timeIntervalSince1970: 0))
        try store.pieces.append(piece, committedAt: Date(timeIntervalSince1970: 0))
        let session = Session(pieceID: piece.id, startedAt: Date(timeIntervalSince1970: 100), endedAt: Date(timeIntervalSince1970: 200))
        // Same session id, two committed events — both rows coexist.
        try store.sessions.append(session, committedAt: Date(timeIntervalSince1970: 300))
        try store.sessions.append(session, committedAt: Date(timeIntervalSince1970: 400))
        let rowCount = try store.db.read { reader in
            try Int.fetchOne(reader, sql: "SELECT COUNT(*) FROM sessions WHERE id = ?", arguments: [session.id.uuidString]) ?? -1
        }
        #expect(rowCount == 2)
        // Current-state resolution still yields one session.
        let current = try store.sessions.currentSessions()
        #expect(current.count == 1)
    }
}

@Suite("Cascade semantics")
struct CascadeTests {
    /// Seed one instrument, one piece, one session with one split, one tempo
    /// log and one note; return ids.
    private func seededFixture() throws -> (store: WoodshedStore, instrument: Instrument, piece: Piece, session: Session) {
        let store = try WoodshedStore.inMemory()
        let instrument = Instrument(name: "Guitar")
        let piece = Piece(instrumentID: instrument.id, title: "Étude")
        let session = Session(pieceID: piece.id, startedAt: Date(timeIntervalSince1970: 100), endedAt: Date(timeIntervalSince1970: 200))
        let split = SessionSplit(sessionID: session.id, label: "scales", startedAt: Date(timeIntervalSince1970: 100), endedAt: Date(timeIntervalSince1970: 150))
        let committed = Date(timeIntervalSince1970: 1)
        try store.instruments.append(instrument, committedAt: committed)
        try store.pieces.append(piece, committedAt: committed)
        try store.sessions.append(session, committedAt: committed)
        try store.sessions.append(split: split, sessionCommittedAt: committed, committedAt: committed)
        try store.tempoLogs.append(TempoLog(pieceID: piece.id, bpm: 90, loggedAt: Date(timeIntervalSince1970: 150)), committedAt: committed)
        try store.practiceNotes.append(PracticeNote(pieceID: piece.id, text: "note", writtenAt: Date(timeIntervalSince1970: 160)), committedAt: committed)
        return (store, instrument, piece, session)
    }

    private func tableCounts(_ store: WoodshedStore) throws -> [String: Int] {
        try store.db.read { reader in
            var counts: [String: Int] = [:]
            for table in ["instruments", "pieces", "sessions", "session_splits", "tempo_logs", "practice_notes"] {
                counts[table] = try Int.fetchOne(reader, sql: "SELECT COUNT(*) FROM \(table)") ?? -1
            }
            return counts
        }
    }

    @Test("deleting an instrument cascades to pieces and every event table")
    func instrumentCascade() throws {
        let (store, instrument, _, _) = try seededFixture()
        try store.db.write { writer in
            try writer.execute(sql: "DELETE FROM instruments WHERE id = ?", arguments: [instrument.id.uuidString])
        }
        let counts = try tableCounts(store)
        #expect(counts["pieces"] == 0)
        #expect(counts["sessions"] == 0)
        #expect(counts["session_splits"] == 0)
        #expect(counts["tempo_logs"] == 0)
        #expect(counts["practice_notes"] == 0)
    }

    @Test("deleting a piece cascades to its events but spares other pieces")
    func pieceCascade() throws {
        let (store, _, piece, _) = try seededFixture()
        // A second piece with its own session — must survive.
        let instrumentID = try store.instruments.allInstruments().first!.id
        let other = Piece(instrumentID: instrumentID, title: "Other")
        let committed = Date(timeIntervalSince1970: 2)
        try store.pieces.append(other, committedAt: committed)
        let otherSession = Session(pieceID: other.id, startedAt: Date(timeIntervalSince1970: 1000), endedAt: Date(timeIntervalSince1970: 1100))
        try store.sessions.append(otherSession, committedAt: committed)

        try store.db.write { writer in
            try writer.execute(sql: "DELETE FROM pieces WHERE id = ?", arguments: [piece.id.uuidString])
        }
        let surviving = try store.sessions.currentSessions()
        #expect(surviving.map(\.id) == [otherSession.id])
        let counts = try tableCounts(store)
        #expect(counts["tempo_logs"] == 0)
        #expect(counts["practice_notes"] == 0)
        #expect(counts["pieces"] == 1)
    }

    @Test("deleting a session event row cascades to its split rows")
    func sessionCascade() throws {
        let (store, _, _, session) = try seededFixture()
        let committed = Date(timeIntervalSince1970: 1)
        try store.db.write { writer in
            try writer.execute(
                sql: "DELETE FROM sessions WHERE id = ? AND committed_at = ?",
                arguments: [session.id.uuidString, committed]
            )
        }
        let counts = try tableCounts(store)
        #expect(counts["session_splits"] == 0)
    }

    @Test("foreign keys reject orphan event inserts at the database level")
    func foreignKeyEnforced() throws {
        let store = try WoodshedStore.inMemory()
        let ghostPiece = UUID()
        #expect(throws: (any Error).self) {
            try store.db.write { writer in
                try writer.execute(
                    sql: "INSERT INTO sessions (id, piece_id, started_at, ended_at, committed_at) VALUES ('s', ?, ?, ?, ?)",
                    arguments: [ghostPiece.uuidString, Date(), Date(), Date()]
                )
            }
        }
    }
}

import Foundation
import GRDB
import WoodshedKit

public enum StoreTransferError: Error, Equatable, LocalizedError, Sendable {
    case invalidBackup(String)
    case changedSincePreview

    public var errorDescription: String? {
        switch self {
        case .invalidBackup(let reason): return "This backup cannot be restored: \(reason)"
        case .changedSincePreview: return "The database changed since the preview. Choose the backup again."
        }
    }
}

public struct RestorePreview: Sendable {
    public let before: StorageUsage.TableCounts
    public let after: StorageUsage.TableCounts
    public let backupData: Data
    let beforeSnapshot: Data

    public var summary: String {
        "\(before.sessions) sessions become \(after.sessions) sessions; \(before.pieces) pieces become \(after.pieces) pieces."
    }
}

extension StorageUsage.TableCounts {
    static func read(_ db: Database) throws -> Self {
        func count(_ table: String) throws -> Int {
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM \(table)") ?? 0
        }
        return .init(instruments: try count("instruments"), pieces: try count("pieces"),
                     sessions: try count("sessions"), sessionSplits: try count("session_splits"),
                     tempoLogs: try count("tempo_logs"), practiceNotes: try count("practice_notes"))
    }
}

extension WoodshedStore {
    /// A snapshot of every persisted row, including superseded session, split,
    /// tempo and note events. The codec supplies versioning and JSON validation.
    public func backupData(generatedAt: Date = Date()) throws -> Data {
        let ledger = try db.read { reader in try Self.backupLedger(reader) }
        return try BackupCodec.encode(ledger, generatedAt: generatedAt)
    }

    private static func backupLedger(_ reader: Database) throws -> Ledger {
            var events: [LedgerEvent] = []
            func add(_ payload: LedgerPayload, _ date: Date, sessionDate: Date? = nil) {
                events.append(LedgerEvent(committedAt: date, payload: payload, sessionCommittedAt: sessionDate))
            }
            for row in try Row.fetchAll(reader, sql: "SELECT * FROM instruments ORDER BY id") {
                add(.instrument(Instrument(id: UUID(uuidString: row["id"])!, name: row["name"])), row["committed_at"])
            }
            for row in try Row.fetchAll(reader, sql: "SELECT * FROM pieces ORDER BY id") {
                guard let status = Piece.Status(rawValue: row["status"]) else {
                    throw StoreTransferError.invalidBackup("Unknown piece status in database")
                }
                add(.piece(Piece(id: UUID(uuidString: row["id"])!, instrumentID: UUID(uuidString: row["instrument_id"])!,
                                 title: row["title"], status: status, targetBPM: row["target_bpm"])), row["committed_at"])
            }
            for row in try Row.fetchAll(reader, sql: "SELECT * FROM sessions ORDER BY id, committed_at") {
                let id = UUID(uuidString: row["id"])!
                let committed: Date = row["committed_at"]
                add(.session(Session(id: id, pieceID: UUID(uuidString: row["piece_id"])!,
                                     startedAt: row["started_at"], endedAt: row["ended_at"])), committed)
                for split in try Row.fetchAll(reader, sql: "SELECT * FROM session_splits WHERE session_id = ? AND session_committed_at = ? ORDER BY id, committed_at", arguments: [id.uuidString, committed]) {
                    add(.sessionSplit(SessionSplit(id: UUID(uuidString: split["id"])!, sessionID: id,
                                                   label: split["label"], startedAt: split["started_at"], endedAt: split["ended_at"])),
                        split["committed_at"], sessionDate: committed)
                }
            }
            for row in try Row.fetchAll(reader, sql: "SELECT * FROM tempo_logs ORDER BY piece_id, logged_at, committed_at, id") {
                add(.tempoLog(TempoLog(id: UUID(uuidString: row["id"])!, pieceID: UUID(uuidString: row["piece_id"])!,
                                       bpm: row["bpm"], loggedAt: row["logged_at"])), row["committed_at"])
            }
            for row in try Row.fetchAll(reader, sql: "SELECT * FROM practice_notes ORDER BY id, committed_at") {
                add(.practiceNote(PracticeNote(id: UUID(uuidString: row["id"])!, pieceID: UUID(uuidString: row["piece_id"])!,
                                               text: row["text"], writtenAt: row["written_at"])), row["committed_at"])
            }
            return Ledger(events: events)
    }

    public func previewRestore(_ data: Data) throws -> RestorePreview {
        let ledger = try BackupCodec.decode(data)
        let before = try storageUsage().rows
        let beforeSnapshot = try backupData(generatedAt: Date(timeIntervalSinceReferenceDate: 0))
        let staging = try WoodshedStore.inMemory()
        try staging.db.write { writer in try Self.insert(ledger, into: writer) }
        return RestorePreview(before: before, after: try staging.storageUsage().rows,
                              backupData: data, beforeSnapshot: beforeSnapshot)
    }

    /// GRDB's write transaction rolls back the DELETEs and every insert on
    /// any error. The preview is checked again immediately before replacement.
    public func replace(with preview: RestorePreview) throws {
        let ledger = try BackupCodec.decode(preview.backupData)
        try db.write { writer in
            guard try StorageUsage.TableCounts.read(writer) == preview.before,
                  try BackupCodec.encode(Self.backupLedger(writer), generatedAt: Date(timeIntervalSinceReferenceDate: 0)) == preview.beforeSnapshot else {
                throw StoreTransferError.changedSincePreview
            }
            for table in ["session_splits", "sessions", "tempo_logs", "practice_notes", "pieces", "instruments"] {
                try writer.execute(sql: "DELETE FROM \(table)")
            }
            try Self.insert(ledger, into: writer)
            guard try StorageUsage.TableCounts.read(writer) == preview.after else {
                throw StoreTransferError.invalidBackup("Row counts differ from preview")
            }
        }
    }

    private static func insert(_ ledger: Ledger, into db: Database) throws {
        var sessionDates: [UUID: Set<Date>] = [:]
        for event in ledger.events {
            if event.kind != .sessionSplit && event.sessionCommittedAt != nil {
                throw StoreTransferError.invalidBackup("Only splits can name a session event")
            }
            switch event.payload {
            case .instrument(let value):
                try db.execute(sql: "INSERT INTO instruments VALUES (?, ?, ?)", arguments: [value.id.uuidString, value.name, event.committedAt])
            case .piece(let value):
                try db.execute(sql: "INSERT INTO pieces VALUES (?, ?, ?, ?, ?, ?)", arguments: [value.id.uuidString, value.instrumentID.uuidString, value.title, value.status.rawValue, value.targetBPM, event.committedAt])
            case .session(let value):
                guard value.endedAt >= value.startedAt else { throw StoreTransferError.invalidBackup("Session ends before it starts") }
                try db.execute(sql: "INSERT INTO sessions VALUES (?, ?, ?, ?, ?)", arguments: [value.id.uuidString, value.pieceID.uuidString, value.startedAt, value.endedAt, event.committedAt])
                sessionDates[value.id, default: []].insert(event.committedAt)
            case .sessionSplit(let value):
                let parent: Date
                if let explicit = event.sessionCommittedAt { parent = explicit }
                else if sessionDates[value.sessionID]?.count == 1 { parent = sessionDates[value.sessionID]!.first! }
                else { throw StoreTransferError.invalidBackup("Split has no unambiguous session event") }
                guard sessionDates[value.sessionID]?.contains(parent) == true else { throw StoreTransferError.invalidBackup("Split refers to a missing session event") }
                guard value.endedAt >= value.startedAt else { throw StoreTransferError.invalidBackup("Split ends before it starts") }
                guard let start: Date = try Date.fetchOne(db, sql: "SELECT started_at FROM sessions WHERE id = ? AND committed_at = ?", arguments: [value.sessionID.uuidString, parent]), value.startedAt >= start else {
                    throw StoreTransferError.invalidBackup("Split starts before its session")
                }
                try db.execute(sql: "INSERT INTO session_splits VALUES (?, ?, ?, ?, ?, ?, ?)", arguments: [value.id.uuidString, value.sessionID.uuidString, parent, value.label, value.startedAt, value.endedAt, event.committedAt])
            case .tempoLog(let value):
                guard value.bpm > 0 else { throw StoreTransferError.invalidBackup("Tempo must be positive") }
                let previous: Date? = try Date.fetchOne(db, sql: "SELECT MAX(logged_at) FROM tempo_logs WHERE piece_id = ?", arguments: [value.pieceID.uuidString])
                guard previous == nil || value.loggedAt >= previous! else { throw StoreTransferError.invalidBackup("Tempo history is out of order") }
                try db.execute(sql: "INSERT INTO tempo_logs VALUES (?, ?, ?, ?, ?)", arguments: [value.id.uuidString, value.pieceID.uuidString, value.bpm, value.loggedAt, event.committedAt])
            case .practiceNote(let value):
                try db.execute(sql: "INSERT INTO practice_notes VALUES (?, ?, ?, ?, ?)", arguments: [value.id.uuidString, value.pieceID.uuidString, value.text, value.writtenAt, event.committedAt])
            }
        }
    }
}

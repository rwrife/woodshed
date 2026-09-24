import Foundation
import WoodshedKit
import WoodshedStore

// Issue #3: in-memory fakes for app/UI tests.
//
// `InMemory*` repositories implement the same protocols as the GRDB
// implementations with the same append-only semantics (corrections =
// newer committedAt wins; tempo monotonicity enforced; splits attach to a
// session event). They back unit tests without a database file. All are
// backed by a lock-guarded store so they satisfy `Sendable`.

final class RepoLock: @unchecked Sendable {
    private var lock = NSLock()
    func withLock<R>(_ body: () throws -> R) rethrows -> R {
        lock.lock()
        defer { lock.unlock() }
        return try body()
    }
}

public final class InMemoryInstrumentRepository: InstrumentRepository, @unchecked Sendable {
    private let lock = RepoLock()
    private var stored: [UUID: (Instrument, Date)] = [:]

    public init() {}

    public func append(_ instrument: Instrument, committedAt: Date) throws {
        try lock.withLock {
            if let existing = stored[instrument.id], existing.1 > committedAt {
                stored[instrument.id] = existing  // older event never wins
            } else {
                stored[instrument.id] = (instrument, committedAt)
            }
        }
    }

    public func instrument(id: UUID) throws -> Instrument? {
        try lock.withLock { stored[id]?.0 }
    }

    public func allInstruments() throws -> [Instrument] {
        try lock.withLock {
            stored.values.map(\.0).sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        }
    }
}

public final class InMemoryPieceRepository: PieceRepository, @unchecked Sendable {
    private let lock = RepoLock()
    private var stored: [UUID: (Piece, Date)] = [:]
    /// Instruments that exist; wire to an InMemoryInstrumentRepository via
    /// `knownInstrumentIDs` or pre-register ids for tests.
    private var knownInstrumentIDs: Set<UUID> = []

    public init(knownInstrumentIDs: [UUID] = []) {
        self.knownInstrumentIDs = Set(knownInstrumentIDs)
    }

    public func registerInstrument(id: UUID) {
        try! lock.withLock { knownInstrumentIDs.insert(id) }
    }

    public func append(_ piece: Piece, committedAt: Date) throws {
        try lock.withLock {
            guard knownInstrumentIDs.contains(piece.instrumentID) else {
                throw WoodshedStoreError.parentNotFound(table: "instruments", id: piece.instrumentID)
            }
            if let existing = stored[piece.id], existing.1 > committedAt {
                stored[piece.id] = existing
            } else {
                stored[piece.id] = (piece, committedAt)
            }
        }
    }

    public func piece(id: UUID) throws -> Piece? {
        try lock.withLock { stored[id]?.0 }
    }

    public func allPieces() throws -> [Piece] {
        try lock.withLock {
            stored.values.map(\.0).sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
        }
    }

    public func pieces(instrumentID: UUID) throws -> [Piece] {
        try lock.withLock {
            stored.values.map(\.0)
                .filter { $0.instrumentID == instrumentID }
                .sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
        }
    }
}

public final class InMemorySessionRepository: SessionRepository, @unchecked Sendable {
    private let lock = RepoLock()
    private var sessionEvents: [(session: Session, committedAt: Date)] = []
    private var splitEvents: [(split: SessionSplit, sessionCommittedAt: Date, committedAt: Date)] = []
    private var knownPieceIDs: Set<UUID> = []

    public init(knownPieceIDs: [UUID] = []) {
        self.knownPieceIDs = Set(knownPieceIDs)
    }

    public func registerPiece(id: UUID) {
        try! lock.withLock { knownPieceIDs.insert(id) }
    }

    public func append(_ session: Session, committedAt: Date) throws {
        try lock.withLock {
            guard knownPieceIDs.contains(session.pieceID) else {
                throw WoodshedStoreError.parentNotFound(table: "pieces", id: session.pieceID)
            }
            sessionEvents.append((session, committedAt))
        }
    }

    public func append(split: SessionSplit, sessionCommittedAt: Date, committedAt: Date) throws {
        try lock.withLock {
            guard let sessionEvent = sessionEvents.first(where: {
                $0.session.id == split.sessionID && $0.committedAt == sessionCommittedAt
            }) else {
                throw WoodshedStoreError.parentNotFound(table: "sessions", id: split.sessionID)
            }
            guard split.startedAt >= sessionEvent.session.startedAt else {
                throw WoodshedStoreError.splitBeforeSessionStart(sessionID: split.sessionID, splitID: split.id)
            }
            splitEvents.append((split, sessionCommittedAt, committedAt))
        }
    }

    public func currentSessions() throws -> [Session] {
        try lock.withLock {
            var latest: [UUID: (Session, Date)] = [:]
            for event in sessionEvents {
                if let existing = latest[event.session.id], existing.1 >= event.committedAt { continue }
                latest[event.session.id] = (event.session, event.committedAt)
            }
            return latest.values.map(\.0).sorted { ($0.startedAt, $0.id.uuidString) < ($1.startedAt, $1.id.uuidString) }
        }
    }

    public func currentSplits(sessionID: UUID) throws -> [SessionSplit] {
        try lock.withLock {
            guard let sessionEvent = sessionEvents
                .filter({ $0.session.id == sessionID })
                .max(by: { $0.committedAt < $1.committedAt }) else { return [] }
            var latest: [UUID: (SessionSplit, Date)] = [:]
            for event in splitEvents
            where event.split.sessionID == sessionID && event.sessionCommittedAt == sessionEvent.committedAt {
                if let existing = latest[event.split.id], existing.1 >= event.committedAt { continue }
                latest[event.split.id] = (event.split, event.committedAt)
            }
            return latest.values.map(\.0).sorted { ($0.startedAt, $0.id.uuidString) < ($1.startedAt, $1.id.uuidString) }
        }
    }
}

public final class InMemoryTempoLogRepository: TempoLogRepository, @unchecked Sendable {
    private let lock = RepoLock()
    private var events: [TempoLog] = []
    private var knownPieceIDs: Set<UUID> = []

    public init(knownPieceIDs: [UUID] = []) {
        self.knownPieceIDs = Set(knownPieceIDs)
    }

    public func registerPiece(id: UUID) {
        try! lock.withLock { knownPieceIDs.insert(id) }
    }

    public func append(_ tempoLog: TempoLog, committedAt: Date) throws {
        _ = committedAt
        try lock.withLock {
            guard knownPieceIDs.contains(tempoLog.pieceID) else {
                throw WoodshedStoreError.parentNotFound(table: "pieces", id: tempoLog.pieceID)
            }
            if let previous = events.filter({ $0.pieceID == tempoLog.pieceID }).map(\.loggedAt).max(),
               tempoLog.loggedAt < previous {
                throw WoodshedStoreError.tempoLogOutOfOrder(
                    pieceID: tempoLog.pieceID,
                    loggedAt: tempoLog.loggedAt,
                    previousLoggedAt: previous
                )
            }
            events.append(tempoLog)
        }
    }

    public func tempoLogs(for pieceID: UUID) throws -> [TempoLog] {
        try lock.withLock {
            events.filter { $0.pieceID == pieceID }
                .sorted { ($0.loggedAt, $0.id.uuidString) < ($1.loggedAt, $1.id.uuidString) }
        }
    }
}

public final class InMemoryPracticeNoteRepository: PracticeNoteRepository, @unchecked Sendable {
    private let lock = RepoLock()
    private var events: [(note: PracticeNote, committedAt: Date)] = []
    private var knownPieceIDs: Set<UUID> = []

    public init(knownPieceIDs: [UUID] = []) {
        self.knownPieceIDs = Set(knownPieceIDs)
    }

    public func registerPiece(id: UUID) {
        try! lock.withLock { knownPieceIDs.insert(id) }
    }

    public func append(_ note: PracticeNote, committedAt: Date) throws {
        try lock.withLock {
            guard knownPieceIDs.contains(note.pieceID) else {
                throw WoodshedStoreError.parentNotFound(table: "pieces", id: note.pieceID)
            }
            events.append((note, committedAt))
        }
    }

    public func notes(for pieceID: UUID) throws -> [PracticeNote] {
        try lock.withLock {
            var latest: [UUID: (PracticeNote, Date)] = [:]
            for event in events where event.note.pieceID == pieceID {
                if let existing = latest[event.note.id], existing.1 >= event.committedAt { continue }
                latest[event.note.id] = (event.note, event.committedAt)
            }
            return latest.values.map(\.0).sorted { ($0.writtenAt, $0.id.uuidString) > ($1.writtenAt, $1.id.uuidString) }
        }
    }
}

/// A bundle of all fakes for app/UI tests.
public struct InMemoryRepositories: Sendable {
    public let instruments: InMemoryInstrumentRepository
    public let pieces: InMemoryPieceRepository
    public let sessions: InMemorySessionRepository
    public let tempoLogs: InMemoryTempoLogRepository
    public let practiceNotes: InMemoryPracticeNoteRepository

    public init() {
        instruments = InMemoryInstrumentRepository()
        pieces = InMemoryPieceRepository()
        sessions = InMemorySessionRepository()
        tempoLogs = InMemoryTempoLogRepository()
        practiceNotes = InMemoryPracticeNoteRepository()
    }
}

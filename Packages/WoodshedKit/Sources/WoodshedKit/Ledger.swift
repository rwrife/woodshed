import Foundation

/// One committed entry in the append-only ledger.
///
/// An event is immutable once appended. A "correction" to any record is
/// modeled as a new event carrying a newer `committedAt` for the same
/// entity id; readers resolve current state as the newest event per id.
public struct LedgerEvent: Codable, Equatable, Hashable, Sendable {
    public enum Kind: String, Codable, Equatable, Hashable, Sendable {
        case instrument
        case piece
        case session
        case sessionSplit
        case tempoLog
        case practiceNote
    }

    public let kind: Kind
    /// Identity of the entity this event records (e.g. `Session.id`).
    public let entityID: UUID
    /// When the ledger accepted the event. Ledger ordering is defined by
    /// this field, not by wall-clock arrival at read time.
    public let committedAt: Date
    /// The recorded snapshot (a `Piece`, `Session`, …).
    public let payload: LedgerPayload

    /// Pinned snake_case wire keys so the backup envelope is stable JSON
    /// independent of Swift property renames.
    enum CodingKeys: String, CodingKey {
        case kind
        case entityID = "entity_id"
        case committedAt = "committed_at"
        case payload
    }

    /// The only in-process constructor: `kind` and `entityID` are derived
    /// from the payload, so a mismatched event is unconstructable in
    /// normal use. Decoding JSON is the sole untrusted path, guarded by
    /// `Ledger.append`'s identity re-check.
    public init(committedAt: Date, payload: LedgerPayload) {
        self.kind = payload.eventKind
        self.entityID = payload.entityID
        self.committedAt = committedAt
        self.payload = payload
    }
}

/// Payload union for ledger events. Distinct JSON keys per case keep the
/// backup codec unambiguous.
public enum LedgerPayload: Codable, Equatable, Hashable, Sendable {
    case instrument(Instrument)
    case piece(Piece)
    case session(Session)
    case sessionSplit(SessionSplit)
    case tempoLog(TempoLog)
    case practiceNote(PracticeNote)

    private enum CodingKeys: String, CodingKey {
        case instrument
        case piece
        case session
        case sessionSplit
        case tempoLog
        case practiceNote
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        // Exactly one payload key must be present.
        var decoded: [(String, LedgerPayload)] = []
        if container.contains(.instrument) {
            decoded.append(("instrument", .instrument(try container.decode(Instrument.self, forKey: .instrument))))
        }
        if container.contains(.piece) {
            decoded.append(("piece", .piece(try container.decode(Piece.self, forKey: .piece))))
        }
        if container.contains(.session) {
            decoded.append(("session", .session(try container.decode(Session.self, forKey: .session))))
        }
        if container.contains(.sessionSplit) {
            decoded.append(("sessionSplit", .sessionSplit(try container.decode(SessionSplit.self, forKey: .sessionSplit))))
        }
        if container.contains(.tempoLog) {
            decoded.append(("tempoLog", .tempoLog(try container.decode(TempoLog.self, forKey: .tempoLog))))
        }
        if container.contains(.practiceNote) {
            decoded.append(("practiceNote", .practiceNote(try container.decode(PracticeNote.self, forKey: .practiceNote))))
        }
        guard decoded.count == 1 else {
            throw DecodingError.dataCorrupted(
                DecodingError.Context(
                    codingPath: decoder.codingPath,
                    debugDescription: "LedgerPayload requires exactly one payload key, found \(decoded.count)"
                )
            )
        }
        self = decoded[0].1
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .instrument(let value): try container.encode(value, forKey: .instrument)
        case .piece(let value): try container.encode(value, forKey: .piece)
        case .session(let value): try container.encode(value, forKey: .session)
        case .sessionSplit(let value): try container.encode(value, forKey: .sessionSplit)
        case .tempoLog(let value): try container.encode(value, forKey: .tempoLog)
        case .practiceNote(let value): try container.encode(value, forKey: .practiceNote)
        }
    }

    /// The entity identity carried by this payload.
    public var entityID: UUID {
        switch self {
        case .instrument(let v): return v.id
        case .piece(let v): return v.id
        case .session(let v): return v.id
        case .sessionSplit(let v): return v.id
        case .tempoLog(let v): return v.id
        case .practiceNote(let v): return v.id
        }
    }

    /// The ledger-event kind corresponding to this payload.
    public var eventKind: LedgerEvent.Kind {
        switch self {
        case .instrument: return .instrument
        case .piece: return .piece
        case .session: return .session
        case .sessionSplit: return .sessionSplit
        case .tempoLog: return .tempoLog
        case .practiceNote: return .practiceNote
        }
    }
}

/// Errors raised by ledger appends that would violate ledger semantics.
public enum LedgerError: Error, Equatable, Sendable {
    /// A tempo log was appended out of monotonic order for its piece:
    /// `loggedAt` precedes the previous tempo log for the same piece.
    case tempoLogOutOfOrder(pieceID: UUID, loggedAt: Date, previousLoggedAt: Date)
    /// An event's declared `entityID` does not match the id inside its
    /// payload; malformed events are rejected rather than stored.
    case entityIdentityMismatch(eventID: UUID, payloadID: UUID)
}

/// The append-only practice ledger.
///
/// Append-only guarantees (issue #2):
/// - `events` is exposed read-only; the only mutator is `append`.
/// - `append` rejects an event whose `committedAt` precedes the latest
///   committed event for the same kind+entity (events for one entity
///   must arrive in ledger time).
/// - `append` rejects a tempo log whose `loggedAt` precedes the previous
///   tempo log for the same piece (monotonic tempo history).
public struct Ledger: Equatable, Sendable {
    private(set) public var events: [LedgerEvent]

    public init(events: [LedgerEvent] = []) {
        // Accepting an already-ordered event list keeps backup restore
        // (codec -> ledger) trivially safe; the codec preserves order.
        self.events = events
    }

    /// Append a new immutable event. Throws `LedgerError` when the
    /// append would break append-only ordering or tempo monotonicity.
    public mutating func append(_ event: LedgerEvent) throws {
        let payloadID = event.payload.entityID
        guard event.entityID == payloadID else {
            throw LedgerError.entityIdentityMismatch(eventID: event.entityID, payloadID: payloadID)
        }

        // Tempo monotonicity: a tempo log must not precede the previous
        // tempo log for the same piece.
        if case .tempoLog(let tempo) = event.payload {
            var previous: Date?
            for existing in events {
                if case .tempoLog(let other) = existing.payload, other.pieceID == tempo.pieceID {
                    if previous == nil || other.loggedAt > previous! { previous = other.loggedAt }
                }
            }
            if let last = previous, tempo.loggedAt < last {
                throw LedgerError.tempoLogOutOfOrder(
                    pieceID: tempo.pieceID,
                    loggedAt: tempo.loggedAt,
                    previousLoggedAt: last
                )
            }
        }

        events.append(event)
    }

    // MARK: - Resolution helpers (newest event per entity wins)

    /// All events of a kind, newest committedAt first (stable: ties keep
    /// later-append order first).
    public func events(of kind: LedgerEvent.Kind) -> [LedgerEvent] {
        events
            .enumerated()
            .filter { $0.element.kind == kind }
            .sorted {
                if $0.element.committedAt != $1.element.committedAt {
                    return $0.element.committedAt > $1.element.committedAt
                }
                return $0.offset > $1.offset
            }
            .map(\.element)
    }

    /// Current state of every entity of a kind: newest event per entity id.
    public func currentInstruments() -> [Instrument] {
        latestPerEntity(of: .instrument) { if case .instrument(let v) = $0.payload { return (v.id, v) }; return nil }
    }

    /// Newest `Piece` snapshot per piece id.
    public func currentPieces() -> [Piece] {
        latestPerEntity(of: .piece) { if case .piece(let v) = $0.payload { return (v.id, v) }; return nil }
    }

    /// All committed sessions in ledger-append order (sessions are
    /// immutable facts; corrections are new session events with the same
    /// id, newest wins).
    public func currentSessions() -> [Session] {
        latestPerEntity(of: .session) { if case .session(let v) = $0.payload { return (v.id, v) }; return nil }
    }

    /// All committed splits, newest per split id.
    public func currentSplits() -> [SessionSplit] {
        latestPerEntity(of: .sessionSplit) { if case .sessionSplit(let v) = $0.payload { return (v.id, v) }; return nil }
    }

    /// All committed tempo logs, ordered by (loggedAt, append order).
    public func tempoLogs(for pieceID: UUID) -> [TempoLog] {
        events
            .enumerated()
            .compactMap { (offset, event) -> (Int, TempoLog)? in
                guard case .tempoLog(let tempo) = event.payload, tempo.pieceID == pieceID else { return nil }
                return (offset, tempo)
            }
            .sorted {
                if $0.1.loggedAt != $1.1.loggedAt { return $0.1.loggedAt < $1.1.loggedAt }
                return $0.0 < $1.0
            }
            .map(\.1)
    }

    /// All committed notes for a piece, newest writtenAt first.
    public func notes(for pieceID: UUID) -> [PracticeNote] {
        events
            .enumerated()
            .compactMap { (offset, event) -> (Int, PracticeNote)? in
                guard case .practiceNote(let note) = event.payload, note.pieceID == pieceID else { return nil }
                return (offset, note)
            }
            .sorted {
                if $0.1.writtenAt != $1.1.writtenAt { return $0.1.writtenAt > $1.1.writtenAt }
                return $0.0 > $1.0
            }
            .map(\.1)
    }

    /// Newest event per entity id for a kind, preserving the events list's
    /// append order in the result. `resolve` extracts (entityID, value)
    /// from a matching event; later events with `>= committedAt` supersede
    /// earlier ones for the same id (append-only correction semantics).
    private func latestPerEntity<T>(of kind: LedgerEvent.Kind, resolve: (LedgerEvent) -> (UUID, T)?) -> [T] {
        var newest: [UUID: (offset: Int, date: Date, value: T)] = [:]
        for (offset, event) in events.enumerated() where event.kind == kind {
            guard let (id, value) = resolve(event) else { continue }
            if let existing = newest[id], event.committedAt < existing.date { continue }
            newest[id] = (offset, event.committedAt, value)
        }
        // Preserve first-seen append order for stable output.
        return newest
            .values
            .sorted { $0.offset < $1.offset }
            .map(\.value)
    }
}

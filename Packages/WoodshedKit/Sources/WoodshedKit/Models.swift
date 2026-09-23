import Foundation

// All domain value types are immutable snapshots. The only way history
// changes is by appending a new event to the `Ledger` — a "correction"
// is simply a newer event for the same identity, and readers take the
// newest event per identity as the current state.

/// A physical instrument the user practices (e.g. "Guitar").
public struct Instrument: Codable, Equatable, Hashable, Sendable {
    public let id: UUID
    public let name: String

    public init(id: UUID = UUID(), name: String) {
        self.id = id
        self.name = name
    }
}

/// A piece of music tracked across practice sessions.
public struct Piece: Codable, Equatable, Hashable, Sendable {
    /// Lifecycle state of a piece in the practice wall.
    public enum Status: String, Codable, Equatable, Hashable, Sendable {
        case active
        case maintenance
        case retired
    }

    public let id: UUID
    public let instrumentID: UUID
    public let title: String
    public let status: Status
    /// Optional user-set target tempo in BPM (integer, never float).
    public let targetBPM: Int?

    public init(
        id: UUID = UUID(),
        instrumentID: UUID,
        title: String,
        status: Status = .active,
        targetBPM: Int? = nil
    ) {
        self.id = id
        self.instrumentID = instrumentID
        self.title = title
        self.status = status
        self.targetBPM = targetBPM
    }
}

/// A practice session. Wall-clock anchored: `startedAt`/`endedAt` are
/// absolute instants, so sessions remain correct across DST transitions.
public struct Session: Codable, Equatable, Hashable, Sendable {
    public let id: UUID
    public let pieceID: UUID
    public let startedAt: Date
    public let endedAt: Date

    public init(id: UUID = UUID(), pieceID: UUID, startedAt: Date, endedAt: Date) {
        self.id = id
        self.pieceID = pieceID
        self.startedAt = startedAt
        self.endedAt = endedAt
    }
}

/// A subdivision of a session (e.g. scales vs. repertoire). Also
/// wall-clock anchored.
public struct SessionSplit: Codable, Equatable, Hashable, Sendable {
    public let id: UUID
    public let sessionID: UUID
    public let label: String
    public let startedAt: Date
    public let endedAt: Date

    public init(
        id: UUID = UUID(),
        sessionID: UUID,
        label: String,
        startedAt: Date,
        endedAt: Date
    ) {
        self.id = id
        self.sessionID = sessionID
        self.label = label
        self.startedAt = startedAt
        self.endedAt = endedAt
    }
}

/// A user-entered tempo observation for a piece. Tempo history is
/// appended monotonically in time: the ledger rejects a tempo log whose
/// `loggedAt` precedes the previous log for the same piece. BPM is an
/// exact integer.
public struct TempoLog: Codable, Equatable, Hashable, Sendable {
    public let id: UUID
    public let pieceID: UUID
    public let bpm: Int
    public let loggedAt: Date

    public init(id: UUID = UUID(), pieceID: UUID, bpm: Int, loggedAt: Date) {
        self.id = id
        self.pieceID = pieceID
        self.bpm = bpm
        self.loggedAt = loggedAt
    }
}

/// A free-text practice note attached to a piece.
public struct PracticeNote: Codable, Equatable, Hashable, Sendable {
    public let id: UUID
    public let pieceID: UUID
    public let text: String
    public let writtenAt: Date

    public init(id: UUID = UUID(), pieceID: UUID, text: String, writtenAt: Date) {
        self.id = id
        self.pieceID = pieceID
        self.text = text
        self.writtenAt = writtenAt
    }
}

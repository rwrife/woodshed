import Foundation
import GRDB
import Testing
import WoodshedKit
import WoodshedStore
import WoodshedStoreTestSupport

// Issue #3: repository CRUD-via-append behavior — every GRDB implementation
// is exercised against its in-memory fake, which must behave identically.

private func date(_ seconds: TimeInterval) -> Date { Date(timeIntervalSince1970: seconds) }

/// Drives the identical scenario through a GRDB-backed and an in-memory
/// repository bundle and asserts both produce the same results.
private struct ScenarioHarness {
    let store: WoodshedStore  // GRDB side (in-memory database)
    let fake: InMemoryRepositories
    let instrument: Instrument
    let piece: Piece

    init() throws {
        store = try WoodshedStore.inMemory()
        fake = InMemoryRepositories()
        instrument = Instrument(name: "Guitar")
        piece = Piece(instrumentID: instrument.id, title: "Étude", status: .active, targetBPM: 120)
        try store.instruments.append(instrument, committedAt: date(1))
        try store.pieces.append(piece, committedAt: date(1))
        fake.pieces.registerInstrument(id: instrument.id)
        try fake.instruments.append(instrument, committedAt: date(1))
        try fake.pieces.append(piece, committedAt: date(1))
    }
}

@Suite("Repository append semantics")
struct RepositoryTests {
    @Test("append then fetch round-trips all domain fields")
    func appendRoundTrip() throws {
        let harness = try ScenarioHarness()
        let storedPiece = try #require(try harness.store.pieces.piece(id: harness.piece.id))
        #expect(storedPiece == harness.piece)

        let storedInstrument = try #require(try harness.store.instruments.instrument(id: harness.instrument.id))
        #expect(storedInstrument == harness.instrument)
    }

    @Test("piece correction replaces the current state (newest committedAt wins)")
    func pieceCorrection() throws {
        let harness = try ScenarioHarness()
        let correction = Piece(id: harness.piece.id, instrumentID: harness.instrument.id, title: "Étude (urtext)", status: .maintenance, targetBPM: 132)
        try harness.store.pieces.append(correction, committedAt: date(10))
        let current = try #require(try harness.store.pieces.piece(id: harness.piece.id))
        #expect(current.title == "Étude (urtext)")
        #expect(current.status == .maintenance)
        #expect(current.targetBPM == 132)

        // An older event can never roll state backwards.
        let stale = Piece(id: harness.piece.id, instrumentID: harness.instrument.id, title: "stale", status: .active, targetBPM: 1)
        try harness.store.pieces.append(stale, committedAt: date(5))
        let stillCurrent = try #require(try harness.store.pieces.piece(id: harness.piece.id))
        #expect(stillCurrent.title == "Étude (urtext)")
    }

    @Test("parent references are validated before insert")
    func parentValidation() throws {
        let store = try WoodshedStore.inMemory()
        let ghost = UUID()
        #expect(throws: WoodshedStoreError.parentNotFound(table: "instruments", id: ghost)) {
            try store.pieces.append(Piece(instrumentID: ghost, title: "orphan"), committedAt: date(1))
        }
        #expect(throws: WoodshedStoreError.parentNotFound(table: "pieces", id: ghost)) {
            try store.sessions.append(Session(pieceID: ghost, startedAt: date(1), endedAt: date(2)), committedAt: date(1))
        }
        #expect(throws: WoodshedStoreError.parentNotFound(table: "pieces", id: ghost)) {
            try store.tempoLogs.append(TempoLog(pieceID: ghost, bpm: 100, loggedAt: date(1)), committedAt: date(1))
        }
        #expect(throws: WoodshedStoreError.parentNotFound(table: "pieces", id: ghost)) {
            try store.practiceNotes.append(PracticeNote(pieceID: ghost, text: "x", writtenAt: date(1)), committedAt: date(1))
        }
    }

    @Test("tempo monotonicity: out-of-order appends are rejected, equal timestamps allowed")
    func tempoMonotonicity() throws {
        let harness = try ScenarioHarness()
        try harness.store.tempoLogs.append(TempoLog(pieceID: harness.piece.id, bpm: 90, loggedAt: date(100)), committedAt: date(1))
        try harness.store.tempoLogs.append(TempoLog(pieceID: harness.piece.id, bpm: 95, loggedAt: date(200)), committedAt: date(1))
        #expect(throws: WoodshedStoreError.tempoLogOutOfOrder(pieceID: harness.piece.id, loggedAt: date(150), previousLoggedAt: date(200))) {
            try harness.store.tempoLogs.append(TempoLog(pieceID: harness.piece.id, bpm: 80, loggedAt: date(150)), committedAt: date(1))
        }
        // Equal loggedAt is permitted (two songs measured in one session).
        try harness.store.tempoLogs.append(TempoLog(pieceID: harness.piece.id, bpm: 95, loggedAt: date(200)), committedAt: date(2))
        let logs = try harness.store.tempoLogs.tempoLogs(for: harness.piece.id)
        #expect(logs.map(\.bpm) == [90, 95, 95])
        #expect(logs.map(\.loggedAt) == [date(100), date(200), date(200)])
    }

    @Test("splits attach to a session event; early splits rejected")
    func splitSemantics() throws {
        let harness = try ScenarioHarness()
        let session = Session(pieceID: harness.piece.id, startedAt: date(100), endedAt: date(200))
        try harness.store.sessions.append(session, committedAt: date(1))
        let split = SessionSplit(sessionID: session.id, label: "scales", startedAt: date(100), endedAt: date(150))
        try harness.store.sessions.append(split: split, sessionCommittedAt: date(1), committedAt: date(1))
        let splits = try harness.store.sessions.currentSplits(sessionID: session.id)
        #expect(splits.map(\.label) == ["scales"])

        let early = SessionSplit(sessionID: session.id, label: "early", startedAt: date(99), endedAt: date(150))
        #expect(throws: WoodshedStoreError.splitBeforeSessionStart(sessionID: session.id, splitID: early.id)) {
            try harness.store.sessions.append(
                split: early,
                sessionCommittedAt: date(1), committedAt: date(1)
            )
        }
        #expect(throws: (any Error).self) {
            try harness.store.sessions.append(
                split: SessionSplit(sessionID: UUID(), label: "ghost", startedAt: date(100), endedAt: date(150)),
                sessionCommittedAt: date(1), committedAt: date(1)
            )
        }
    }

    @Test("GRDB and in-memory repositories agree on the full ledger scenario")
    func grdbMatchesInMemory() throws {
        let harness = try ScenarioHarness()
        let session = Session(pieceID: harness.piece.id, startedAt: date(100), endedAt: date(200))
        let split = SessionSplit(sessionID: session.id, label: "scales", startedAt: date(100), endedAt: date(150))
        let note = PracticeNote(pieceID: harness.piece.id, text: "rushes at bar 32", writtenAt: date(201))
        let tempo = TempoLog(pieceID: harness.piece.id, bpm: 90, loggedAt: date(150))

        // GRDB side
        try harness.store.sessions.append(session, committedAt: date(1))
        try harness.store.sessions.append(split: split, sessionCommittedAt: date(1), committedAt: date(1))
        try harness.store.tempoLogs.append(tempo, committedAt: date(1))
        try harness.store.practiceNotes.append(note, committedAt: date(1))

        // In-memory side (same inputs)
        try harness.fake.sessions.registerPiece(id: harness.piece.id)
        try harness.fake.tempoLogs.registerPiece(id: harness.piece.id)
        try harness.fake.practiceNotes.registerPiece(id: harness.piece.id)
        try harness.fake.sessions.append(session, committedAt: date(1))
        try harness.fake.sessions.append(split: split, sessionCommittedAt: date(1), committedAt: date(1))
        try harness.fake.tempoLogs.append(tempo, committedAt: date(1))
        try harness.fake.practiceNotes.append(note, committedAt: date(1))

        #expect(try harness.store.sessions.currentSessions() == harness.fake.sessions.currentSessions())
        #expect(try harness.store.sessions.currentSplits(sessionID: session.id) == harness.fake.sessions.currentSplits(sessionID: session.id))
        #expect(try harness.store.tempoLogs.tempoLogs(for: harness.piece.id) == harness.fake.tempoLogs.tempoLogs(for: harness.piece.id))
        #expect(try harness.store.practiceNotes.notes(for: harness.piece.id) == harness.fake.practiceNotes.notes(for: harness.piece.id))
        #expect(try harness.store.pieces.allPieces() == harness.fake.pieces.allPieces())

        // Both enforce tempo monotonicity identically.
        #expect(throws: WoodshedStoreError.tempoLogOutOfOrder(pieceID: harness.piece.id, loggedAt: date(140), previousLoggedAt: date(150))) {
            try harness.store.tempoLogs.append(TempoLog(pieceID: harness.piece.id, bpm: 80, loggedAt: date(140)), committedAt: date(2))
        }
        #expect(throws: WoodshedStoreError.tempoLogOutOfOrder(pieceID: harness.piece.id, loggedAt: date(140), previousLoggedAt: date(150))) {
            try harness.fake.tempoLogs.append(TempoLog(pieceID: harness.piece.id, bpm: 80, loggedAt: date(140)), committedAt: date(2))
        }
    }

    @Test("notes: newest event per id wins, newest written first")
    func noteOrdering() throws {
        let harness = try ScenarioHarness()
        let noteID = UUID()
        let committed = Date(timeIntervalSince1970: 1)
        try harness.store.practiceNotes.append(
            PracticeNote(id: noteID, pieceID: harness.piece.id, text: "first", writtenAt: date(100)),
            committedAt: committed
        )
        try harness.store.practiceNotes.append(
            PracticeNote(id: noteID, pieceID: harness.piece.id, text: "corrected", writtenAt: date(100)),
            committedAt: date(5)
        )
        let other = PracticeNote(id: UUID(), pieceID: harness.piece.id, text: "later", writtenAt: date(200))
        try harness.store.practiceNotes.append(other, committedAt: committed)
        let notes = try harness.store.practiceNotes.notes(for: harness.piece.id)
        #expect(notes.map(\.text) == ["later", "corrected"])
    }

    @Test("storage usage reports row counts and on-disk byte size")
    func storageUsage() throws {
        let harness = try ScenarioHarness()
        let usage = try harness.store.storageUsage()
        #expect(usage.rows.instruments == 1)
        #expect(usage.rows.pieces == 1)
        #expect(usage.rows.sessions == 0)
        #expect(usage.databaseBytes > 0)
    }
}

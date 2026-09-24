import Foundation
import GRDB
import Testing
import WoodshedKit
import WoodshedStore

// Issue #3: migrations against the committed v1 fixture database.
//
// The fixture (Tests/WoodshedStoreTests/Fixtures/v1.sqlite) is a real v1-schema
// file with seeded rows, produced by fixture-seed + Scripts/make_fixture_db.py.
// These tests copy it to a temp location, run the production migrator, and
// assert that v1 data survives unchanged and the schema is current.

private func fixtureURL() -> URL {
    // Anchor on this source file: swift-test working directories differ
    // between `swift test` and Xcode, but #filePath does not.
    URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .appendingPathComponent("Fixtures/v1.sqlite")
}

/// Copies the fixture to a throwaway file and opens it with the production
/// migrator, mirroring `WoodshedStore.open(at:)`.
private func migratedFixture() throws -> (store: WoodshedStore, fileURL: URL) {
    let tempDirectory = FileManager.default.temporaryDirectory
        .appendingPathComponent("WoodshedStore-migration-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: tempDirectory, withIntermediateDirectories: true)
    let fileURL = tempDirectory.appendingPathComponent("woodshed.sqlite")
    try FileManager.default.copyItem(at: fixtureURL(), to: fileURL)

    var config = Configuration()
    config.foreignKeysEnabled = true
    let db = try DatabaseQueue(path: fileURL.path, configuration: config)
    try WoodshedStoreSchema.migrator.migrate(db)
    return (WoodshedStore(db: db), fileURL)
}

private func fixedUUID(_ hex: String) -> UUID { UUID(uuidString: hex)! }
private func fixedDate(_ iso: String) -> Date {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    guard let date = formatter.date(from: iso) else { fatalError("bad fixed date \(iso)") }
    return date
}

private let instrumentID = fixedUUID("11111111-1111-1111-1111-111111111111")
private let pieceID = fixedUUID("22222222-2222-2222-2222-222222222222")
private let retiredPieceID = fixedUUID("33333333-3333-3333-3333-333333333333")
private let sessionID = fixedUUID("44444444-4444-4444-4444-444444444444")

@Suite("Schema migration v1 -> current", .serialized)
struct MigrationTests {
    @Test("v1 fixture upgrades and reports the current schema version")
    func fixtureUpgradesToCurrent() throws {
        let (store, fileURL) = try migratedFixture()
        defer { try? FileManager.default.removeItem(at: fileURL.deletingLastPathComponent()) }
        let applied = try woodshedStoreAppliedSchemaVersion(store.db)
        #expect(applied == WoodshedStoreSchema.currentVersion)
        #expect(applied == 1)  // v1 baseline
    }

    @Test("a fresh database reaches the same version as a migrated fixture")
    func freshEqualsMigrated() throws {
        let (store, fileURL) = try migratedFixture()
        defer { try? FileManager.default.removeItem(at: fileURL.deletingLastPathComponent()) }
        let fresh = try WoodshedStore.inMemory()
        let migratedVersion = try woodshedStoreAppliedSchemaVersion(store.db)
        let freshVersion = try woodshedStoreAppliedSchemaVersion(fresh.db)
        #expect(migratedVersion == freshVersion)
    }

    @Test("fixture ledger contents survive the migration exactly")
    func fixtureDataSurvives() throws {
        let (store, fileURL) = try migratedFixture()
        defer { try? FileManager.default.removeItem(at: fileURL.deletingLastPathComponent()) }

        let instrument = try #require(try store.instruments.instrument(id: instrumentID))
        #expect(instrument.name == "Fixture Guitar")

        let piece = try #require(try store.pieces.piece(id: pieceID))
        #expect(piece == Piece(
            id: pieceID, instrumentID: instrumentID, title: "Fixture Étude",
            status: .active, targetBPM: 120
        ))
        let retired = try #require(try store.pieces.piece(id: retiredPieceID))
        #expect(retired.status == .retired)
        #expect(retired.targetBPM == nil)

        let sessions = try store.sessions.currentSessions()
        #expect(sessions.count == 1)
        let session = try #require(sessions.first)
        #expect(session.id == sessionID)
        #expect(session.pieceID == pieceID)
        #expect(session.startedAt == fixedDate("2026-01-08T09:00:00.000Z"))
        #expect(session.endedAt == fixedDate("2026-01-08T09:45:00.000Z"))

        let splits = try store.sessions.currentSplits(sessionID: sessionID)
        #expect(splits.map(\.label) == ["scales", "repertoire"])

        let tempos = try store.tempoLogs.tempoLogs(for: pieceID)
        #expect(tempos.map(\.bpm) == [90, 100])

        let notes = try store.practiceNotes.notes(for: pieceID)
        #expect(notes.map(\.text) == ["Fixture note: left hand rushes at the modulation."])

        let usage = try store.storageUsage()
        #expect(usage.rows == StorageUsage.TableCounts(
            instruments: 1, pieces: 2, sessions: 1, sessionSplits: 2, tempoLogs: 2, practiceNotes: 1
        ))
        #expect(usage.databaseBytes > 0)  // on-disk file, unlike in-memory
    }

    @Test("appending to the migrated fixture works (tempo monotonicity holds)")
    func appendAfterMigration() throws {
        let (store, fileURL) = try migratedFixture()
        defer { try? FileManager.default.removeItem(at: fileURL.deletingLastPathComponent()) }
        // Out-of-order relative to fixture data must be rejected.
        #expect(throws: WoodshedStoreError.tempoLogOutOfOrder(
            pieceID: pieceID, loggedAt: fixedDate("2026-01-01T00:00:00.000Z"),
            previousLoggedAt: fixedDate("2026-02-01T18:30:00.000Z")
        )) {
            try store.tempoLogs.append(
                TempoLog(pieceID: pieceID, bpm: 50, loggedAt: fixedDate("2026-01-01T00:00:00.000Z")),
                committedAt: fixedDate("2026-03-01T00:00:00.000Z")
            )
        }
        // A legal append succeeds.
        try store.tempoLogs.append(
            TempoLog(pieceID: pieceID, bpm: 108, loggedAt: fixedDate("2026-03-01T12:00:00.000Z")),
            committedAt: fixedDate("2026-03-01T12:00:00.000Z")
        )
        let tempos = try store.tempoLogs.tempoLogs(for: pieceID)
        #expect(tempos.map(\.bpm) == [90, 100, 108])
    }

    @Test("cascade delete works after migrating the fixture")
    func cascadeAfterMigration() throws {
        let (store, fileURL) = try migratedFixture()
        defer { try? FileManager.default.removeItem(at: fileURL.deletingLastPathComponent()) }
        try store.db.write { writer in
            try writer.execute(sql: "DELETE FROM pieces WHERE id = ?", arguments: [pieceID.uuidString])
        }
        let remainingPieces = try store.pieces.allPieces()
        #expect(remainingPieces.map(\.id) == [retiredPieceID])
        let tempos = try store.tempoLogs.tempoLogs(for: pieceID)
        #expect(tempos.isEmpty)
    }
}

import Foundation
import GRDB
import WoodshedKit
import WoodshedStore

// Deterministic seeder for the committed schema-v1 fixture
// (Tests/WoodshedStoreTests/Fixtures/v1.sqlite).
//
// It applies the real WoodshedStoreSchema v1 migration and inserts one
// instrument, two pieces, one session with two splits, two tempo logs and
// one practice note — all with FIXED dates and fixed UUIDs, so the fixture
// is stable and the migration tests can assert exact contents.
// Run via Scripts/make_fixture_db.py — never hand-edit the result.

let arguments = CommandLine.arguments
guard arguments.count == 2 else {
    FileHandle.standardError.write(Data("usage: fixture-seed <output.sqlite>\n".utf8))
    exit(2)
}
let outputURL = URL(fileURLWithPath: arguments[1])
try? FileManager.default.removeItem(at: outputURL)

var config = Configuration()
config.foreignKeysEnabled = true
let db = try DatabaseQueue(path: outputURL.path, configuration: config)
try WoodshedStoreSchema.migrator.migrate(db)

func fixedDate(_ iso: String) -> Date {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    guard let date = formatter.date(from: iso) else {
        fatalError("bad fixed date \(iso)")
    }
    return date
}

// Fixed identities — deterministic across runs and platforms.
func fixedUUID(_ hex: String) -> UUID {
    guard let uuid = UUID(uuidString: hex) else { fatalError("bad uuid \(hex)") }
    return uuid
}
let instrumentID = fixedUUID("11111111-1111-1111-1111-111111111111")
let pieceID = fixedUUID("22222222-2222-2222-2222-222222222222")
let retiredPieceID = fixedUUID("33333333-3333-3333-3333-333333333333")
let sessionID = fixedUUID("44444444-4444-4444-4444-444444444444")
let split1ID = fixedUUID("55555555-5555-5555-5555-555555555555")
let split2ID = fixedUUID("66666666-6666-6666-6666-666666666666")
let tempo1ID = fixedUUID("77777777-7777-7777-7777-777777777777")
let tempo2ID = fixedUUID("88888888-8888-8888-8888-888888888888")
let noteID = fixedUUID("99999999-9999-9999-9999-999999999999")

let committed = fixedDate("2026-01-01T00:00:00.000Z")

let store = WoodshedStore(db: db)
try store.instruments.append(
    Instrument(id: instrumentID, name: "Fixture Guitar"),
    committedAt: committed
)
try store.pieces.append(
    Piece(id: pieceID, instrumentID: instrumentID, title: "Fixture Étude", status: .active, targetBPM: 120),
    committedAt: committed
)
try store.pieces.append(
    Piece(id: retiredPieceID, instrumentID: instrumentID, title: "Fixture Prelude", status: .retired, targetBPM: nil),
    committedAt: committed
)
let sessionStart = fixedDate("2026-01-08T09:00:00.000Z")
let sessionEnd = fixedDate("2026-01-08T09:45:00.000Z")
try store.sessions.append(
    Session(id: sessionID, pieceID: pieceID, startedAt: sessionStart, endedAt: sessionEnd),
    committedAt: committed
)
try store.sessions.append(
    split: SessionSplit(
        id: split1ID, sessionID: sessionID, label: "scales",
        startedAt: sessionStart, endedAt: fixedDate("2026-01-08T09:15:00.000Z")
    ),
    sessionCommittedAt: committed,
    committedAt: committed
)
try store.sessions.append(
    split: SessionSplit(
        id: split2ID, sessionID: sessionID, label: "repertoire",
        startedAt: fixedDate("2026-01-08T09:15:00.000Z"), endedAt: sessionEnd
    ),
    sessionCommittedAt: committed,
    committedAt: committed
)
try store.tempoLogs.append(
    TempoLog(id: tempo1ID, pieceID: pieceID, bpm: 90, loggedAt: fixedDate("2026-01-08T09:40:00.000Z")),
    committedAt: committed
)
try store.tempoLogs.append(
    TempoLog(id: tempo2ID, pieceID: pieceID, bpm: 100, loggedAt: fixedDate("2026-02-01T18:30:00.000Z")),
    committedAt: committed
)
try store.practiceNotes.append(
    PracticeNote(
        id: noteID, pieceID: pieceID, text: "Fixture note: left hand rushes at the modulation.",
        writtenAt: fixedDate("2026-01-08T09:46:00.000Z")
    ),
    committedAt: committed
)

// Verify the seed matches expectations before committing it to the fixture.
let usage = try store.storageUsage()
let expected = StorageUsage.TableCounts(
    instruments: 1, pieces: 2, sessions: 1, sessionSplits: 2, tempoLogs: 2, practiceNotes: 1
)
guard usage.rows == expected else {
    fatalError("seed verification failed: \(usage.rows) != \(expected)")
}
guard let piece = try store.pieces.piece(id: pieceID) else {
    fatalError("seed verification failed: piece missing")
}
guard piece.targetBPM == 120, piece.status == .active else {
    fatalError("seed verification failed: piece mismatch")
}
print("Seeded \(outputURL.path): \(usage.rows)")

import Foundation
import GRDB
import Testing
import WoodshedKit
import WoodshedStore

private let fixture = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Fixtures/v1.sqlite")
private let fixed = Date(timeIntervalSince1970: 1_700_000_000)

private func fixtureStore() throws -> (WoodshedStore, URL) {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("woodshed-transfer-\(UUID().uuidString).sqlite")
    try FileManager.default.copyItem(at: fixture, to: url)
    return (try WoodshedStore.open(at: url), url)
}

@Suite("Backup, restore, and CSV", .serialized)
struct TransferTests {
    @Test func fixtureRoundTripAndPreview() throws {
        let (source, url) = try fixtureStore()
        defer { try? FileManager.default.removeItem(at: url) }
        let backup = try source.backupData(generatedAt: fixed)
        let decoded = try BackupCodec.decode(backup)
        #expect(decoded.events.count == 9)
        let destination = try WoodshedStore.inMemory()
        let preview = try destination.previewRestore(backup)
        #expect(preview.before.sessions == 0)
        let sourceCounts = try source.storageUsage().rows
        #expect(preview.after == sourceCounts)
        try destination.replace(with: preview)
        #expect(try destination.backupData(generatedAt: fixed) == backup)
        #expect(try destination.sessionCSV() == source.sessionCSV())
    }

    @Test func supersededSessionAndSplitEventsSurvive() throws {
        let (source, url) = try fixtureStore()
        defer { try? FileManager.default.removeItem(at: url) }
        let old = try #require(source.sessions.currentSessions().first)
        let oldSplit = try #require(source.sessions.currentSplits(sessionID: old.id).first)
        let correctionDate = Date(timeIntervalSince1970: 1_800_000_000)
        let corrected = Session(id: old.id, pieceID: old.pieceID,
                                startedAt: old.startedAt.addingTimeInterval(3600),
                                endedAt: old.endedAt.addingTimeInterval(3600))
        try source.sessions.append(corrected, committedAt: correctionDate)
        try source.sessions.append(split: SessionSplit(id: oldSplit.id, sessionID: old.id,
                                                       label: "corrected", startedAt: corrected.startedAt,
                                                       endedAt: corrected.endedAt),
                                   sessionCommittedAt: correctionDate, committedAt: correctionDate)
        let data = try source.backupData(generatedAt: fixed)
        let restored = try WoodshedStore.inMemory()
        try restored.replace(with: restored.previewRestore(data))
        #expect(try restored.backupData(generatedAt: fixed) == data)
        #expect(try restored.sessions.currentSplits(sessionID: old.id).first?.label == "corrected")
        #expect(try restored.storageUsage().rows.sessions == 2)
        #expect(try restored.storageUsage().rows.sessionSplits == 3)
    }

    @Test func replaceAndRollback() throws {
        let (source, url) = try fixtureStore()
        defer { try? FileManager.default.removeItem(at: url) }
        let original = try source.backupData(generatedAt: fixed)
        let empty = try BackupCodec.encode(Ledger(), generatedAt: fixed)
        let preview = try source.previewRestore(empty)
        #expect(preview.before.sessions == 1)
        #expect(preview.after.sessions == 0)
        try source.replace(with: preview)
        #expect(try source.storageUsage().rows.sessions == 0)
        let restore = try source.previewRestore(original)
        try source.replace(with: restore)
        #expect(try source.backupData(generatedAt: fixed) == original)

        let stale = try source.previewRestore(empty)
        let instrument = Instrument(name: "New")
        try source.instruments.append(instrument, committedAt: fixed)
        #expect(throws: StoreTransferError.changedSincePreview) { try source.replace(with: stale) }
        #expect(try source.instruments.instrument(id: instrument.id) != nil)
        #expect(try source.storageUsage().rows.sessions == 1)

        let sameCounts = try source.previewRestore(empty)
        try source.instruments.append(Instrument(id: instrument.id, name: "Renamed"), committedAt: Date())
        #expect(throws: StoreTransferError.changedSincePreview) { try source.replace(with: sameCounts) }
    }

    @Test func transactionRollsBackOnInsertionFailure() throws {
        let (source, url) = try fixtureStore()
        defer { try? FileManager.default.removeItem(at: url) }
        let before = try source.backupData(generatedAt: fixed)
        let orphan = Piece(instrumentID: UUID(), title: "Orphan")
        let data = try BackupCodec.encode(Ledger(events: [LedgerEvent(committedAt: fixed, payload: .piece(orphan))]), generatedAt: fixed)
        #expect(throws: (any Error).self) { _ = try source.previewRestore(data) }
        #expect(try source.backupData(generatedAt: fixed) == before)

        // A database error after the replacement DELETEs must leave every
        // original row intact, including its child event rows.
        let valid = try source.previewRestore(before)
        try source.db.write { writer in
            try writer.execute(sql: "CREATE TRIGGER fail_restore BEFORE INSERT ON instruments BEGIN SELECT RAISE(ABORT, 'injected failure'); END")
        }
        #expect(throws: (any Error).self) { try source.replace(with: valid) }
        #expect(try source.backupData(generatedAt: fixed) == before)
    }

    @Test func forwardVersionHasClearTypedError() throws {
        let (source, url) = try fixtureStore()
        defer { try? FileManager.default.removeItem(at: url) }
        let data = try source.backupData(generatedAt: fixed)
        var json = try #require(String(data: data, encoding: .utf8))
        json = json.replacingOccurrences(of: "\"schema_version\" : 1", with: "\"schema_version\" : 999")
        #expect(throws: BackupCodec.BackupCodecError.unsupportedSchemaVersion(found: 999, supported: 1...1)) {
            _ = try source.previewRestore(Data(json.utf8))
        }
    }

    @Test func csvMatchesGoldenFixture() throws {
        let (source, url) = try fixtureStore()
        defer { try? FileManager.default.removeItem(at: url) }
        let golden = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Fixtures/sessions.csv")
        #expect(try source.sessionCSV() == Data(contentsOf: golden))
    }
}

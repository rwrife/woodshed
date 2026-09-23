import Foundation
import Testing

@testable import WoodshedKit

// MARK: - Test fixtures / helpers

/// Deterministic calendar builder — derivations never read the system
/// calendar, and neither do these tests.
func cal(_ timeZone: String, firstWeekday: Int = 1) -> Calendar {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: timeZone)!
    calendar.firstWeekday = firstWeekday
    return calendar
}

func inst(_ year: Int, _ month: Int, _ day: Int, _ hour: Int = 12, _ minute: Int = 0, calendar: Calendar) -> Date {
    var components = DateComponents()
    components.year = year
    components.month = month
    components.day = day
    components.hour = hour
    components.minute = minute
    return calendar.date(from: components)!
}

/// Small deterministic PRNG (xorshift64*) so the round-trip fuzz loop is
/// reproducible across platforms and runs.
struct XorShift64: RandomNumberGenerator {
    private var state: UInt64
    init(seed: UInt64) { state = seed == 0 ? 0x9E3779B97F4A7C15 : seed }
    mutating func next() -> UInt64 {
        state ^= state << 13
        state ^= state >> 7
        state ^= state << 17
        return state &* 0x2545F4914F6CDD1D
    }
}

func randUUID(_ rng: inout XorShift64) -> UUID {
    let a = rng.next(), b = rng.next()
    let bytes: uuid_t = (
        UInt8(a & 0xFF), UInt8((a >> 8) & 0xFF), UInt8((a >> 16) & 0xFF), UInt8((a >> 24) & 0xFF),
        UInt8((a >> 32) & 0xFF), UInt8((a >> 40) & 0xFF), UInt8((a >> 48) & 0xFF), UInt8((a >> 56) & 0xFF),
        UInt8(b & 0xFF), UInt8((b >> 8) & 0xFF), UInt8((b >> 16) & 0xFF), UInt8((b >> 24) & 0xFF),
        UInt8((b >> 32) & 0xFF), UInt8((b >> 40) & 0xFF), UInt8((b >> 48) & 0xFF), UInt8((b >> 56) & 0xFF)
    )
    return UUID(uuid: bytes)
}

private func sessionPayload(
    id: UUID = UUID(),
    pieceID: UUID,
    start: Date,
    minutes: Int
) -> LedgerPayload {
    .session(Session(
        id: id, pieceID: pieceID, startedAt: start,
        endedAt: start.addingTimeInterval(TimeInterval(minutes * 60))
    ))
}

// MARK: - Skeleton contract (kept: the app's debug surface depends on it)

@Suite("WoodshedKit markers")
struct MarkerTests {
    @Test("domain namespace and milestone are stable constants")
    func markers() {
        #expect(WoodshedKit.domain == "WoodshedKit")
        #expect(WoodshedKit.milestone == "M1-domain")
    }
}

// MARK: - Ledger: append-only semantics

@Suite("Ledger append-only semantics")
struct LedgerTests {
    @Test("events list is read-only: no removal or rewrite API is reachable")
    func appendOnlySurface() throws {
        var ledger = Ledger()
        let piece = Piece(id: UUID(), instrumentID: UUID(), title: "Etude")
        try ledger.append(LedgerEvent(committedAt: Date(timeIntervalSince1970: 1), payload: .piece(piece)))
        #expect(ledger.events.count == 1)
        // Compile-time proof of the contract: `events` is private(set);
        // these would not compile (kept commented as the assertion):
        //   ledger.events = []
        //   ledger.events.removeAll()
    }

    @Test("event kind and entityID are derived from the payload")
    func derivedKeys() {
        let piece = Piece(id: UUID(), instrumentID: UUID(), title: "X")
        let event = LedgerEvent(committedAt: Date(timeIntervalSince1970: 5), payload: .piece(piece))
        #expect(event.kind == .piece)
        #expect(event.entityID == piece.id)
    }

    @Test("corrections append new events; newest per entity id wins")
    func corrections() throws {
        let id = UUID()
        let instrumentID = UUID()
        var ledger = Ledger()
        let v1 = Piece(id: id, instrumentID: instrumentID, title: "Old Title", status: .active, targetBPM: 80)
        let v2 = Piece(id: id, instrumentID: instrumentID, title: "New Title", status: .maintenance, targetBPM: 90)
        try ledger.append(LedgerEvent(committedAt: Date(timeIntervalSince1970: 100), payload: .piece(v1)))
        try ledger.append(LedgerEvent(committedAt: Date(timeIntervalSince1970: 200), payload: .piece(v2)))

        // History retains BOTH events.
        #expect(ledger.events.count == 2)
        // Current state is the newest.
        let current = ledger.currentPieces()
        #expect(current.count == 1)
        #expect(current[0].title == "New Title")
        #expect(current[0].status == .maintenance)
        #expect(current[0].targetBPM == 90)
    }

    @Test("equal committedAt corrections: later append wins")
    func equalTimestampCorrections() throws {
        let id = UUID()
        let instrumentID = UUID()
        let stamp = Date(timeIntervalSince1970: 500)
        var ledger = Ledger()
        try ledger.append(LedgerEvent(committedAt: stamp, payload: .piece(Piece(id: id, instrumentID: instrumentID, title: "A"))))
        try ledger.append(LedgerEvent(committedAt: stamp, payload: .piece(Piece(id: id, instrumentID: instrumentID, title: "B"))))
        #expect(ledger.currentPieces().first?.title == "B")
    }

    @Test("tempo logs enforce monotonic loggedAt per piece; other pieces unaffected")
    func tempoMonotonic() throws {
        var ledger = Ledger()
        let pieceA = UUID(), pieceB = UUID()
        let base = Date(timeIntervalSince1970: 1_000)

        try ledger.append(LedgerEvent(committedAt: base, payload: .tempoLog(TempoLog(pieceID: pieceA, bpm: 80, loggedAt: base))))
        // Later tempo for A: fine.
        try ledger.append(LedgerEvent(committedAt: base.addingTimeInterval(10), payload: .tempoLog(TempoLog(pieceID: pieceA, bpm: 90, loggedAt: base.addingTimeInterval(10)))))
        // Equal loggedAt is allowed (monotonic, not strictly increasing).
        try ledger.append(LedgerEvent(committedAt: base.addingTimeInterval(10), payload: .tempoLog(TempoLog(pieceID: pieceA, bpm: 92, loggedAt: base.addingTimeInterval(10)))))
        // Earlier loggedAt for A: rejected.
        #expect(throws: LedgerError.tempoLogOutOfOrder(pieceID: pieceA, loggedAt: base.addingTimeInterval(5), previousLoggedAt: base.addingTimeInterval(10))) {
            try ledger.append(LedgerEvent(committedAt: base.addingTimeInterval(30), payload: .tempoLog(TempoLog(pieceID: pieceA, bpm: 70, loggedAt: base.addingTimeInterval(5)))))
        }
        // Different piece may log an earlier time.
        try ledger.append(LedgerEvent(committedAt: base.addingTimeInterval(31), payload: .tempoLog(TempoLog(pieceID: pieceB, bpm: 60, loggedAt: base))))

        #expect(ledger.tempoLogs(for: pieceA).map(\.bpm) == [80, 90, 92])
        #expect(ledger.tempoLogs(for: pieceB).map(\.bpm) == [60])
    }

    @Test("a rejected append leaves the ledger untouched")
    func rejectionIsInert() throws {
        var ledger = Ledger()
        let pieceA = UUID()
        let base = Date(timeIntervalSince1970: 1_000)
        try ledger.append(LedgerEvent(committedAt: base, payload: .tempoLog(TempoLog(pieceID: pieceA, bpm: 80, loggedAt: base))))
        #expect(throws: LedgerError.self) {
            try ledger.append(LedgerEvent(committedAt: base.addingTimeInterval(5), payload: .tempoLog(TempoLog(pieceID: pieceA, bpm: 70, loggedAt: base.addingTimeInterval(-5)))))
        }
        #expect(ledger.events.count == 1)
    }
}

// MARK: - Derivations: table-driven day streak

@Suite("Derivations: day streak")
struct DayStreakTests {
    static let ny = cal("America/New_York")
    static let utc = cal("UTC")

    struct StreakRow {
        let label: String
        let sessionDays: [(Int, Int, Int)]
        let reference: (Int, Int, Int)
        let expected: Int?
    }

    @Test("streak over consecutive days", arguments: [
        StreakRow(label: "three-day streak", sessionDays: [(2026, 3, 4), (2026, 3, 5), (2026, 3, 6)], reference: (2026, 3, 6), expected: 3),
        StreakRow(label: "streak break", sessionDays: [(2026, 3, 4), (2026, 3, 6)], reference: (2026, 3, 6), expected: 1),
        StreakRow(label: "reference not a practice day", sessionDays: [(2026, 3, 4), (2026, 3, 5)], reference: (2026, 3, 6), expected: nil),
        StreakRow(label: "single day", sessionDays: [(2026, 3, 6)], reference: (2026, 3, 6), expected: 1),
    ])
    func streakTable(_ row: StreakRow) throws {
        var ledger = Ledger()
        let pieceID = UUID()
        var commit = Date(timeIntervalSince1970: 1)
        for day in row.sessionDays {
            let start = inst(day.0, day.1, day.2, 9, 0, calendar: Self.ny)
            try ledger.append(LedgerEvent(committedAt: commit, payload: sessionPayload(pieceID: pieceID, start: start, minutes: 30)))
            commit = commit.addingTimeInterval(1)
        }
        let referenceDate = inst(row.reference.0, row.reference.1, row.reference.2, 18, 0, calendar: Self.ny)
        #expect(Derivations.dayStreak(in: ledger, reference: referenceDate, calendar: Self.ny) == row.expected, Comment(rawValue: row.label))
    }

    @Test("empty ledger has no streak (unknown, not zero)")
    func emptyLedger() {
        #expect(Derivations.dayStreak(in: Ledger(), reference: Date(), calendar: Self.utc) == nil)
    }

    @Test("spring-forward day counts as exactly one practice day")
    func springForward() throws {
        // 2026-03-08 is DST spring-forward in New York: local day has 23 hours.
        var ledger = Ledger()
        let pieceID = UUID()
        var commit = Date(timeIntervalSince1970: 1)
        for day in [(2026, 3, 7), (2026, 3, 8)] {
            try ledger.append(LedgerEvent(committedAt: commit, payload: sessionPayload(pieceID: pieceID, start: inst(day.0, day.1, day.2, 1, 30, calendar: Self.ny), minutes: 20)))
            commit = commit.addingTimeInterval(1)
        }
        // Second session on the 23-hour day still one streak day (no double count).
        try ledger.append(LedgerEvent(committedAt: commit, payload: sessionPayload(pieceID: pieceID, start: inst(2026, 3, 8, 15, 0, calendar: Self.ny), minutes: 10)))
        let reference = inst(2026, 3, 8, 23, 30, calendar: Self.ny)
        #expect(Derivations.dayStreak(in: ledger, reference: reference, calendar: Self.ny) == 2)
    }

    @Test("fall-back day counts as exactly one practice day")
    func fallBack() throws {
        // 2026-11-01 is DST fall-back in New York: local day has 25 hours.
        var ledger = Ledger()
        let pieceID = UUID()
        var commit = Date(timeIntervalSince1970: 1)
        for (start, minutes) in [(inst(2026, 10, 31, 23, 30, calendar: Self.ny), 30),
                                 (inst(2026, 11, 1, 1, 15, calendar: Self.ny), 45),
                                 (inst(2026, 11, 1, 1, 45, calendar: Self.ny), 15)] {
            try ledger.append(LedgerEvent(committedAt: commit, payload: sessionPayload(pieceID: pieceID, start: start, minutes: minutes)))
            commit = commit.addingTimeInterval(1)
        }
        let reference = inst(2026, 11, 1, 20, 0, calendar: Self.ny)
        #expect(Derivations.dayStreak(in: ledger, reference: reference, calendar: Self.ny) == 2)
    }

    @Test("streak across month and year boundaries")
    func monthYearBoundaries() throws {
        var ledger = Ledger()
        let pieceID = UUID()
        var commit = Date(timeIntervalSince1970: 1)
        for day in [(2025, 12, 30), (2025, 12, 31), (2026, 1, 1)] {
            try ledger.append(LedgerEvent(committedAt: commit, payload: sessionPayload(pieceID: pieceID, start: inst(day.0, day.1, day.2, 10, 0, calendar: Self.ny), minutes: 25)))
            commit = commit.addingTimeInterval(1)
        }
        let reference = inst(2026, 1, 1, 22, 0, calendar: Self.ny)
        #expect(Derivations.dayStreak(in: ledger, reference: reference, calendar: Self.ny) == 3)
    }

    @Test("session starting late at night counts on its local start day")
    func midnightCrossing() throws {
        // A session starting 2026-03-05 23:50 New York counts as March 5.
        var ledger = Ledger()
        let pieceID = UUID()
        try ledger.append(LedgerEvent(committedAt: Date(timeIntervalSince1970: 5), payload: sessionPayload(pieceID: pieceID, start: inst(2026, 3, 5, 23, 50, calendar: Self.ny), minutes: 40)))
        let afterMidnight = inst(2026, 3, 6, 0, 30, calendar: Self.ny) // March 6 is not a practice day
        #expect(Derivations.dayStreak(in: ledger, reference: afterMidnight, calendar: Self.ny) == nil)
        let refDay = inst(2026, 3, 5, 23, 55, calendar: Self.ny)
        #expect(Derivations.dayStreak(in: ledger, reference: refDay, calendar: Self.ny) == 1)
    }

    @Test("time zone injection changes day bucketing")
    func timezoneInjection() throws {
        // 2026-06-10 23:30 New York == 2026-06-11 03:30 UTC. Same instant,
        // different practice day, purely from the injected calendar.
        let instant = inst(2026, 6, 10, 23, 30, calendar: Self.ny)
        var ledger = Ledger()
        try ledger.append(LedgerEvent(committedAt: Date(timeIntervalSince1970: 1), payload: sessionPayload(pieceID: UUID(), start: instant, minutes: 30)))

        #expect(Derivations.dayStreak(in: ledger, reference: instant, calendar: Self.ny) == 1)
        // In UTC the session belongs to June 11; referencing June 10 (UTC)
        // is not a practice day.
        let refJune10UTC = inst(2026, 6, 10, 12, 0, calendar: Self.utc)
        #expect(Derivations.dayStreak(in: ledger, reference: refJune10UTC, calendar: Self.utc) == nil)
        let refJune11UTC = inst(2026, 6, 11, 12, 0, calendar: Self.utc)
        #expect(Derivations.dayStreak(in: ledger, reference: refJune11UTC, calendar: Self.utc) == 1)
    }
}

// MARK: - Derivations: weekly minutes

@Suite("Derivations: weekly minutes")
struct WeeklyMinutesTests {
    static let ny = cal("America/New_York")

    @Test("empty ledger is unknown")
    func empty() {
        #expect(Derivations.weeklyMinutes(in: Ledger(), reference: Date(), calendar: Self.ny) == nil)
    }

    @Test("no sessions in reference week is unknown, never zero")
    func noSessionsInWeek() throws {
        var ledger = Ledger()
        // Session in the week of Mar 2; reference in week of Mar 9 (Sunday start).
        try ledger.append(LedgerEvent(committedAt: Date(timeIntervalSince1970: 1), payload: sessionPayload(pieceID: UUID(), start: inst(2026, 3, 3, 10, 0, calendar: Self.ny), minutes: 30)))
        #expect(Derivations.weeklyMinutes(in: ledger, reference: inst(2026, 3, 11, 10, 0, calendar: Self.ny), calendar: Self.ny) == nil)
    }

    @Test("sums sessions inside the calendar week; excludes neighbors")
    func weekBucketing() throws {
        var ledger = Ledger()
        let pieceID = UUID()
        var commit = Date(timeIntervalSince1970: 1)
        // Week (Sun..Sat) containing Wed 2026-03-11: Mar 8 through Mar 14.
        for (start, minutes) in [(inst(2026, 3, 7, 23, 30, calendar: Self.ny), 30),   // previous week
                                 (inst(2026, 3, 8, 9, 0, calendar: Self.ny), 45),     // Sunday boundary — in
                                 (inst(2026, 3, 14, 9, 0, calendar: Self.ny), 15),    // Saturday — in
                                 (inst(2026, 3, 15, 9, 0, calendar: Self.ny), 60)] {  // next week — out
            try ledger.append(LedgerEvent(committedAt: commit, payload: sessionPayload(pieceID: pieceID, start: start, minutes: minutes)))
            commit = commit.addingTimeInterval(1)
        }
        #expect(Derivations.weeklyMinutes(in: ledger, reference: inst(2026, 3, 11, 12, 0, calendar: Self.ny), calendar: Self.ny) == 60)
    }

    @Test("sessions spanning a DST boundary keep exact integer totals")
    func dstWeeks() throws {
        var ledger = Ledger()
        let pieceID = UUID()
        var commit = Date(timeIntervalSince1970: 1)
        // Fall-back week Sun 2026-11-01 .. Sat 2026-11-07 (25-hour Sunday).
        for (start, minutes) in [(inst(2026, 11, 1, 0, 30, calendar: Self.ny), 120),
                                 (inst(2026, 11, 3, 18, 0, calendar: Self.ny), 30)] {
            try ledger.append(LedgerEvent(committedAt: commit, payload: sessionPayload(pieceID: pieceID, start: start, minutes: minutes)))
            commit = commit.addingTimeInterval(1)
        }
        #expect(Derivations.weeklyMinutes(in: ledger, reference: inst(2026, 11, 4, 12, 0, calendar: Self.ny), calendar: Self.ny) == 150)
    }

    @Test("week totals are exact sums, not double-counted accumulation")
    func accumulationCanary() throws {
        // Regression canary: weekly minutes for two 45-min sessions must be
        // 90, not 135 or 45. Guards the accumulate step directly.
        var ledger = Ledger()
        let pieceID = UUID()
        let monday = inst(2026, 3, 9, 9, 0, calendar: Self.ny)
        try ledger.append(LedgerEvent(committedAt: Date(timeIntervalSince1970: 1), payload: sessionPayload(pieceID: pieceID, start: monday, minutes: 45)))
        try ledger.append(LedgerEvent(committedAt: Date(timeIntervalSince1970: 2), payload: sessionPayload(pieceID: pieceID, start: monday.addingTimeInterval(86_400), minutes: 45)))
        #expect(Derivations.weeklyMinutes(in: ledger, reference: monday, calendar: Self.ny) == 90)
    }

    @Test("week boundaries respect firstWeekday injection")
    func firstWeekdayInjection() throws {
        let mondayFirst = cal("UTC", firstWeekday: 2)
        var ledger = Ledger()
        let pieceID = UUID()
        // 2026-03-08 is a Sunday. With Monday-first weeks, Sunday belongs
        // to the week Mar 2..Mar 8, NOT the week Mar 9..Mar 15.
        try ledger.append(LedgerEvent(committedAt: Date(timeIntervalSince1970: 1), payload: sessionPayload(pieceID: pieceID, start: inst(2026, 3, 8, 12, 0, calendar: mondayFirst), minutes: 30)))
        let referenceMar11 = inst(2026, 3, 11, 12, 0, calendar: mondayFirst)
        #expect(Derivations.weeklyMinutes(in: ledger, reference: referenceMar11, calendar: mondayFirst) == nil)
        let referenceMar4 = inst(2026, 3, 4, 12, 0, calendar: mondayFirst)
        #expect(Derivations.weeklyMinutes(in: ledger, reference: referenceMar4, calendar: mondayFirst) == 30)
    }
}

// MARK: - Derivations: per-piece metrics

@Suite("Derivations: per-piece metrics")
struct PieceMetricTests {
    static let ny = cal("America/New_York")

    @Test("all piece derivations are unknown on empty input")
    func unknowns() {
        let pieceID = UUID()
        let ledger = Ledger()
        #expect(Derivations.daysSinceLast(in: ledger, pieceID: pieceID, reference: Date(), calendar: Self.ny) == nil)
        #expect(Derivations.pieceMinutes(in: ledger, pieceID: pieceID) == nil)
        #expect(Derivations.bestTempo(in: ledger, pieceID: pieceID) == nil)
        #expect(Derivations.lastTempo(in: ledger, pieceID: pieceID) == nil)
        #expect(Derivations.tempoDeltaVsTarget(in: ledger, pieceID: pieceID) == nil)
    }

    @Test("daysSinceLast: same day → 0, calendar-day difference, DST-safe")
    func daysSinceLast() throws {
        var ledger = Ledger()
        let pieceID = UUID()
        try ledger.append(LedgerEvent(committedAt: Date(timeIntervalSince1970: 1), payload: sessionPayload(pieceID: pieceID, start: inst(2026, 10, 31, 23, 0, calendar: Self.ny), minutes: 30)))
        // Same calendar day, later hour → 0.
        #expect(Derivations.daysSinceLast(in: ledger, pieceID: pieceID, reference: inst(2026, 10, 31, 23, 59, calendar: Self.ny), calendar: Self.ny) == 0)
        // Crossed midnight → 1 even though only 1.5 real hours elapsed.
        #expect(Derivations.daysSinceLast(in: ledger, pieceID: pieceID, reference: inst(2026, 11, 1, 0, 30, calendar: Self.ny), calendar: Self.ny) == 1)
        // Over the fall-back transition (2026-11-01), 10-31 → 11-02 is 2 days.
        #expect(Derivations.daysSinceLast(in: ledger, pieceID: pieceID, reference: inst(2026, 11, 2, 12, 0, calendar: Self.ny), calendar: Self.ny) == 2)
    }

    @Test("pieceMinutes sums exact whole-minute integers")
    func pieceMinutes() throws {
        var ledger = Ledger()
        let mine = UUID(), other = UUID()
        var commit = Date(timeIntervalSince1970: 1)
        for minutes in [30, 45, 15] {
            try ledger.append(LedgerEvent(committedAt: commit, payload: sessionPayload(pieceID: mine, start: commit.addingTimeInterval(1_000), minutes: minutes)))
            commit = commit.addingTimeInterval(1)
        }
        try ledger.append(LedgerEvent(committedAt: commit, payload: sessionPayload(pieceID: other, start: commit, minutes: 999)))
        #expect(Derivations.pieceMinutes(in: ledger, pieceID: mine) == 90)
        #expect(Derivations.pieceMinutes(in: ledger, pieceID: other) == 999)
    }

    @Test("seconds-level durations truncate, never round, into minutes")
    func truncation() {
        let s = Session(pieceID: UUID(), startedAt: Date(timeIntervalSince1970: 0), endedAt: Date(timeIntervalSince1970: 119.9))
        #expect(Derivations.sessionMinutes(s) == 1)
        let neg = Session(pieceID: UUID(), startedAt: Date(timeIntervalSince1970: 100), endedAt: Date(timeIntervalSince1970: 0))
        #expect(Derivations.sessionMinutes(neg) == 0)
    }

    @Test("tempo best/last use integer BPM; delta vs target exact")
    func tempoMetrics() throws {
        var ledger = Ledger()
        let instrumentID = UUID()
        let pieceID = UUID()
        try ledger.append(LedgerEvent(committedAt: Date(timeIntervalSince1970: 1), payload: .piece(Piece(id: pieceID, instrumentID: instrumentID, title: "Scales", targetBPM: 100))))
        let base = Date(timeIntervalSince1970: 1_000)
        for (bpm, offset) in [(80, 0), (120, 10), (95, 20)] {
            try ledger.append(LedgerEvent(committedAt: base.addingTimeInterval(Double(offset)), payload: .tempoLog(TempoLog(pieceID: pieceID, bpm: bpm, loggedAt: base.addingTimeInterval(Double(offset))))))
        }
        #expect(Derivations.bestTempo(in: ledger, pieceID: pieceID) == 120)
        #expect(Derivations.lastTempo(in: ledger, pieceID: pieceID) == 95)
        #expect(Derivations.tempoDeltaVsTarget(in: ledger, pieceID: pieceID) == -5)
    }

    @Test("tempoDeltaVsTarget unknown when piece has no target or no tempo logs")
    func tempoDeltaUnknowns() throws {
        var ledger = Ledger()
        let instrumentID = UUID()
        let noTarget = UUID()
        let noLogs = UUID()
        try ledger.append(LedgerEvent(committedAt: Date(timeIntervalSince1970: 1), payload: .piece(Piece(id: noTarget, instrumentID: instrumentID, title: "No target"))))
        try ledger.append(LedgerEvent(committedAt: Date(timeIntervalSince1970: 2), payload: .tempoLog(TempoLog(pieceID: noTarget, bpm: 90, loggedAt: Date(timeIntervalSince1970: 2)))))
        #expect(Derivations.tempoDeltaVsTarget(in: ledger, pieceID: noTarget) == nil)

        try ledger.append(LedgerEvent(committedAt: Date(timeIntervalSince1970: 3), payload: .piece(Piece(id: noLogs, instrumentID: instrumentID, title: "Untemposed", targetBPM: 120))))
        #expect(Derivations.tempoDeltaVsTarget(in: ledger, pieceID: noLogs) == nil)
    }
}

// MARK: - Backup codec

@Suite("BackupCodec")
struct BackupCodecTests {
    @Test("empty ledger round-trips losslessly")
    func emptyRoundTrip() throws {
        let ledger = Ledger()
        let data = try BackupCodec.encode(ledger, generatedAt: Date(timeIntervalSince1970: 0))
        #expect(try BackupCodec.decode(data) == ledger)
    }

    @Test("envelope carries schema_version and preserves append order")
    func envelopeFormat() throws {
        let pieceID = UUID()
        var ledger = Ledger()
        try ledger.append(LedgerEvent(committedAt: Date(timeIntervalSince1970: 5), payload: .piece(Piece(id: pieceID, instrumentID: UUID(), title: "X"))))
        try ledger.append(LedgerEvent(committedAt: Date(timeIntervalSince1970: 6), payload: sessionPayload(pieceID: pieceID, start: Date(timeIntervalSince1970: 100), minutes: 30)))
        let data = try BackupCodec.encode(ledger, generatedAt: Date(timeIntervalSince1970: 0))
        let json = try #require(String(data: data, encoding: .utf8))
        #expect(json.contains("\"schema_version\" : 1"))
        let decodedJSON = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        let events = try #require(decodedJSON?["events"] as? [[String: Any]])
        #expect(events.count == 2)
        #expect(events[0]["kind"] as? String == "piece")
        #expect(events[1]["kind"] as? String == "session")
        // Pinned wire keys.
        #expect(events[0]["entity_id"] != nil)
        #expect(events[0]["committed_at"] != nil)
    }

    @Test("forward-incompatible version rejected with typed error")
    func futureVersionRejected() throws {
        let pieceID = UUID()
        var ledger = Ledger()
        try ledger.append(LedgerEvent(committedAt: Date(timeIntervalSince1970: 5), payload: .piece(Piece(id: pieceID, instrumentID: UUID(), title: "X"))))
        var json = try #require(String(data: try BackupCodec.encode(ledger, generatedAt: Date(timeIntervalSince1970: 0)), encoding: .utf8))
        json = json.replacingOccurrences(of: "\"schema_version\" : 1", with: "\"schema_version\" : 99")
        #expect(throws: BackupCodec.BackupCodecError.unsupportedSchemaVersion(found: 99, supported: 1...1)) {
            _ = try BackupCodec.decode(Data(json.utf8))
        }
    }

    @Test("malformed JSON rejected with typed error")
    func malformed() {
        #expect(throws: (any Error).self) {
            _ = try BackupCodec.decode(Data("not json {".utf8))
        }
        // Payload with zero payload keys is corrupted.
        let emptyPayload = """
        {"schema_version":1,"generated_at":0,"events":[{"kind":"piece","entity_id":"00000000-0000-0000-0000-000000000001","committed_at":1,"payload":{}}]}
        """
        #expect(throws: (any Error).self) {
            _ = try BackupCodec.decode(Data(emptyPayload.utf8))
        }
    }

    @Test("decode re-validates ledger semantics; corrupt tempo order is rejected")
    func decodeRejectsSemanticsViolation() throws {
        // Craft a backup whose tempo logs go backwards in loggedAt.
        let piece = UUID().uuidString
        let json = """
        {"schema_version":1,"generated_at":0,"events":[\
        {"kind":"tempoLog","entity_id":"\(UUID().uuidString)","committed_at":100,"payload":{"tempoLog":{"id":"\(UUID().uuidString)","pieceID":"\(piece)","bpm":90,"loggedAt":200}}},\
        {"kind":"tempoLog","entity_id":"\(UUID().uuidString)","committed_at":101,"payload":{"tempoLog":{"id":"\(UUID().uuidString)","pieceID":"\(piece)","bpm":80,"loggedAt":100}}}\
        ]}
        """
        #expect(throws: (any Error).self) {
            _ = try BackupCodec.decode(Data(json.utf8))
        }
    }

    @Test("seeded fuzz: encode→decode→encode is stable across random ledgers")
    func roundTripFuzz() throws {
        var rng = XorShift64(seed: 20260923)
        for iteration in 0..<32 {
            let pieceID = randUUID(&rng)
            let instrumentID = randUUID(&rng)
            let statuses: [Piece.Status] = [.active, .maintenance, .retired]
            var ledger = Ledger()
            let eventCount = Int(rng.next() % 40)
            var lastTempoAt = Date(timeIntervalSince1970: 0)
            var commit = Date(timeIntervalSince1970: Double(iteration) + 1)

            try ledger.append(LedgerEvent(
                committedAt: commit,
                payload: .piece(Piece(
                    id: pieceID, instrumentID: instrumentID,
                    title: "Fuzz \(iteration) 🎸", status: statuses[Int(rng.next() % 3)],
                    targetBPM: rng.next() % 4 == 0 ? nil : Int(rng.next() % 300)
                ))
            ))
            for _ in 0..<eventCount {
                commit = commit.addingTimeInterval(Double(rng.next() % 100))
                switch rng.next() % 4 {
                case 0:
                    let start = commit.addingTimeInterval(Double(rng.next() % 86_400))
                    let minutes = Int(rng.next() % 200)
                    try ledger.append(LedgerEvent(committedAt: commit, payload: sessionPayload(pieceID: pieceID, start: start, minutes: minutes)))
                case 1:
                    let splitID = randUUID(&rng)
                    let start = commit
                    try ledger.append(LedgerEvent(
                        committedAt: commit,
                        payload: .sessionSplit(SessionSplit(
                            id: splitID, sessionID: randUUID(&rng), label: "split-\(rng.next() % 7)",
                            startedAt: start, endedAt: start.addingTimeInterval(Double(rng.next() % 3600))
                        ))
                    ))
                case 2:
                    // Monotonic tempo appends only.
                    lastTempoAt = lastTempoAt.addingTimeInterval(Double(rng.next() % 60))
                    try ledger.append(LedgerEvent(
                        committedAt: commit,
                        payload: .tempoLog(TempoLog(id: randUUID(&rng), pieceID: pieceID, bpm: Int(rng.next() % 300), loggedAt: lastTempoAt))
                    ))
                default:
                    let noteID = randUUID(&rng)
                    try ledger.append(LedgerEvent(
                        committedAt: commit,
                        payload: .practiceNote(PracticeNote(id: noteID, pieceID: pieceID, text: "note \"\(rng.next() % 100)\" 🎵", writtenAt: commit))
                    ))
                }
            }

            let encoded = try BackupCodec.encode(ledger, generatedAt: commit)
            let decoded = try BackupCodec.decode(encoded)
            #expect(decoded == ledger, "round-trip mismatch at iteration \(iteration)")
            let reencoded = try BackupCodec.encode(decoded, generatedAt: commit)
            #expect(reencoded == encoded, "re-encode mismatch at iteration \(iteration)")
        }
    }
}

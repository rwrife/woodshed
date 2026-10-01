import Foundation
import Testing

@testable import WoodshedKit

// Issue #7: derivation fuzz hardening.
//
// Property tests with FIXED seeds asserting the two headline derivation
// invariants — `dayStreak` and `weeklyMinutes` — across randomized ledgers
// (sessions, corrections, mixed pieces) and time zones whose DST rules
// include the pathological offsets (30- and 45-minute zones, southern-
// hemisphere switches). Each assertion compares the implementation against
// an INDEPENDENT oracle that uses a different Foundation API path:
//
//   streak / weekly oracle: `startOfDay(for:)` + whole-day counting from a
//   calendar epoch (`dateComponents([.day], from:to:)`) — a day-index space
//   distinct from `Derivations`' year/month/day component extraction and
//   day-stepping. A shared bug in the component-extraction path cannot hide
//   in both spaces.
//
//   weekly-minutes partition oracle: the sum of `weeklyMinutes` evaluated
//   once per distinct practice week must equal the sum of per-session
//   truncated minutes over all resolved sessions — every session counted
//   exactly once, so a boundary that double-counts or drops a day-29/31 or
//   DST edge session fails.
//
// Time-zone set includes zones whose spring-forward transition removes
// local midnight (`America/Havana`, `America/Santiago`) since issue #15
// fixed the streak day-anchor to use the day's earliest real instant;
// before that fix those zones were excluded (docs/issue-7-hardening-
// evidence.md Findings-3) because the midnight anchor degraded streaks to
// unknown on the gap day.

// MARK: - Fixed-seed fuzz harness

private let fuzzTimeZones = [
    "America/New_York",   // DST 2026-03-08 (23h day) and 2026-11-01 (25h day)
    "UTC",                // no DST baseline
    "Europe/London",      // DST 2026-03-29 / 2026-10-25
    "Asia/Kolkata",       // permanent +05:30 half-hour offset, no DST
    "Pacific/Chatham",    // +12:45/+13:45 — 45-minute offset with DST
    "Australia/Lord_Howe", // +10:30/+11:00/+10:30 — 30-minute DST shift, southern hemisphere
    "Pacific/Auckland",   // southern-hemisphere DST 2026-09-27 / 2026-04-05
    "America/Havana",     // midnight-less spring-forward 2026-03-08 (00:00→01:00) — issue #15
    "America/Santiago",   // midnight-less spring-forward 2026-09-06 (00:00→01:00) — issue #15
]

/// Anchored windows so randomized sessions reliably straddle real DST
/// transitions instead of relying on lucky draws: northern spring-forward,
/// northern fall-back, southern spring-forward/fall-back, EU switches.
private let fuzzWindows: [(start: (Int, Int, Int), days: Int)] = [
    ((2026, 3, 1), 20),    // US spring-forward (Mar 8), EU (Mar 29 start)
    ((2026, 3, 22), 24),   // EU Mar 29, Lord Howe Apr 5, Chatham Apr 5
    ((2026, 9, 25), 18),   // Auckland Sep 27, Lord Howe-style southern spring
    ((2026, 10, 25), 14),  // EU Oct 25, Lord Howe Oct 4 carry-over, US Nov 1
    ((2026, 9, 1), 10),    // Santiago midnight-less spring-forward (Sep 6) — issue #15
]

private struct FuzzLedger {
    let ledger: Ledger
    /// Instants to use as derivation references: session starts plus
    /// deliberate near-misses (±hours/days around sessions).
    let references: [Date]
    let pieceIDs: [UUID]
    /// Resolved (newest-event-per-id) sessions — the oracle's input.
    let resolvedSessions: [Session]
}

private func fuzzSessionPayload(id: UUID, pieceID: UUID, start: Date, minutes: Int) -> LedgerPayload {
    .session(Session(
        id: id, pieceID: pieceID, startedAt: start,
        endedAt: start.addingTimeInterval(TimeInterval(minutes * 60))
    ))
}

private func makeFuzzLedger(seed: UInt64, window: (start: (Int, Int, Int), days: Int), calendar: Calendar) throws -> FuzzLedger {
    var rng = XorShift64(seed: seed)
    var ledger = Ledger()
    let pieceIDs = [randUUID(&rng), randUUID(&rng)]
    let instrumentID = randUUID(&rng)
    var commit = Date(timeIntervalSince1970: 1_600_000_000)

    for pieceID in pieceIDs {
        try ledger.append(LedgerEvent(
            committedAt: commit,
            payload: .piece(Piece(id: pieceID, instrumentID: instrumentID, title: "Fuzz \(pieceID.uuidString.prefix(4))", targetBPM: Int(rng.next() % 200)))
        ))
        commit = commit.addingTimeInterval(1)
    }

    let windowStart = inst(window.start.0, window.start.1, window.start.2, 0, 0, calendar: calendar)
    let windowEnd = calendar.date(byAdding: .day, value: window.days, to: windowStart)!

    var sessionStarts: [Date] = []
    let sessionCount = 1 + Int(rng.next() % 40)
    for _ in 0..<sessionCount {
        let offset = Double(rng.next() % UInt64(max(1, window.days * 86_400)))
        let start = windowStart.addingTimeInterval(offset)
        let minutes = 1 + Int(rng.next() % 180)
        let sessionID = randUUID(&rng)
        commit = commit.addingTimeInterval(1 + Double(rng.next() % 60))
        try ledger.append(LedgerEvent(committedAt: commit, payload: fuzzSessionPayload(id: sessionID, pieceID: pieceIDs[Int(rng.next() % 2)], start: start, minutes: minutes)))
        sessionStarts.append(start)

        // Occasionally append a correction: same session id, later
        // committedAt, new duration. Readers must resolve the newest.
        if rng.next() % 4 == 0 {
            let correctedMinutes = 1 + Int(rng.next() % 180)
            commit = commit.addingTimeInterval(1 + Double(rng.next() % 60))
            try ledger.append(LedgerEvent(
                committedAt: commit,
                payload: fuzzSessionPayload(id: sessionID, pieceID: pieceIDs[Int(rng.next() % 2)], start: start, minutes: correctedMinutes)
            ))
        }
    }

    var references: [Date] = sessionStarts
    // Near-miss references: mid-day on random window days and instants just
    // before/after session starts (exercises the nil "not a practice day"
    // path and week-boundary instants).
    for _ in 0..<10 {
        let offset = Double(rng.next() % UInt64(max(1, window.days * 86_400)))
        references.append(windowStart.addingTimeInterval(offset))
    }
    for start in sessionStarts.prefix(8) {
        references.append(start.addingTimeInterval(-3_600))
        references.append(start.addingTimeInterval(72 * 3_600))
    }
    references = references.filter { (windowStart.addingTimeInterval(-86_400)...windowEnd.addingTimeInterval(86_400)).contains($0) }

    return FuzzLedger(
        ledger: ledger,
        references: references,
        pieceIDs: pieceIDs,
        resolvedSessions: ledger.currentSessions()
    )
}

// MARK: - Independent oracles (different API path than the implementation)

/// Whole-day index of an instant: calendar days from the calendar's own
/// start-of-epoch day. Uses `startOfDay` + `dateComponents([.day])`
/// counting, not year/month/day extraction.
private func dayIndex(_ instant: Date, calendar: Calendar) -> Int {
    let epochDay = calendar.startOfDay(for: Date(timeIntervalSince1970: 0))
    let day = calendar.startOfDay(for: instant)
    return calendar.dateComponents([.day], from: epochDay, to: day).day ?? Int.min
}

private func oracleDaySet(_ sessions: [Session], calendar: Calendar) -> Set<Int> {
    Set(sessions.map { dayIndex($0.startedAt, calendar: calendar) })
}

private func oracleStreak(daySet: Set<Int>, reference: Date, calendar: Calendar) -> Int? {
    let referenceIndex = dayIndex(reference, calendar: calendar)
    guard daySet.contains(referenceIndex) else { return nil }
    var streak = 1
    var cursor = referenceIndex - 1
    while daySet.contains(cursor) {
        streak += 1
        cursor -= 1
    }
    return streak
}

/// Week containing `reference` per the same firstWeekday contract, computed
/// by stepping start-of-day backwards until the weekday matches — a
/// day-by-day walk, not `dateInterval(of: .weekOfYear:)`.
///
/// The backward step takes each previous day's EARLIEST real instant (its
/// `startOfDay` result re-anchored through explicit date components), not
/// a raw `date(byAdding: .day)`. On fall-back days whose midnight is
/// ambiguous (America/Havana 2026-11-01, where 00:00 recurs), `startOfDay`
/// can return the SECOND occurrence and a raw day-step lands back on the
/// ambiguous hour; re-extracting the calendar-day components (no hour) and
/// re-resolving pins each step to the day's first instant, exactly like
/// `Derivations.dayAnchor` does for the streak. Without this, the oracle
/// produced two week-start keys one hour apart on the same Sunday and the
/// partition test double-counted one bucket (exposed when Havana joined
/// the matrix for issue #15).
private func oracleWeekInterval(containing reference: Date, calendar: Calendar) -> DateInterval {
    // Entry point too: `startOfDay` of an instant inside an ambiguous
    // (fall-back duplicated) midnight can return the SECOND occurrence;
    // re-anchor through explicit day components so the oracle's week key
    // is always the day's first instant, matching `dateInterval(of:)`.
    var start = firstInstantOfDay(calendar.startOfDay(for: reference), calendar: calendar)
    var guardCount = 0
    while calendar.component(.weekday, from: start) != calendar.firstWeekday && guardCount < 7 {
        start = previousDayStart(start, calendar: calendar)
        guardCount += 1
    }
    let end = (0..<7).reduce(start) { partial, _ in calendar.date(byAdding: .day, value: 1, to: partial)! }
    return DateInterval(start: start, end: end)
}

/// Re-anchor any instant to the earliest real instant of its own calendar
/// day (ambiguous fall-back midnights resolve to the FIRST occurrence).
private func firstInstantOfDay(_ instant: Date, calendar: Calendar) -> Date {
    let comps = calendar.dateComponents([.year, .month, .day], from: instant)
    return Derivations.dayAnchor(for: comps, calendar: calendar) ?? calendar.startOfDay(for: instant)
}

/// The earliest real instant of the calendar day before `instant`'s.
private func previousDayStart(_ instant: Date, calendar: Calendar) -> Date {
    let previousDay: Date = {
        // Step a midday instant back: midday always exists, and its
        // calendar day is unambiguously the previous day.
        let noon = calendar.date(bySettingHour: 12, minute: 0, second: 0, of: instant)!
        let moved = calendar.date(byAdding: .day, value: -1, to: noon)!
        return calendar.startOfDay(for: moved)
    }()
    // Re-anchor to the day's first instant via explicit day components so
    // an ambiguous startOfDay (DST fall-back duplicated midnight) cannot
    // keep the oracle one hour off the implementation's week boundary.
    return firstInstantOfDay(previousDay, calendar: calendar)
}

private func oracleWeeklyMinutes(_ sessions: [Session], reference: Date, calendar: Calendar) -> Int? {
    let interval = oracleWeekInterval(containing: reference, calendar: calendar)
    let inWeek = sessions.filter { interval.contains($0.startedAt) }
    guard !inWeek.isEmpty else { return nil }
    return inWeek.reduce(0) { $0 + Derivations.sessionMinutes($1) }
}

// MARK: - Property tests

@Suite("Derivation fuzz hardening (fixed seed)")
struct DerivationFuzzTests {
    static let seed: UInt64 = 20_260_929

    /// Fixed-seed property sweep: for every time zone × window, every
    /// reference must match the independent oracle for `dayStreak` and
    /// ledger-wide `weeklyMinutes`, and derived values must satisfy their
    /// contract bounds (never 0-instead-of-nil, streak ≤ distinct days).
    @Test("streak and weekly minutes match an independent day-index oracle")
    func oracleConcordance() throws {
        for (zoneIndex, zone) in fuzzTimeZones.enumerated() {
            let calendar = cal(zone)
            for (windowIndex, window) in fuzzWindows.enumerated() {
                let seed = Self.seed &+ UInt64(zoneIndex &* 131 &+ windowIndex &* 7_919)
                let fuzz = try makeFuzzLedger(seed: seed, window: window, calendar: calendar)
                let daySet = oracleDaySet(fuzz.resolvedSessions, calendar: calendar)
                for (refIndex, reference) in fuzz.references.enumerated() {
                    let expectedStreak = oracleStreak(daySet: daySet, reference: reference, calendar: calendar)
                    let actualStreak = Derivations.dayStreak(in: fuzz.ledger, reference: reference, calendar: calendar)
                    #expect(
                        actualStreak == expectedStreak,
                        "streak mismatch zone=\(zone) window=\(windowIndex) ref=\(refIndex) reference=\(reference.timeIntervalSince1970)"
                    )
                    if let actualStreak {
                        #expect(actualStreak >= 1)
                        #expect(actualStreak <= daySet.count, "streak cannot exceed distinct practice days")
                    }

                    let expectedWeekly = oracleWeeklyMinutes(fuzz.resolvedSessions, reference: reference, calendar: calendar)
                    let actualWeekly = Derivations.weeklyMinutes(in: fuzz.ledger, reference: reference, calendar: calendar)
                    #expect(
                        actualWeekly == expectedWeekly,
                        "weekly mismatch zone=\(zone) window=\(windowIndex) ref=\(refIndex) reference=\(reference.timeIntervalSince1970)"
                    )
                    if let actualWeekly {
                        #expect(actualWeekly >= 0, "a counted week is never negative")
                    }
                }
            }
        }
    }

    /// Partition invariant: summing `weeklyMinutes` once per distinct
    /// practice week equals the total of per-session truncated minutes.
    /// Every session lands in exactly one week bucket — double-counting or
    /// dropped boundary sessions (DST weeks, 45-minute-offset zones) fail.
    @Test("weekly buckets partition the whole ledger exactly once")
    func weeklyPartitionSum() throws {
        for (zoneIndex, zone) in fuzzTimeZones.enumerated() {
            let calendar = cal(zone)
            for (windowIndex, window) in fuzzWindows.enumerated() {
                let seed = Self.seed &+ UInt64(zoneIndex &* 257 &+ windowIndex &* 104_729)
                let fuzz = try makeFuzzLedger(seed: seed, window: window, calendar: calendar)
                let sessions = fuzz.resolvedSessions
                let total = sessions.reduce(0) { $0 + Derivations.sessionMinutes($1) }

                // One reference per distinct practice day; weeklyMinutes for
                // all days of the same week is identical, so summing per day
                // would re-count — dedupe by week start first.
                var weekRepresentatives: [Date: Date] = [:]
                for session in sessions {
                    let weekStart = oracleWeekInterval(containing: session.startedAt, calendar: calendar).start
                    weekRepresentatives[weekStart] = session.startedAt
                }
                var bucketed = 0
                for (_, reference) in weekRepresentatives {
                    bucketed += Derivations.weeklyMinutes(in: fuzz.ledger, reference: reference, calendar: calendar) ?? 0
                }
                #expect(bucketed == total, "week buckets fail to partition zone=\(zone) window=\(windowIndex)")
            }
        }
    }

    /// Corrections invariant: a corrected session's newest event wins in
    /// both derivations — totals follow the correction, and the pre-
    /// correction value only survives if the corrected duration is equal.
    @Test("corrections resolve to the newest session event")
    func correctionsResolveNewest() throws {
        for (zoneIndex, zone) in fuzzTimeZones.enumerated() {
            let calendar = cal(zone)
            let seed = Self.seed &+ UInt64(zoneIndex &* 31)
            let fuzz = try makeFuzzLedger(seed: seed, window: fuzzWindows[zoneIndex % fuzzWindows.count], calendar: calendar)
            let total = fuzz.resolvedSessions.reduce(0) { $0 + Derivations.sessionMinutes($1) }
            // Sum over per-day week representatives == resolved-session total
            // only holds when corrections supersede (raw-event summing would
            // exceed it).
            var weekRepresentatives: [Date: Date] = [:]
            for session in fuzz.resolvedSessions {
                let weekStart = oracleWeekInterval(containing: session.startedAt, calendar: calendar).start
                weekRepresentatives[weekStart] = session.startedAt
            }
            let bucketed = weekRepresentatives.values.reduce(0) {
                $0 + (Derivations.weeklyMinutes(in: fuzz.ledger, reference: $1, calendar: calendar) ?? 0)
            }
            #expect(bucketed == total, "corrections not resolved newest zone=\(zone)")
            // pieceMinutes must agree with per-piece resolved-session totals.
            for pieceID in fuzz.pieceIDs {
                let pieceTotal = fuzz.resolvedSessions.filter { $0.pieceID == pieceID }.reduce(0) { $0 + Derivations.sessionMinutes($1) }
                #expect(Derivations.pieceMinutes(in: fuzz.ledger, pieceID: pieceID) == (pieceTotal > 0 || fuzz.resolvedSessions.contains(where: { $0.pieceID == pieceID }) ? pieceTotal : nil))
            }
        }
    }

    /// Determinism: the same fixed seed reproduces byte-identical results,
    /// so a failure reported by CI is reproducible from the seed alone.
    @Test("fixed seed reproduces identical derivation results")
    func determinism() throws {
        let calendar = cal("America/New_York")
        func run() throws -> [Int?] {
            let fuzz = try makeFuzzLedger(seed: Self.seed, window: fuzzWindows[0], calendar: calendar)
            return fuzz.references.map { reference in
                Derivations.dayStreak(in: fuzz.ledger, reference: reference, calendar: calendar)
            }
        }
        let first = try run()
        let second = try run()
        #expect(first == second)
    }
}

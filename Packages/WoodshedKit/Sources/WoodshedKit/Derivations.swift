import Foundation

/// Deterministic derivations over a `Ledger`.
///
/// Contract (issue #2):
/// - Pure functions. Every derivation takes an explicit `Calendar`
///   (which carries the time zone) — the system calendar is never read.
/// - Every derivation returns `nil` ("unknown") when its inputs are
///   absent — never 0, and never a verdict word.
/// - Minute totals use exact integer arithmetic (truncating each
///   session's duration to whole minutes, the unit the ledger defines);
///   no floats accumulate.
public enum Derivations {

    /// Whole calendar days containing at least one session, mapped from
    /// session start instants using `calendar`.
    static func practiceDayComponents(in ledger: Ledger, calendar: Calendar) -> Set<DateComponents> {
        var days: Set<DateComponents> = []
        for session in ledger.currentSessions() {
            days.insert(practiceDay(for: session.startedAt, calendar: calendar))
        }
        return days
    }

    static func practiceDay(for instant: Date, calendar: Calendar) -> DateComponents {
        calendar.dateComponents([.year, .month, .day], from: instant)
    }

    /// Consecutive-calendar-day practice streak ending on `reference`'s
    /// calendar day.
    ///
    /// Returns `nil` (unknown) when the ledger holds no sessions, or
    /// when `reference` does not fall on a practice day (the streak has
    /// not started or has been broken — either way, no streak count is
    /// asserted). Day math is pure `Calendar` component arithmetic, so
    /// spring-forward/fall-back days still count as exactly one day.
    public static func dayStreak(in ledger: Ledger, reference: Date, calendar: Calendar) -> Int? {
        let days = practiceDayComponents(in: ledger, calendar: calendar)
        guard !days.isEmpty else { return nil }

        let referenceDay = practiceDay(for: reference, calendar: calendar)
        guard days.contains(referenceDay) else { return nil }

        // Day arithmetic via date(from:) + date(byAdding:) would normalize
        // a DST day-component set (e.g. missing hour 2) into a shifted
        // instant whose re-extraction yields different components. Anchor
        // the reference day once, then step in whole days, comparing the
        // day each step instant falls on.
        guard let referenceDayInstant = calendar.date(from: referenceDay) else { return nil }
        var streak = 1
        var cursor = referenceDayInstant
        while let previousInstant = calendar.date(byAdding: .day, value: -1, to: cursor) {
            let previousDay = practiceDay(for: previousInstant, calendar: calendar)
            guard days.contains(previousDay) else { break }
            streak += 1
            cursor = previousInstant
        }
        return streak
    }

    /// Minutes practiced in the calendar week (per `calendar`'s week
    /// boundaries) containing `reference`.
    ///
    /// Returns `nil` (unknown) when the ledger holds no sessions or none
    /// of them fall inside the reference week — never 0. Accumulation
    /// truncates each session to whole minutes before summing, keeping
    /// the total an exact Int across DST weeks (a 23- or 25-hour day is
    /// handled by calendar-day bucketing, not by raw second math).
    public static func weeklyMinutes(in ledger: Ledger, reference: Date, calendar: Calendar) -> Int? {
        let sessions = ledger.currentSessions()
        guard !sessions.isEmpty else { return nil }

        guard let interval = calendar.dateInterval(of: .weekOfYear, for: reference) else { return nil }
        var total: Int = 0
        var counted = false
        for session in sessions where interval.contains(session.startedAt) {
            total = checkedAdd(total, sessionMinutes(session))
            counted = true
        }
        return counted ? total : nil
    }

    /// Whole minutes of a session (truncated). The elapsed interval is
    /// converted to whole integer seconds first, so minute totals are
    /// exact Int division — no float accumulation (issue #2 contract).
    public static func sessionMinutes(_ session: Session) -> Int {
        minutes(fromElapsed: session.endedAt.timeIntervalSince(session.startedAt))
    }

    /// Whole minutes of a split (truncated), exact Int arithmetic.
    public static func splitMinutes(_ split: SessionSplit) -> Int {
        minutes(fromElapsed: split.endedAt.timeIntervalSince(split.startedAt))
    }

    /// Elapsed seconds -> truncated whole minutes, via Int seconds so the
    /// arithmetic stays integral after the unavoidable Double measurement.
    static func minutes(fromElapsed elapsed: TimeInterval) -> Int {
        guard elapsed > 0 else { return 0 }
        return Int(elapsed) / 60
    }

    /// Whole calendar days between the piece's most recent session and
    /// `reference`, per `calendar` (calendar-day difference, so a partial
    /// "day" crossing midnight still counts as one day).
    ///
    /// Returns `nil` (unknown) when the piece has no sessions. Returns 0
    /// when the piece was practiced on the reference day.
    public static func daysSinceLast(in ledger: Ledger, pieceID: UUID, reference: Date, calendar: Calendar) -> Int? {
        let sessions = ledger.currentSessions().filter { $0.pieceID == pieceID }
        guard let last = sessions.map(\.startedAt).max() else { return nil }
        let startOfDay: (Date) -> Date? = { date in calendar.startOfDay(for: date) }
        guard let lastDay = startOfDay(last), let referenceDay = startOfDay(reference) else { return nil }
        let components = calendar.dateComponents([.day], from: lastDay, to: referenceDay)
        return components.day
    }

    /// Total whole minutes practiced on a piece across all its sessions.
    ///
    /// Returns `nil` (unknown) when the piece has no sessions — never 0.
    public static func pieceMinutes(in ledger: Ledger, pieceID: UUID) -> Int? {
        let sessions = ledger.currentSessions().filter { $0.pieceID == pieceID }
        guard !sessions.isEmpty else { return nil }
        var total: Int = 0
        for session in sessions {
            total = checkedAdd(total, sessionMinutes(session))
        }
        return total
    }

    /// Highest BPM ever logged for a piece. `nil` (unknown) when no
    /// tempo logs exist.
    public static func bestTempo(in ledger: Ledger, pieceID: UUID) -> Int? {
        ledger.tempoLogs(for: pieceID).map(\.bpm).max()
    }

    /// Most recently logged BPM for a piece (by loggedAt, append order
    /// tiebreak). `nil` (unknown) when no tempo logs exist.
    public static func lastTempo(in ledger: Ledger, pieceID: UUID) -> Int? {
        ledger.tempoLogs(for: pieceID).last?.bpm
    }

    /// Last logged BPM minus the piece's target BPM (both integers —
    /// exact). `nil` (unknown) when either input is missing.
    public static func tempoDeltaVsTarget(in ledger: Ledger, pieceID: UUID) -> Int? {
        guard let piece = ledger.currentPieces().first(where: { $0.id == pieceID }),
              let target = piece.targetBPM,
              let last = lastTempo(in: ledger, pieceID: pieceID)
        else { return nil }
        return checkedSubtract(last, target)
    }

    // MARK: - Exact integer helpers

    /// Checked addition for accumulated minute totals; overflow is a
    /// logic error in practice data and must fail loudly, never wrap.
    static func checkedAdd(_ lhs: Int, _ rhs: Int) -> Int {
        let (sum, overflow) = lhs.addingReportingOverflow(rhs)
        precondition(!overflow, "Minute total overflow: \(lhs) + \(rhs)")
        return sum
    }

    /// Checked subtraction for tempo deltas.
    static func checkedSubtract(_ lhs: Int, _ rhs: Int) -> Int {
        let (diff, overflow) = lhs.subtractingReportingOverflow(rhs)
        precondition(!overflow, "Tempo delta overflow: \(lhs) - \(rhs)")
        return diff
    }
}

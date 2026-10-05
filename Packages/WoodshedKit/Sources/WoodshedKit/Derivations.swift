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
        // The anchor is the day's earliest real instant: midnight where it
        // exists, otherwise the first valid hour on midnight-less
        // spring-forward days (issue #15 — e.g. America/Havana 2026-03-08,
        // America/Santiago 2026-09-06, where local midnight is skipped).
        guard let referenceDayInstant = dayAnchor(for: referenceDay, calendar: calendar) else { return nil }
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

    /// The earliest real instant of a calendar day — midnight when local
    /// midnight exists, otherwise the first instant of the first hour that
    /// exists (issue #15). Zones whose spring-forward transition skips
    /// local midnight (`Calendar.date(from:)` with hour 0 resolves to nil
    /// on such days) previously degraded `dayStreak` to unknown for a full
    /// day per year; nudging the anchor hour forward keeps the day anchor
    /// (and day-stepping) exact without inventing a nonexistent instant.
    ///
    /// Contract (issue #2): returns `nil` only when the whole day is
    /// missing from the calendar (or it does not exist at all) — never a
    /// guessed instant outside the target day. Each candidate is verified
    /// to re-extract to the requested year/month/day, so a permissive
    /// Foundation that resolves skipped midnight into an adjacent day is
    /// rejected rather than trusted.
    static func dayAnchor(for day: DateComponents, calendar: Calendar) -> Date? {
        var shifted = day
        shifted.minute = 0
        shifted.second = 0
        for hour in 0...23 {
            shifted.hour = hour
            guard let candidate = calendar.date(from: shifted) else { continue }
            let extracted = calendar.dateComponents([.year, .month, .day], from: candidate)
            if extracted.year == day.year, extracted.month == day.month, extracted.day == day.day {
                return candidate
            }
        }
        return nil
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

    /// Minutes practiced on a single piece in the calendar week (per
    /// `calendar`'s week boundaries) containing `reference`.
    ///
    /// Returns `nil` (unknown) when the piece has no practice in the
    /// reference week — never 0. Sessions containing piece-specific splits
    /// attribute only those splits to each piece; a splitless session belongs
    /// entirely to its primary piece. A session is bucketed by its start
    /// instant, matching the ledger-wide weekly calculation.
    public static func weeklyMinutes(in ledger: Ledger, pieceID: UUID, reference: Date, calendar: Calendar) -> Int? {
        guard let interval = calendar.dateInterval(of: .weekOfYear, for: reference) else { return nil }
        let pieceTitle = ledger.currentPieces().first(where: { $0.id == pieceID })?.title
        let splits = ledger.currentSplits()
        var total: Int = 0
        var counted = false
        for session in ledger.currentSessions() where interval.contains(session.startedAt) {
            guard let minutes = attributedSessionMinutes(session, pieceID: pieceID, pieceTitle: pieceTitle, splits: splits) else { continue }
            total = checkedAdd(total, minutes)
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

    /// Whole calendar days between the piece's most recent practice and
    /// `reference`, per `calendar` (calendar-day difference, so a partial
    /// "day" crossing midnight still counts as one day).
    ///
    /// Honors split-based attribution: a piece practiced only inside a
    /// switched session's split counts as practiced on that session's day.
    /// Returns `nil` (unknown) when the piece has no practice. Returns 0
    /// when the piece was practiced on the reference day.
    public static func daysSinceLast(in ledger: Ledger, pieceID: UUID, reference: Date, calendar: Calendar) -> Int? {
        let pieceTitle = ledger.currentPieces().first(where: { $0.id == pieceID })?.title
        let splits = ledger.currentSplits()
        var last: Date?
        for session in ledger.currentSessions()
        where attributedSessionMinutes(session, pieceID: pieceID, pieceTitle: pieceTitle, splits: splits) != nil {
            if last == nil || session.startedAt > last! { last = session.startedAt }
        }
        guard let last else { return nil }
        let startOfDay: (Date) -> Date? = { date in calendar.startOfDay(for: date) }
        guard let lastDay = startOfDay(last), let referenceDay = startOfDay(reference) else { return nil }
        let components = calendar.dateComponents([.day], from: lastDay, to: referenceDay)
        return components.day
    }

    /// Total whole minutes practiced on a piece across all its sessions.
    ///
    /// Returns `nil` (unknown) when the piece has no practice — never 0.
    /// Honors split-based attribution for switched sessions.
    public static func pieceMinutes(in ledger: Ledger, pieceID: UUID) -> Int? {
        let pieceTitle = ledger.currentPieces().first(where: { $0.id == pieceID })?.title
        let splits = ledger.currentSplits()
        var total: Int = 0
        var counted = false
        for session in ledger.currentSessions() {
            guard let minutes = attributedSessionMinutes(session, pieceID: pieceID, pieceTitle: pieceTitle, splits: splits) else { continue }
            total = checkedAdd(total, minutes)
            counted = true
        }
        return counted ? total : nil
    }

    /// Attributed whole minutes for `pieceID` within `session`. When splits
    /// are present for the session, splits matching `pieceTitle` are summed
    /// (SessionSplit carries label rather than pieceID). When no splits
    /// exist, the session is attributed to its primary `pieceID`.
    static func attributedSessionMinutes(
        _ session: Session,
        pieceID: UUID,
        pieceTitle: String?,
        splits: [SessionSplit]
    ) -> Int? {
        let matchingSplits = splits.filter { $0.sessionID == session.id }
        if !matchingSplits.isEmpty {
            guard let pieceTitle else { return nil }
            let pieceSplits = matchingSplits.filter { $0.label == pieceTitle }
            guard !pieceSplits.isEmpty else { return nil }
            var total = 0
            for split in pieceSplits {
                total = checkedAdd(total, splitMinutes(split))
            }
            return total
        }
        guard session.pieceID == pieceID else { return nil }
        return sessionMinutes(session)
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

    /// Best logged BPM minus the piece target. `nil` (unknown) when the
    /// target or tempo history is absent. This is the wall's explicit
    /// best-vs-target contract; `tempoDeltaVsTarget` remains latest-vs-target.
    public static func bestTempoDeltaVsTarget(in ledger: Ledger, pieceID: UUID) -> Int? {
        guard let piece = ledger.currentPieces().first(where: { $0.id == pieceID }),
              let target = piece.targetBPM,
              let best = bestTempo(in: ledger, pieceID: pieceID)
        else { return nil }
        return checkedSubtract(best, target)
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

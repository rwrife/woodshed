import Foundation
import Combine
import SwiftUI
import WoodshedKit
import WoodshedStore

/// Model and state machine for the session capture workflow.
///
/// Guarantees (issue #4):
/// - Quick Start reachable in <= 2 taps from launch.
/// - Wall-clock anchored timer: elapsed recomputes from timestamps, not tick counting.
/// - Immutable splits recording: each switch ends previous split at `Date()` and starts new split at `Date()`.
/// - Undo removes the last split switch and restores the previous active piece.
/// - Free (unassigned) time is a first-class piece choice.
/// - Stop flow: auto-split summary, per-split whole minute adjustment, optional achieved BPM stepper, one-line note.
/// - Commit writes the Session, SessionSplits, TempoLog (if entered), and PracticeNote (if entered)
///   through the repository layer.
@MainActor
public final class SessionCaptureViewModel: ObservableObject {
    public static let freePracticeTitle = "Free Practice"
    public static let runningDraftDefaultsKey = "woodshed.capture.runningDraft"
    public static let recentPiecesDefaultsKey = "woodshed.capture.recentPieces"
    public static let favoritePiecesDefaultsKey = "woodshed.capture.favoritePieces"

    public struct SplitDraft: Identifiable, Codable, Equatable, Sendable {
        public let id: UUID
        public var pieceID: UUID
        public var pieceTitle: String
        public var startedAt: Date
        public var endedAt: Date
        public var manualMinuteAdjustment: Int

        public init(
            id: UUID = UUID(),
            pieceID: UUID,
            pieceTitle: String,
            startedAt: Date,
            endedAt: Date,
            manualMinuteAdjustment: Int = 0
        ) {
            self.id = id
            self.pieceID = pieceID
            self.pieceTitle = pieceTitle
            self.startedAt = startedAt
            self.endedAt = endedAt
            self.manualMinuteAdjustment = manualMinuteAdjustment
        }

        public var elapsedSeconds: TimeInterval {
            max(0, endedAt.timeIntervalSince(startedAt))
        }

        public var computedMinutes: Int {
            guard elapsedSeconds > 0 else { return 0 }
            return Int(elapsedSeconds) / 60
        }

        public var finalMinutes: Int {
            max(0, computedMinutes + manualMinuteAdjustment)
        }
    }

    public struct ReviewPiece: Identifiable, Equatable, Sendable {
        public let id: UUID
        public let title: String
        public let targetBPM: Int?

        public init(id: UUID, title: String, targetBPM: Int?) {
            self.id = id
            self.title = title
            self.targetBPM = targetBPM
        }
    }

    public struct CommittedSessionSummary: Equatable, Sendable {
        public let sessionID: UUID
        public let primaryPieceTitle: String
        public let totalMinutes: Int
        public let splitCount: Int
        public let achievedBPM: Int?
        public let note: String?
        public let committedAt: Date

        public init(
            sessionID: UUID,
            primaryPieceTitle: String,
            totalMinutes: Int,
            splitCount: Int,
            achievedBPM: Int?,
            note: String?,
            committedAt: Date
        ) {
            self.sessionID = sessionID
            self.primaryPieceTitle = primaryPieceTitle
            self.totalMinutes = totalMinutes
            self.splitCount = splitCount
            self.achievedBPM = achievedBPM
            self.note = note
            self.committedAt = committedAt
        }
    }

    public enum CaptureState: Equatable {
        case idle
        case running
        case paused
        case confirming
    }

    let store: WoodshedStore

    @Published public private(set) var state: CaptureState = .idle
    @Published public private(set) var sessionID: UUID?
    @Published public private(set) var sessionStartedAt: Date?
    @Published public private(set) var activePiece: Piece?
    @Published public private(set) var currentSplitStartedAt: Date?
    @Published public private(set) var completedSplits: [SplitDraft] = []
    @Published public private(set) var previousSwitches: [(piece: Piece, splitID: UUID)] = []

    // Confirmation screen editable state
    @Published public var reviewSplits: [SplitDraft] = []
    @Published public var achievedBPMByPiece: [UUID: Int] = [:]
    @Published public var practiceNoteText: String = ""
    @Published public private(set) var lastCommittedSummary: CommittedSessionSummary?
    @Published public var statusMessage: String?

    // Library pieces for picker
    @Published public private(set) var availablePieces: [Piece] = []
    @Published public private(set) var favoritePieceIDs: Set<UUID> = []
    @Published public private(set) var recentPieceIDs: [UUID] = []

    // Display wall clock
    @Published public private(set) var now: Date = Date()
    private var timerSubscription: AnyCancellable?
    private var pausedAccumulatedSeconds: TimeInterval = 0
    private var pausedAt: Date?

    private struct RunningDraftSnapshot: Codable, Sendable {
        var sessionID: UUID
        var sessionStartedAt: Date
        var currentSplitStartedAt: Date
        var activePieceID: UUID
        var completedSplits: [SplitDraft]
        var previousSwitches: [SwitchSnapshot]
        var pausedAccumulatedSeconds: TimeInterval
        var pausedAt: Date?
        var stateRaw: String

        struct SwitchSnapshot: Codable, Sendable {
            var pieceID: UUID
            var splitID: UUID
        }
    }

    public init(store: WoodshedStore) {
        self.store = store
        loadLibrary()
        loadPreferences()
        restoreRunningDraft()
    }

    private func persistRunningDraft() {
        guard (state == .running || state == .paused),
              let sID = sessionID,
              let sStart = sessionStartedAt,
              let cStart = currentSplitStartedAt,
              let aPiece = activePiece else {
            UserDefaults.standard.removeObject(forKey: Self.runningDraftDefaultsKey)
            return
        }

        let switches = previousSwitches.map {
            RunningDraftSnapshot.SwitchSnapshot(pieceID: $0.piece.id, splitID: $0.splitID)
        }
        let snapshot = RunningDraftSnapshot(
            sessionID: sID,
            sessionStartedAt: sStart,
            currentSplitStartedAt: cStart,
            activePieceID: aPiece.id,
            completedSplits: completedSplits,
            previousSwitches: switches,
            pausedAccumulatedSeconds: pausedAccumulatedSeconds,
            pausedAt: pausedAt,
            stateRaw: state == .paused ? "paused" : "running"
        )
        if let encoded = try? JSONEncoder().encode(snapshot) {
            UserDefaults.standard.set(encoded, forKey: Self.runningDraftDefaultsKey)
        }
    }

    private func restoreRunningDraft() {
        guard let data = UserDefaults.standard.data(forKey: Self.runningDraftDefaultsKey),
              let snapshot = try? JSONDecoder().decode(RunningDraftSnapshot.self, from: data) else {
            return
        }

        let piece = (try? store.pieces.piece(id: snapshot.activePieceID)) ?? freePracticePiece()
        var recoveredSwitches: [(piece: Piece, splitID: UUID)] = []
        for sw in snapshot.previousSwitches {
            if let swPiece = try? store.pieces.piece(id: sw.pieceID) {
                recoveredSwitches.append((piece: swPiece, splitID: sw.splitID))
            }
        }

        sessionID = snapshot.sessionID
        sessionStartedAt = snapshot.sessionStartedAt
        currentSplitStartedAt = snapshot.currentSplitStartedAt
        activePiece = piece
        completedSplits = snapshot.completedSplits
        previousSwitches = recoveredSwitches
        pausedAccumulatedSeconds = snapshot.pausedAccumulatedSeconds
        pausedAt = snapshot.pausedAt
        achievedBPMByPiece = [:]

        if snapshot.stateRaw == "paused" {
            state = .paused
        } else {
            state = .running
            startClock()
        }
    }

    public func loadLibrary() {
        do {
            availablePieces = try store.pieces.allPieces()
        } catch {
            availablePieces = []
        }
    }

    public func loadPreferences() {
        let defaults = UserDefaults.standard
        if let favs = defaults.array(forKey: Self.favoritePiecesDefaultsKey) as? [String] {
            favoritePieceIDs = Set(favs.compactMap(UUID.init(uuidString:)))
        }
        if let recents = defaults.array(forKey: Self.recentPiecesDefaultsKey) as? [String] {
            recentPieceIDs = recents.compactMap(UUID.init(uuidString:))
        }
    }

    public func toggleFavorite(pieceID: UUID) {
        if favoritePieceIDs.contains(pieceID) {
            favoritePieceIDs.remove(pieceID)
        } else {
            favoritePieceIDs.insert(pieceID)
        }
        let raw = favoritePieceIDs.map(\.uuidString)
        UserDefaults.standard.set(raw, forKey: Self.favoritePiecesDefaultsKey)
    }

    private func recordRecent(pieceID: UUID) {
        recentPieceIDs.removeAll(where: { $0 == pieceID })
        recentPieceIDs.insert(pieceID, at: 0)
        if recentPieceIDs.count > 10 {
            recentPieceIDs = Array(recentPieceIDs.prefix(10))
        }
        let raw = recentPieceIDs.map(\.uuidString)
        UserDefaults.standard.set(raw, forKey: Self.recentPiecesDefaultsKey)
    }

    // MARK: - Wall-clock timer

    private func startClock() {
        stopClock()
        now = Date()
        timerSubscription = Timer.publish(every: 1.0, on: .main, in: .common)
            .autoconnect()
            .sink { [weak self] current in
                guard let self else { return }
                self.now = current
            }
    }

    private func stopClock() {
        timerSubscription?.cancel()
        timerSubscription = nil
    }

    public func handleScenePhaseChange(_ phase: ScenePhase) {
        if phase == .active {
            now = Date()
        } else if phase == .background || phase == .inactive {
            persistRunningDraft()
        }
    }

    public var totalElapsedSeconds: TimeInterval {
        guard let start = sessionStartedAt else { return 0 }
        switch state {
        case .idle:
            return 0
        case .running:
            let wall = now.timeIntervalSince(start) - pausedAccumulatedSeconds
            return max(0, wall)
        case .paused:
            if let pausedAt {
                let wall = pausedAt.timeIntervalSince(start) - pausedAccumulatedSeconds
                return max(0, wall)
            }
            return 0
        case .confirming:
            let completed = completedSplits.reduce(0.0) { $0 + $1.elapsedSeconds }
            return completed
        }
    }

    public var activeSplitElapsedSeconds: TimeInterval {
        guard let splitStart = currentSplitStartedAt, state == .running else { return 0 }
        return max(0, now.timeIntervalSince(splitStart))
    }

    // MARK: - Session lifecycle

    /// Starts a session with the requested piece (or Free Practice if nil / not found).
    public func startSession(piece: Piece? = nil, instant: Date = Date()) {
        loadLibrary()
        let resolvedPiece = piece ?? freePracticePiece()
        let newSessionID = UUID()

        sessionID = newSessionID
        sessionStartedAt = instant
        currentSplitStartedAt = instant
        activePiece = resolvedPiece
        completedSplits = []
        previousSwitches = []
        pausedAccumulatedSeconds = 0
        pausedAt = nil
        achievedBPMByPiece = [:]
        practiceNoteText = ""
        statusMessage = nil
        state = .running

        if resolvedPiece.id != WoodshedStoreContainer.freePieceID {
            recordRecent(pieceID: resolvedPiece.id)
        }

        startClock()
        persistRunningDraft()
    }

    public func pauseSession(instant: Date = Date()) {
        guard state == .running else { return }
        pausedAt = instant
        state = .paused
        stopClock()
        persistRunningDraft()
    }

    public func resumeSession(instant: Date = Date()) {
        guard state == .paused, let pausedAt else { return }
        let pauseDuration = max(0, instant.timeIntervalSince(pausedAt))
        pausedAccumulatedSeconds += pauseDuration
        self.pausedAt = nil
        currentSplitStartedAt = currentSplitStartedAt?.addingTimeInterval(pauseDuration)
        state = .running
        startClock()
        persistRunningDraft()
    }
    /// Switches the running session to a new piece (or Free Practice), recording an immutable split.
    public func switchPiece(to newPiece: Piece, instant: Date = Date()) {
        guard state == .running || state == .paused else { return }
        guard let current = activePiece, let splitStart = currentSplitStartedAt else { return }

        // If paused, resume time anchor
        if state == .paused {
            resumeSession(instant: instant)
        }

        let splitEnd = instant
        let splitID = UUID()
        let draft = SplitDraft(
            id: splitID,
            pieceID: current.id,
            pieceTitle: current.title,
            startedAt: splitStart,
            endedAt: splitEnd
        )
        completedSplits.append(draft)
        previousSwitches.append((piece: current, splitID: splitID))

        activePiece = newPiece
        currentSplitStartedAt = instant

        if newPiece.id != WoodshedStoreContainer.freePieceID {
            recordRecent(pieceID: newPiece.id)
        }
        persistRunningDraft()
    }

    /// Undo removes the last switch action only.
    public func undoLastSwitch(instant: Date = Date()) {
        guard let last = previousSwitches.popLast() else { return }
        // Remove the split that was recorded when switching away from last.piece
        if let index = completedSplits.firstIndex(where: { $0.id == last.splitID }) {
            let removedSplit = completedSplits.remove(at: index)
            // Restore previous piece and re-anchor split start back to removed split's start
            activePiece = last.piece
            currentSplitStartedAt = removedSplit.startedAt
        }
        persistRunningDraft()
    }

    /// Stop flow: transitions to confirmation screen with auto-split summary.
    public func stopAndReview(instant: Date = Date()) {
        guard state == .running || state == .paused else { return }
        stopClock()

        let finalInstant = (state == .paused ? pausedAt : instant) ?? instant

        // Close final split
        if let current = activePiece, let splitStart = currentSplitStartedAt {
            let draft = SplitDraft(
                id: UUID(),
                pieceID: current.id,
                pieceTitle: current.title,
                startedAt: splitStart,
                endedAt: finalInstant
            )
            completedSplits.append(draft)
        }

        reviewSplits = completedSplits
        state = .confirming
        UserDefaults.standard.removeObject(forKey: Self.runningDraftDefaultsKey)
    }

    public var reviewTempoPieces: [ReviewPiece] {
        var seen = Set<UUID>()
        var result: [ReviewPiece] = []
        for split in reviewSplits where split.pieceID != WoodshedStoreContainer.freePieceID {
            if seen.insert(split.pieceID).inserted {
                let piece = (try? store.pieces.piece(id: split.pieceID))
                result.append(ReviewPiece(
                    id: split.pieceID,
                    title: split.pieceTitle,
                    targetBPM: piece?.targetBPM
                ))
            }
        }
        return result
    }

    public func adjustSplitMinutes(splitID: UUID, delta: Int) {
        guard let index = reviewSplits.firstIndex(where: { $0.id == splitID }) else { return }
        let current = reviewSplits[index]
        let newAdjustment = current.manualMinuteAdjustment + delta
        if current.computedMinutes + newAdjustment >= 0 {
            reviewSplits[index].manualMinuteAdjustment = newAdjustment
        }
    }

    public func cancelConfirmation() {
        state = .idle
        sessionID = nil
        sessionStartedAt = nil
        currentSplitStartedAt = nil
        activePiece = nil
        completedSplits = []
        reviewSplits = []
        previousSwitches = []
        UserDefaults.standard.removeObject(forKey: Self.runningDraftDefaultsKey)
    }

    /// Commit writes the session, splits, optional tempo log and practice note through the store repositories.
    @discardableResult
    public func commitSession(instant: Date = Date()) throws -> CommittedSessionSummary {
        guard let sID = sessionID, let started = sessionStartedAt else {
            throw WoodshedStoreError.parentNotFound(table: "sessions", id: UUID())
        }

        let commitDate = instant

        // Primary piece is the first non-free piece or the free piece
        let primaryPiece = reviewSplits.first(where: { $0.pieceID != WoodshedStoreContainer.freePieceID })
            ?? reviewSplits.first
            ?? SplitDraft(pieceID: freePracticePiece().id, pieceTitle: Self.freePracticeTitle, startedAt: started, endedAt: instant)

        let adjustedSplitEnds: [UUID: Date] = Dictionary(uniqueKeysWithValues: reviewSplits.map {
            ($0.id, $0.startedAt.addingTimeInterval(TimeInterval($0.finalMinutes * 60)))
        })
        let sessionEndedAt = adjustedSplitEnds.values.max() ?? instant

        let session = Session(
            id: sID,
            pieceID: primaryPiece.pieceID,
            startedAt: started,
            endedAt: sessionEndedAt
        )

        try store.sessions.append(session, committedAt: commitDate)

        // Write each split
        for draft in reviewSplits {
            let adjustedEnd = adjustedSplitEnds[draft.id] ?? draft.endedAt

            let split = SessionSplit(
                id: draft.id,
                sessionID: sID,
                label: draft.pieceTitle,
                startedAt: draft.startedAt,
                endedAt: adjustedEnd
            )
            try store.sessions.append(
                split: split,
                sessionCommittedAt: commitDate,
                committedAt: commitDate
            )
        }

        // Optional achieved tempo (per piece)
        for piece in reviewTempoPieces {
            if let bpm = achievedBPMByPiece[piece.id], bpm > 0 {
                let tempo = TempoLog(
                    pieceID: piece.id,
                    bpm: bpm,
                    loggedAt: sessionEndedAt
                )
                try store.tempoLogs.append(tempo, committedAt: commitDate)
            }
        }

        // Optional practice note
        let trimmedNote = practiceNoteText.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedNote.isEmpty, primaryPiece.pieceID != WoodshedStoreContainer.freePieceID {
            let note = PracticeNote(
                pieceID: primaryPiece.pieceID,
                text: trimmedNote,
                writtenAt: sessionEndedAt
            )
            try store.practiceNotes.append(note, committedAt: commitDate)
        }

        let totalMins = reviewSplits.reduce(0) { $0 + $1.finalMinutes }
        let primaryBPM = achievedBPMByPiece[primaryPiece.pieceID]
        let summary = CommittedSessionSummary(
            sessionID: sID,
            primaryPieceTitle: primaryPiece.pieceTitle,
            totalMinutes: totalMins,
            splitCount: reviewSplits.count,
            achievedBPM: primaryBPM,
            note: trimmedNote.isEmpty ? nil : trimmedNote,
            committedAt: commitDate
        )

        lastCommittedSummary = summary
        statusMessage = "Session saved: \(summary.primaryPieceTitle) (\(summary.totalMinutes)m)"

        // Reset state
        state = .idle
        sessionID = nil
        sessionStartedAt = nil
        currentSplitStartedAt = nil
        activePiece = nil
        completedSplits = []
        reviewSplits = []
        previousSwitches = []
        achievedBPMByPiece = [:]
        practiceNoteText = ""
        UserDefaults.standard.removeObject(forKey: Self.runningDraftDefaultsKey)

        return summary
    }

    public var canUndoLastSwitch: Bool {
        !previousSwitches.isEmpty
    }

    public func addPiece(title: String) {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let newPiece = Piece(
            id: UUID(),
            instrumentID: WoodshedStoreContainer.primaryInstrumentID,
            title: trimmed,
            status: .active,
            targetBPM: nil
        )
        do {
            try store.pieces.append(newPiece, committedAt: Date())
            loadLibrary()
        } catch {
            statusMessage = "Could not add piece: \(error.localizedDescription)"
        }
    }

    public func freePracticePiece() -> Piece {
        if let existing = availablePieces.first(where: { $0.id == WoodshedStoreContainer.freePieceID }) {
            return existing
        }
        return Piece(
            id: WoodshedStoreContainer.freePieceID,
            instrumentID: WoodshedStoreContainer.freeInstrumentID,
            title: Self.freePracticeTitle,
            status: .active,
            targetBPM: nil
        )
    }

    public var sortedPickerPieces: (favorites: [Piece], recents: [Piece], others: [Piece]) {
        let nonFree = availablePieces.filter { $0.id != WoodshedStoreContainer.freePieceID }
        let favs = nonFree.filter { favoritePieceIDs.contains($0.id) }

        var recentsList: [Piece] = []
        for rid in recentPieceIDs where !favoritePieceIDs.contains(rid) {
            if let found = nonFree.first(where: { $0.id == rid }) {
                recentsList.append(found)
            }
        }

        let others = nonFree.filter { !favoritePieceIDs.contains($0.id) && !recentPieceIDs.contains($0.id) }
        return (favs, recentsList, others)
    }
}

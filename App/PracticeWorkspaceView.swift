import Foundation
import SwiftUI
import UIKit
import WoodshedKit
import WoodshedStore

/// The sole layout seam for Woodshed's practice workspace.
///
/// Today it branches only on standard SwiftUI horizontal size class:
/// compact renders a folded/single-column navigation stack; regular renders
/// an unfolded wall-plus-session-workbench span. A future iPhone Duo port
/// must add fold-region awareness here—and nowhere else—while preserving the
/// selected piece, the running-session identity, and wall/detail scroll
/// positions across folded/unfolded transitions. No fold API is referenced.
struct PracticeWorkspaceLayout<Wall: View, Detail: View>: View {
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass

    let selectedPieceID: UUID?
    private let wall: Wall
    private let detail: Detail

    init(
        selectedPieceID: UUID?,
        @ViewBuilder wall: () -> Wall,
        @ViewBuilder detail: () -> Detail
    ) {
        self.selectedPieceID = selectedPieceID
        self.wall = wall()
        self.detail = detail()
    }

    var body: some View {
        if horizontalSizeClass == .regular {
            NavigationSplitView {
                wall
            } detail: {
                detail
            }
        } else {
            NavigationStack {
                wall
            }
        }
    }
}

@MainActor
final class PracticeWorkspaceViewModel: ObservableObject {
    struct Card: Identifiable, Equatable {
        let id: UUID
        let piece: Piece
        let daysSinceLast: Int?
        let weeklyMinutes: Int?
        let bestTempo: Int?
        let bestTempoDelta: Int?
    }

    struct SessionHistory: Identifiable, Equatable {
        let session: Session
        /// Minutes attributed to THIS piece within the session: its splits
        /// when present, otherwise the whole session (it was the primary piece).
        let minutes: Int
        let splits: [SplitHistory]
        var id: UUID { session.id }
    }

    struct SplitHistory: Identifiable, Equatable {
        let split: SessionSplit
        let minutes: Int
        var id: UUID { split.id }
    }

    let store: WoodshedStore
    @Published private(set) var instruments: [Instrument] = []
    @Published var selectedInstrumentID: UUID?
    @Published var selectedPieceID: UUID?
    @Published private(set) var cards: [Card] = []
    @Published private(set) var statusMessage: String?

    private var ledger = Ledger()
    private var pieces: [Piece] = []
    private let calendar: Calendar
    private let referenceDate: () -> Date

    init(
        store: WoodshedStore,
        calendar: Calendar = .autoupdatingCurrent,
        referenceDate: @escaping () -> Date = Date.init
    ) {
        self.store = store
        self.calendar = calendar
        self.referenceDate = referenceDate
        reload()
    }

    var selectedPiece: Piece? {
        guard let selectedPieceID else { return nil }
        return pieces.first(where: { $0.id == selectedPieceID })
    }

    func reload() {
        do {
            instruments = try store.instruments.allInstruments()
                .filter { $0.id != WoodshedStoreContainer.freeInstrumentID }
            pieces = try store.pieces.allPieces()
                .filter { $0.id != WoodshedStoreContainer.freePieceID }
            ledger = try makeLedger()

            if selectedInstrumentID == nil || !instruments.contains(where: { $0.id == selectedInstrumentID }) {
                selectedInstrumentID = instruments.first?.id
            }
            rebuildCards()
            statusMessage = nil
        } catch {
            instruments = []
            pieces = []
            cards = []
            statusMessage = "Practice wall unavailable: \(error.localizedDescription)"
        }
    }

    func selectInstrument(_ instrumentID: UUID) {
        selectedInstrumentID = instrumentID
        selectedPieceID = nil
        rebuildCards()
    }

    func selectPiece(_ pieceID: UUID) {
        selectedPieceID = pieceID
    }

    func updateStatus(_ status: Piece.Status) {
        guard let piece = selectedPiece else { return }
        let corrected = Piece(
            id: piece.id,
            instrumentID: piece.instrumentID,
            title: piece.title,
            status: status,
            targetBPM: piece.targetBPM
        )
        do {
            try store.pieces.append(corrected, committedAt: Date())
            reload()
            if status == .retired {
                selectedPieceID = corrected.id
            }
        } catch {
            statusMessage = "Could not update status: \(error.localizedDescription)"
        }
    }

    func card(for pieceID: UUID) -> Card? {
        cards.first(where: { $0.id == pieceID })
    }

    func sessionHistory(for piece: Piece) -> [SessionHistory] {
        let allSessions = ledger.currentSessions()
        let matching = allSessions.filter { session in
            if session.pieceID == piece.id { return true }
            return ledger.currentSplits().contains {
                $0.sessionID == session.id && $0.label == piece.title
            }
        }
        return matching
            .sorted { lhs, rhs in
                if lhs.startedAt != rhs.startedAt { return lhs.startedAt > rhs.startedAt }
                return lhs.id.uuidString < rhs.id.uuidString
            }
            .map { session in
                let splitRows = ledger.currentSplits()
                    .filter { $0.sessionID == session.id && $0.label == piece.title }
                    .sorted { $0.startedAt > $1.startedAt }
                    .map { SplitHistory(split: $0, minutes: Derivations.splitMinutes($0)) }
                let pieceMinutes = splitRows.isEmpty
                    ? Derivations.sessionMinutes(session)
                    : splitRows.reduce(0) { $0 + $1.minutes }
                return SessionHistory(
                    session: session,
                    minutes: pieceMinutes,
                    splits: splitRows
                )
            }
    }

    func tempoHistory(for pieceID: UUID) -> [TempoLog] {
        Array(ledger.tempoLogs(for: pieceID).reversed())
    }

    private func rebuildCards() {
        guard let selectedInstrumentID else {
            cards = []
            return
        }
        let now = referenceDate()
        cards = pieces
            .filter { $0.instrumentID == selectedInstrumentID && $0.status != .retired }
            .map { piece in
                Card(
                    id: piece.id,
                    piece: piece,
                    daysSinceLast: Derivations.daysSinceLast(
                        in: ledger,
                        pieceID: piece.id,
                        reference: now,
                        calendar: calendar
                    ),
                    weeklyMinutes: Derivations.weeklyMinutes(
                        in: ledger,
                        pieceID: piece.id,
                        reference: now,
                        calendar: calendar
                    ),
                    bestTempo: Derivations.bestTempo(in: ledger, pieceID: piece.id),
                    bestTempoDelta: Derivations.bestTempoDeltaVsTarget(in: ledger, pieceID: piece.id)
                )
            }
            .sorted(by: Self.coldSort)
    }

    /// Explicit deterministic cold sort: never-practiced first, then the
    /// largest days-since-last, then case-insensitive title, then UUID.
    nonisolated static func coldSort(_ lhs: Card, _ rhs: Card) -> Bool {
        switch (lhs.daysSinceLast, rhs.daysSinceLast) {
        case (nil, .some): return true
        case (.some, nil): return false
        case let (.some(left), .some(right)) where left != right: return left > right
        default:
            let titleOrder = lhs.piece.title.localizedCaseInsensitiveCompare(rhs.piece.title)
            if titleOrder != .orderedSame { return titleOrder == .orderedAscending }
            return lhs.id.uuidString < rhs.id.uuidString
        }
    }

    private func makeLedger() throws -> Ledger {
        var result = Ledger()
        var commit = Date(timeIntervalSinceReferenceDate: 1)
        func append(_ payload: LedgerPayload) throws {
            try result.append(LedgerEvent(committedAt: commit, payload: payload))
            commit = commit.addingTimeInterval(1)
        }

        for instrument in try store.instruments.allInstruments() {
            try append(.instrument(instrument))
        }
        for piece in try store.pieces.allPieces() {
            try append(.piece(piece))
        }
        let sessions = try store.sessions.currentSessions()
        for session in sessions {
            try append(.session(session))
            for split in try store.sessions.currentSplits(sessionID: session.id) {
                try append(.sessionSplit(split))
            }
        }
        for piece in try store.pieces.allPieces() {
            for tempo in try store.tempoLogs.tempoLogs(for: piece.id) {
                try append(.tempoLog(tempo))
            }
            for note in try store.practiceNotes.notes(for: piece.id) {
                try append(.practiceNote(note))
            }
        }
        return result
    }
}

struct PracticeWorkspaceView: View {
    @ObservedObject var captureModel: SessionCaptureViewModel
    @StateObject private var wallModel: PracticeWorkspaceViewModel

    init(captureModel: SessionCaptureViewModel) {
        self.captureModel = captureModel
        _wallModel = StateObject(wrappedValue: PracticeWorkspaceViewModel(store: captureModel.store))
    }

    var body: some View {
        PracticeWorkspaceLayout(selectedPieceID: wallModel.selectedPieceID) {
            PracticeWallView(captureModel: captureModel, wallModel: wallModel)
        } detail: {
            if let piece = wallModel.selectedPiece {
                PieceDetailView(piece: piece, model: wallModel)
            } else {
                ContentUnavailableView(
                    "Select a Piece",
                    systemImage: "music.note",
                    description: Text("Choose a practice-wall card to inspect its history.")
                )
            }
        }
        .onAppear { wallModel.reload() }
    }
}

@MainActor
struct PracticeWallView: View {
    @ObservedObject var captureModel: SessionCaptureViewModel
    @ObservedObject var wallModel: PracticeWorkspaceViewModel
    @State private var showingAddPiece = false
    @State private var showingSettings = false
    /// Drives the deterministic ledger reveal (issue #18): set to the
    /// ledger anchor id once the wall (re)appears with a committed
    /// session, so the just-written row is deterministically on screen
    /// instead of racing app-level swipe bursts on hosted runners.
    @State private var revealedSectionID: String?
    /// Last anchor revealed in this process (issue #18 review: the wall
    /// is REBUILT after commit and after Discard — instance @State would
    /// not survive, letting a stale commit re-jump the wall on unrelated
    /// rebuilds). The app is single-window iPhone-only, so one process-
    /// wide MainActor tracker is sufficient: the reveal fires exactly
    /// once per commit, ever.
    private static var lastRevealedAnchor: String?

    init(captureModel: SessionCaptureViewModel, wallModel: PracticeWorkspaceViewModel) {
        self.captureModel = captureModel
        self.wallModel = wallModel
        // The wall view is rebuilt when a session ends (BootstrapHomeView
        // swaps roots on state changes): seed the reveal BEFORE first
        // layout — but only for a commit that has not been revealed yet,
        // so a later Discard/return rebuild never re-jumps to an old row.
        // init deliberately does NOT mutate the tracker: a constructed-but
        // -never-displayed value must not consume the reveal; onAppear
        // (which only runs for a displayed wall) marks it.
        if let anchor = Self.pendingReveal(for: captureModel.lastCommittedSummary) {
            _revealedSectionID = State(initialValue: anchor)
        }
    }

    /// The anchor to reveal for `summary`, or nil when that commit was
    /// already revealed (nil for no commit at all).
    private static func pendingReveal(for summary: SessionCaptureViewModel.CommittedSessionSummary?) -> String? {
        guard let summary else { return nil }
        let anchor = LedgerSummaryView.anchorID(for: summary)
        return anchor == lastRevealedAnchor ? nil : anchor
    }

    /// Reveals the ledger only when a *newly* committed session has not
    /// been shown yet: the anchor is unique per commit, so the reveal
    /// happens exactly once per commit — never on ordinary wall revisits.
    /// (Run 37117908376 evidence: the seeded first-layout reveal worked —
    /// test 1's ledger row appeared with no gesture fallback — so no
    /// deferred re-write is attempted; a `DispatchQueue.main.async`
    /// capture would also risk Swift 6 Sendable violations on `Binding`.)
    private func revealLedgerIfNew(_ summary: SessionCaptureViewModel.CommittedSessionSummary?) {
        guard let anchor = Self.pendingReveal(for: summary) else { return }
        Self.lastRevealedAnchor = anchor
        revealedSectionID = anchor
    }

    var body: some View {
        ScrollView {
            // Keep the summary/status surfaces instantiated offscreen so the
            // existing end-to-end ledger assertions remain accessible after a
            // session save. Piece counts are intentionally small enough that a
            // non-lazy stack is the correct accessibility tradeoff here.
            VStack(spacing: 16) {
                // Dynamic Type proof surface (issue #7): renders the resolved
                // UIKit content-size category so UI tests can prove the AX
                // launch override actually applied before asserting layout.
                // Gated behind a test-only launch flag; production launches
                // never see it. Kept visible — an accessibilityHidden probe
                // would be invisible to XCUITest itself.
                if ProcessInfo.processInfo.arguments.contains("-ui-testing-dynamic-type-probe") {
                    Text(UIApplication.shared.preferredContentSizeCategory.rawValue)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .accessibilityIdentifier("wall.sizeCategory")
                }

                Button {
                    captureModel.startSession(piece: captureModel.freePracticePiece())
                } label: {
                    Label("Quick Start: Free Practice", systemImage: "play.circle.fill")
                        .font(.headline)
                        .frame(maxWidth: .infinity, minHeight: 56)
                }
                .buttonStyle(.borderedProminent)
                .accessibilityIdentifier("capture.quickStart.free")

                if !wallModel.instruments.isEmpty {
                    Picker("Instrument", selection: Binding(
                        get: { wallModel.selectedInstrumentID ?? wallModel.instruments[0].id },
                        set: { wallModel.selectInstrument($0) }
                    )) {
                        ForEach(wallModel.instruments, id: \.id) { instrument in
                            Text(instrument.name).tag(instrument.id)
                        }
                    }
                    .pickerStyle(.segmented)
                    .accessibilityIdentifier("wall.instrumentPicker")
                }

                if wallModel.cards.isEmpty {
                    ContentUnavailableView(
                        "No Active Pieces",
                        systemImage: "music.note.list",
                        description: Text("Add a piece or change an existing piece from Retired.")
                    )
                    .accessibilityIdentifier("wall.empty")
                } else {
                    ForEach(wallModel.cards) { card in
                        VStack(spacing: 10) {
                            NavigationLink {
                                PieceDetailView(piece: card.piece, model: wallModel)
                            } label: {
                                PracticeWallCard(card: card)
                            }
                            .buttonStyle(.plain)
                            .simultaneousGesture(TapGesture().onEnded { wallModel.selectPiece(card.id) })
                            .accessibilityIdentifier("wall.card.\(Identifiers.slug(card.piece))")

                            Button {
                                captureModel.startSession(piece: card.piece)
                            } label: {
                                Label("Start \(card.piece.title)", systemImage: "play.fill")
                                    .frame(maxWidth: .infinity, minHeight: 44)
                            }
                            .buttonStyle(.borderedProminent)
                            .accessibilityIdentifier(Identifiers.startPiece(card.piece))
                        }
                        .padding(16)
                        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 16))
                        .overlay {
                            RoundedRectangle(cornerRadius: 16)
                                .stroke(.quaternary, lineWidth: 1)
                        }
                    }
                }

                if let message = wallModel.statusMessage {
                    Text(message)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }

                if let status = captureModel.statusMessage {
                    Text(status)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .accessibilityIdentifier("capture.status")
                        .fixedSize(horizontal: false, vertical: true)
                        .multilineTextAlignment(.center)
                }

                // Commit-unique anchor id on the DIRECT child of the
                // .scrollTargetLayout() VStack: when a commit lands this
                // row gets a new id, so the wall's `.scrollPosition(id:)`
                // binding resolves it to a position (issue #18
                // deterministic reveal). .scrollTargetLayout() alone
                // registers id-bearing children as position targets.
                LedgerSummaryView(model: captureModel)
                    .id(LedgerSummaryView.anchorID(for: captureModel.lastCommittedSummary))
            }
            .padding(16)
            // Register the wall content as the scroll-target layout so
            // `.scrollPosition(id:)` can resolve the ledger anchor id
            // (issue #18 review finding: without this the reveal would
            // fall back to free-scroll position semantics, not an id).
            .scrollTargetLayout()
        }
        .scrollPosition(id: $revealedSectionID)
        .navigationTitle("Practice Wall")
        .accessibilityIdentifier("practice.wall")
        // Issue #18: when a commit lands while the wall is visible,
        // scroll the ledger row the user just wrote into view
        // deterministically. App-level swipe bursts in UI tests could not
        // reliably reveal this row on some hosted runners; the app itself
        // now owns the reveal. Repeated onAppear (back from piece detail)
        // must NOT re-trigger the jump — revealLedgerIfNew fires once per
        // commit, and the commit flow's wall rebuild is covered by the
        // seed in init.
        .onAppear {
            revealLedgerIfNew(captureModel.lastCommittedSummary)
        }
        .onChange(of: captureModel.lastCommittedSummary) { _, summary in
            revealLedgerIfNew(summary)
        }
        .accessibilityRotor("Practice pieces") {
            ForEach(wallModel.cards) { card in
                AccessibilityRotorEntry(card.piece.title, id: card.id)
            }
        }
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Button("Settings", systemImage: "gearshape") { showingSettings = true }
                    .accessibilityIdentifier("settings.open")
            }
            ToolbarItem(placement: .primaryAction) {
                Button {
                    showingAddPiece = true
                } label: {
                    Image(systemName: "plus.circle.fill")
                        .accessibilityLabel("Add piece")
                }
                .accessibilityIdentifier("capture.addPiece.toolbar")
            }
        }
        .sheet(isPresented: $showingAddPiece, onDismiss: wallModel.reload) {
            AddPieceSheet(model: captureModel, isPresented: $showingAddPiece)
        }
        .sheet(isPresented: $showingSettings, onDismiss: {
            captureModel.loadLibrary()
            wallModel.reload()
        }) {
            SettingsView(store: captureModel.store, databaseURL: WoodshedStoreContainer.storeURL())
        }
    }
}

struct PracticeWallCard: View {
    let card: PracticeWorkspaceViewModel.Card

    private var accessibilitySummary: String {
        [
            card.piece.title,
            "Status: \(card.piece.status == .maintenance ? "Maintenance" : "Active")",
            "Last practiced: \(lastPracticedText)",
            "This week: \(weeklyMinutesText)",
            "Best tempo: \(bestTempoText)",
            "Versus target: \(tempoDeltaText)",
        ].joined(separator: ", ")
    }

    private var lastPracticedText: String {
        card.daysSinceLast.map { $0 == 0 ? "Today" : "\($0) days ago" } ?? "Unknown"
    }

    private var weeklyMinutesText: String {
        card.weeklyMinutes.map { "\($0) minutes" } ?? "Unknown"
    }

    private var bestTempoText: String {
        card.bestTempo.map { "\($0) BPM" } ?? "Unknown"
    }

    private var tempoDeltaText: String {
        card.bestTempoDelta.map { value in
            value >= 0 ? "+\(value) BPM" : "\(value) BPM"
        } ?? "Unknown"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                Text(card.piece.title)
                    .font(.title3.bold())
                Spacer()
                Text(card.piece.status == .maintenance ? "Maintenance" : "Active")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
            }

            HStack(spacing: 8) {
                metric("Last practiced", value: card.daysSinceLast.map { $0 == 0 ? "Today" : "\($0)d ago" })
                metric("This week", value: card.weeklyMinutes.map { "\($0) min" })
            }
            HStack(spacing: 8) {
                metric("Best tempo", value: card.bestTempo.map { "\($0) BPM" })
                metric("Vs target", value: card.bestTempoDelta.map { value in
                    value >= 0 ? "+\(value) BPM" : "\(value) BPM"
                })
            }
        }
        .contentShape(Rectangle())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilitySummary)
    }

    private func metric(_ label: String, value: String?) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
            if let value {
                Text(value)
                    .font(.subheadline.weight(.semibold))
            } else {
                Text("Unknown")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .accessibilityLabel("\(label): Unknown")
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct PieceDetailView: View {
    let piece: Piece
    @ObservedObject var model: PracticeWorkspaceViewModel

    private var sessions: [PracticeWorkspaceViewModel.SessionHistory] {
        model.sessionHistory(for: piece)
    }

    private var tempos: [TempoLog] {
        model.tempoHistory(for: piece.id)
    }

    var body: some View {
        List {
            Section("Status") {
                Picker("Piece status", selection: Binding(
                    get: { model.selectedPiece?.status ?? piece.status },
                    set: { model.updateStatus($0) }
                )) {
                    Text("Active").tag(Piece.Status.active)
                    Text("Maintenance").tag(Piece.Status.maintenance)
                    Text("Retired").tag(Piece.Status.retired)
                }
                .pickerStyle(.segmented)
                .accessibilityIdentifier("piece.status")
                Text("Retired pieces leave the wall but keep all history.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            Section("Sessions & splits") {
                if sessions.isEmpty {
                    Text("Unknown — no sessions logged")
                        .foregroundStyle(.secondary)
                        .accessibilityIdentifier("piece.history.unknown")
                } else {
                    ForEach(sessions) { row in
                        VStack(alignment: .leading, spacing: 4) {
                            Text(row.session.startedAt, format: .dateTime.month().day().year())
                                .font(.headline)
                            Text("\(row.minutes) minutes")
                            ForEach(row.splits) { split in
                                Text("\(split.split.label): \(split.minutes) minutes")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }

            Section("Tempo series") {
                if tempos.isEmpty {
                    Text("Unknown — no tempos logged")
                        .foregroundStyle(.secondary)
                        .accessibilityIdentifier("piece.tempo.unknown")
                } else {
                    ForEach(tempos, id: \.id) { tempo in
                        HStack {
                            Text(tempo.loggedAt, format: .dateTime.month().day().year())
                            Spacer()
                            Text("\(tempo.bpm) BPM")
                        }
                    }
                }
            }
        }
        .navigationTitle(piece.title)
        .navigationBarTitleDisplayMode(.inline)
        .accessibilityIdentifier("piece.detail")
        .onAppear { model.selectPiece(piece.id) }
    }
}

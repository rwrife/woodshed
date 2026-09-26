import SwiftUI
import WoodshedKit
import WoodshedStore

/// Root view for the session-capture workflow (issue #4). Switches between
/// the Quick Start picker, the running session controls, and the stop
/// confirmation flow based on `SessionCaptureViewModel.state`.
struct BootstrapHomeView: View {
    @ObservedObject var model: SessionCaptureViewModel

    var body: some View {
        NavigationStack {
            Group {
                switch model.state {
                case .idle:
                    StartSessionPickerView(model: model)
                case .running, .paused:
                    RunningSessionView(model: model)
                case .confirming:
                    StopConfirmationView(model: model)
                }
            }
            .navigationTitle(model.state == .idle ? "Woodshed" : "")
            .navigationBarTitleDisplayMode(.inline)
        }
        .accessibilityIdentifier("bootstrap.home")
    }
}

/// One tap from launch: Quick Start into Free Practice. A second tap picks
/// a specific piece (favorites/recents first). Reachable in <= 2 taps.
struct StartSessionPickerView: View {
    @ObservedObject var model: SessionCaptureViewModel
    @State private var showingAddPiece = false

    var body: some View {
        ScrollView {
            VStack(spacing: 20) {
                header

                Button {
                    model.startSession(piece: model.freePracticePiece())
                } label: {
                    Label("Quick Start: Free Practice", systemImage: "play.circle.fill")
                        .font(.title2.bold())
                        .frame(maxWidth: .infinity, minHeight: 64)
                }
                .buttonStyle(.borderedProminent)
                .accessibilityIdentifier("capture.quickStart.free")
                .accessibilityHint("Starts a practice session immediately without picking a piece.")

                let groups = model.sortedPickerPieces
                pieceSection(title: "Favorites", pieces: groups.favorites)
                pieceSection(title: "Recent", pieces: groups.recents)
                pieceSection(title: "All pieces", pieces: groups.others)

                if model.availablePieces.filter({ $0.id != WoodshedStoreContainer.freePieceID }).isEmpty {
                    Text("Add a piece to see it here as a one-tap start.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }

                if let status = model.statusMessage {
                    Text(status)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .accessibilityIdentifier("capture.status")
                        .fixedSize(horizontal: false, vertical: true)
                        .multilineTextAlignment(.center)
                }

                LedgerSummaryView(model: model)
            }
            .padding(20)
        }
        .toolbar {
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
        .sheet(isPresented: $showingAddPiece) {
            AddPieceSheet(model: model, isPresented: $showingAddPiece)
        }
    }

    private var header: some View {
        VStack(spacing: 8) {
            Image(systemName: "music.note.list")
                .font(.system(size: 44))
                .foregroundStyle(.tint)
                .accessibilityHidden(true)
            Text("Woodshed")
                .font(.largeTitle.bold())
            Text("Session capture and the practice wall arrive in the next milestones.")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    @ViewBuilder
    private func pieceSection(title: String, pieces: [Piece]) -> some View {
        if !pieces.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                Text(title)
                    .font(.headline)
                    .frame(maxWidth: .infinity, alignment: .leading)
                ForEach(pieces, id: \.id) { piece in
                    PieceStartRow(piece: piece, model: model)
                }
            }
        }
    }
}

/// A single one-handed, big-target row that starts a session with `piece`
/// on a single tap, plus a favorite toggle.
struct PieceStartRow: View {
    let piece: Piece
    @ObservedObject var model: SessionCaptureViewModel

    var body: some View {
        HStack {
            Button {
                model.startSession(piece: piece)
            } label: {
                VStack(alignment: .leading, spacing: 2) {
                    Text(piece.title)
                        .font(.body.weight(.semibold))
                        .multilineTextAlignment(.leading)
                    if let target = piece.targetBPM {
                        Text("Target \(target) BPM")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .frame(maxWidth: .infinity, minHeight: 56, alignment: .leading)
            }
            .buttonStyle(.bordered)
            .accessibilityIdentifier(Identifiers.startPiece(piece))
            .accessibilityLabel("Start session: \(piece.title)")

            Button {
                model.toggleFavorite(pieceID: piece.id)
            } label: {
                Image(systemName: model.favoritePieceIDs.contains(piece.id) ? "star.fill" : "star")
                    .frame(width: 44, height: 44)
            }
            .accessibilityIdentifier(Identifiers.favoriteToggle(piece))
            .accessibilityLabel(model.favoritePieceIDs.contains(piece.id) ? "Remove favorite" : "Add favorite")
        }
    }
}

struct AddPieceSheet: View {
    @ObservedObject var model: SessionCaptureViewModel
    @Binding var isPresented: Bool
    @State private var title: String = ""

    var body: some View {
        NavigationStack {
            Form {
                TextField("Piece title", text: $title)
                    .accessibilityIdentifier("addPiece.title")
            }
            .navigationTitle("Add Piece")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { isPresented = false }
                        .accessibilityIdentifier("addPiece.cancel")
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        model.addPiece(title: title)
                        isPresented = false
                    }
                    .disabled(title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    .accessibilityIdentifier("addPiece.save")
                }
            }
        }
    }
}

/// Ledger row counts read straight from the store — doubles as the
/// end-to-end "ledger-assert" surface for UI tests (issue #4 acceptance).
struct LedgerSummaryView: View {
    @ObservedObject var model: SessionCaptureViewModel
    @State private var usage: StorageUsage?

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Ledger")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            if let usage {
                Text("Sessions: \(usage.rows.sessions)")
                    .accessibilityIdentifier("ledger.sessions.count")
                Text("Session splits: \(usage.rows.sessionSplits)")
                    .accessibilityIdentifier("ledger.splits.count")
                Text("Tempo logs: \(usage.rows.tempoLogs)")
                    .accessibilityIdentifier("ledger.tempoLogs.count")
                Text("Practice notes: \(usage.rows.practiceNotes)")
                    .accessibilityIdentifier("ledger.notes.count")
            } else {
                Text("Ledger unavailable")
                    .accessibilityIdentifier("ledger.unavailable")
            }
        }
        .font(.footnote)
        .foregroundStyle(.secondary)
        .frame(maxWidth: .infinity, alignment: .leading)
        .onAppear(perform: refresh)
        .onChange(of: model.lastCommittedSummary) { _, _ in refresh() }
    }

    private func refresh() {
        usage = try? model.store.storageUsage()
    }
}

enum Identifiers {
    static func slug(text: String) -> String {
        text
            .lowercased()
            .replacingOccurrences(of: "[^a-z0-9]+", with: "-", options: .regularExpression)
            .trimmingCharacters(in: CharacterSet(charactersIn: "-"))
    }

    static func slug(_ piece: Piece) -> String { slug(text: piece.title) }
    static func startPiece(_ piece: Piece) -> String { "capture.piece.start.\(slug(piece))" }
    static func favoriteToggle(_ piece: Piece) -> String { "capture.piece.favorite.\(slug(piece))" }
    static func switchPiece(_ piece: Piece) -> String { "capture.switch.\(slug(piece))" }
}

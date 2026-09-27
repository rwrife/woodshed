import SwiftUI
import WoodshedKit
import WoodshedStore

/// Root view. In the idle state it hands off to `PracticeWorkspaceView`,
/// which owns the practice wall + piece detail and, through
/// `PracticeWorkspaceLayout`, the only layout/size-class branch in the app.
/// The running and confirmation flows keep their own navigation stack.
struct BootstrapHomeView: View {
    @ObservedObject var model: SessionCaptureViewModel

    var body: some View {
        Group {
            switch model.state {
            case .idle:
                PracticeWorkspaceView(captureModel: model)
            case .running, .paused:
                NavigationStack {
                    RunningSessionView(model: model)
                        .navigationTitle(model.state == .idle ? "Woodshed" : "")
                        .navigationBarTitleDisplayMode(.inline)
                }
            case .confirming:
                NavigationStack {
                    StopConfirmationView(model: model)
                        .navigationTitle(model.state == .idle ? "Woodshed" : "")
                        .navigationBarTitleDisplayMode(.inline)
                }
            }
        }
        .accessibilityIdentifier("bootstrap.home")
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

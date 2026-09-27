import SwiftUI
import WoodshedKit

struct RunningSessionView: View {
    @ObservedObject var model: SessionCaptureViewModel
    @State private var showingPiecePicker = false

    var body: some View {
        ScrollView {
            VStack(spacing: 20) {
                VStack(spacing: 6) {
                    Text(model.state == .paused ? "Paused" : "Practicing")
                        .font(.headline)
                        .foregroundStyle(model.state == .paused ? .orange : .secondary)

                    Text(Self.duration(model.totalElapsedSeconds))
                        .font(.system(.largeTitle, design: .monospaced, weight: .bold))
                        .contentTransition(.numericText())
                        .accessibilityIdentifier("capture.elapsed")
                        .accessibilityLabel("Session elapsed time")
                        .accessibilityValue(Self.spokenDuration(model.totalElapsedSeconds))

                    Text(model.activePiece?.title ?? SessionCaptureViewModel.freePracticeTitle)
                        .font(.title2.bold())
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier("capture.activePiece")
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 16)

                Button {
                    showingPiecePicker = true
                } label: {
                    Label("Switch Piece", systemImage: "arrow.left.arrow.right.circle.fill")
                        .font(.title3.bold())
                        .frame(maxWidth: .infinity, minHeight: 60)
                }
                .buttonStyle(.borderedProminent)
                .accessibilityIdentifier("capture.switchPiece")
                .accessibilityHint("Ends the current split and starts a new split for another piece.")

                Button {
                    model.switchPiece(to: model.freePracticePiece())
                } label: {
                    Label("Free Practice", systemImage: "music.note")
                        .frame(maxWidth: .infinity, minHeight: 52)
                }
                .buttonStyle(.bordered)
                .accessibilityIdentifier("capture.switch.free")
                .accessibilityHint("Records unassigned practice time as its own split.")

                HStack(spacing: 12) {
                    Button {
                        if model.state == .paused {
                            model.resumeSession()
                        } else {
                            model.pauseSession()
                        }
                    } label: {
                        Label(
                            model.state == .paused ? "Resume" : "Pause",
                            systemImage: model.state == .paused ? "play.fill" : "pause.fill"
                        )
                        .frame(maxWidth: .infinity, minHeight: 52)
                    }
                    .buttonStyle(.bordered)
                    .accessibilityIdentifier("capture.pauseResume")
                    .accessibilityHint(model.state == .paused ? "Resumes wall-clock practice timing." : "Pauses practice timing without counting paused time.")

                    Button {
                        model.undoLastSwitch()
                    } label: {
                        Label("Undo Switch", systemImage: "arrow.uturn.backward")
                            .frame(maxWidth: .infinity, minHeight: 52)
                    }
                    .buttonStyle(.bordered)
                    .disabled(!model.canUndoLastSwitch)
                    .accessibilityIdentifier("capture.undo")
                    .accessibilityHint("Removes only the most recent piece switch.")
                }

                VStack(alignment: .leading, spacing: 8) {
                    Text("Completed splits")
                        .font(.headline)
                    if model.completedSplits.isEmpty {
                        Text("No switches yet")
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(model.completedSplits) { split in
                            HStack {
                                Text(split.pieceTitle)
                                Spacer()
                                Text(Self.duration(split.elapsedSeconds))
                                    .monospacedDigit()
                            }
                            .font(.body)
                            .accessibilityElement(children: .combine)
                            .accessibilityLabel("\(split.pieceTitle), \(Self.spokenDuration(split.elapsedSeconds))")
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                Button(role: .destructive) {
                    model.stopAndReview()
                } label: {
                    Label("Stop and Review", systemImage: "stop.circle.fill")
                        .font(.title3.bold())
                        .frame(maxWidth: .infinity, minHeight: 60)
                }
                .buttonStyle(.borderedProminent)
                .tint(.red)
                .accessibilityIdentifier("capture.stop")
                .accessibilityHint("Stops the timer and opens the split confirmation screen.")
            }
            .padding(20)
        }
        .navigationTitle("Session")
        .sheet(isPresented: $showingPiecePicker) {
            PieceSwitchSheet(model: model, isPresented: $showingPiecePicker)
        }
    }

    static func duration(_ seconds: TimeInterval) -> String {
        let total = max(0, Int(seconds))
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        let secs = total % 60
        return hours > 0
            ? String(format: "%02d:%02d:%02d", hours, minutes, secs)
            : String(format: "%02d:%02d", minutes, secs)
    }

    static func spokenDuration(_ seconds: TimeInterval) -> String {
        let total = max(0, Int(seconds))
        let minutes = total / 60
        let secs = total % 60
        return "\(minutes) minutes, \(secs) seconds"
    }
}

struct PieceSwitchSheet: View {
    @ObservedObject var model: SessionCaptureViewModel
    @Binding var isPresented: Bool

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    switchSection(title: "Unassigned", pieces: [model.freePracticePiece()])

                    let groups = model.sortedPickerPieces
                    switchSection(title: "Favorites", pieces: groups.favorites)
                    switchSection(title: "Recent", pieces: groups.recents)
                    switchSection(title: "All pieces", pieces: groups.others)
                }
                .padding(20)
            }
            .accessibilityIdentifier("capture.switch.scroll")
            .navigationTitle("Switch Piece")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { isPresented = false }
                        .accessibilityIdentifier("capture.switch.cancel")
                }
            }
        }
    }

    @ViewBuilder
    private func switchSection(title: String, pieces: [Piece]) -> some View {
        if !pieces.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                Text(title)
                    .font(.headline)
                ForEach(pieces, id: \.id) { piece in
                    switchButton(piece)
                }
            }
        }
    }

    private func switchButton(_ piece: Piece) -> some View {
        Button {
            model.switchPiece(to: piece)
            isPresented = false
        } label: {
            Text(piece.title)
                .multilineTextAlignment(.leading)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, minHeight: 52, alignment: .leading)
        }
        .buttonStyle(.bordered)
        .accessibilityIdentifier(Identifiers.switchPiece(piece))
        .accessibilityLabel("Switch to \(piece.title)")
    }
}

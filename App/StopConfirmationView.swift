import SwiftUI

struct StopConfirmationView: View {
    @ObservedObject var model: SessionCaptureViewModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text("Review Session")
                    .font(.largeTitle.bold())
                    .accessibilityIdentifier("capture.review.title")

                Text("Adjust split minutes in whole minutes, then optionally log tempo and a note.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                ForEach(model.reviewSplits) { split in
                    SplitReviewRow(
                        split: split,
                        onMinus: { model.adjustSplitMinutes(splitID: split.id, delta: -1) },
                        onPlus: { model.adjustSplitMinutes(splitID: split.id, delta: 1) }
                    )
                }

                ForEach(model.reviewTempoPieces) { piece in
                    TempoReviewRow(piece: piece, model: model)
                }

                VStack(alignment: .leading, spacing: 8) {
                    Text("One-line note (optional)")
                        .font(.headline)
                    TextField("What improved?", text: $model.practiceNoteText)
                        .textFieldStyle(.roundedBorder)
                        .accessibilityIdentifier("capture.review.note")
                }

                Text("Total minutes: \(model.reviewSplits.reduce(0) { $0 + $1.finalMinutes })")
                    .font(.headline)
                    .accessibilityIdentifier("capture.review.total")

                HStack(spacing: 12) {
                    Button(role: .cancel) {
                        model.cancelConfirmation()
                    } label: {
                        Text("Discard")
                            .frame(maxWidth: .infinity, minHeight: 52)
                    }
                    .buttonStyle(.bordered)
                    .accessibilityIdentifier("capture.review.discard")

                    Button {
                        do {
                            _ = try model.commitSession()
                        } catch {
                            model.statusMessage = "Save failed: \(error.localizedDescription)"
                        }
                    } label: {
                        Text("Save Session")
                            .font(.headline)
                            .frame(maxWidth: .infinity, minHeight: 52)
                    }
                    .buttonStyle(.borderedProminent)
                    .accessibilityIdentifier("capture.review.save")
                }
            }
            .padding(20)
        }
        .accessibilityIdentifier("capture.review.scroll")
        .navigationTitle("Confirm")
    }
}

struct TempoReviewRow: View {
    let piece: SessionCaptureViewModel.ReviewPiece
    @ObservedObject var model: SessionCaptureViewModel

    private var slug: String { Identifiers.slug(text: piece.title) }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Achieved tempo: \(piece.title) (optional)")
                .font(.headline)
                .fixedSize(horizontal: false, vertical: true)
            Stepper(
                value: Binding(
                    get: { model.achievedBPMByPiece[piece.id] ?? 60 },
                    set: { model.achievedBPMByPiece[piece.id] = $0 }
                ),
                in: 40...320,
                step: 1
            ) {
                Text(model.achievedBPMByPiece[piece.id].map { "\($0) BPM" } ?? "Not set")
            }
            .accessibilityIdentifier("capture.review.tempo.\(slug)")

            Button("Clear tempo") {
                model.achievedBPMByPiece[piece.id] = nil
            }
            .buttonStyle(.bordered)
            .accessibilityIdentifier("capture.review.tempo.\(slug).clear")
        }
    }
}

struct SplitReviewRow: View {
    let split: SessionCaptureViewModel.SplitDraft
    let onMinus: () -> Void
    let onPlus: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(split.pieceTitle)
                .font(.headline)
            HStack(spacing: 12) {
                Button(action: onMinus) {
                    Image(systemName: "minus.circle.fill")
                        .font(.title3)
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("capture.review.split.\(split.id.uuidString).minus")
                .accessibilityLabel("Decrease minutes for \(split.pieceTitle)")

                Text("\(split.finalMinutes) min")
                    .font(.body.monospacedDigit())
                    .frame(minWidth: 74)
                    .accessibilityIdentifier("capture.review.split.\(split.id.uuidString).minutes")

                Button(action: onPlus) {
                    Image(systemName: "plus.circle.fill")
                        .font(.title3)
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("capture.review.split.\(split.id.uuidString).plus")
                .accessibilityLabel("Increase minutes for \(split.pieceTitle)")

                Spacer()

                Text("raw \(split.computedMinutes)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(12)
        .background(.thinMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }
}

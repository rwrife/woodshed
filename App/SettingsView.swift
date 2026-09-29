import Foundation
import SwiftUI
import UniformTypeIdentifiers
import WoodshedKit
import WoodshedStore

private struct TransferDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.json, .commaSeparatedText] }
    var data: Data

    init(data: Data) { self.data = data }
    init(configuration: ReadConfiguration) throws {
        data = configuration.file.regularFileContents ?? Data()
    }
    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: data)
    }
}

struct SettingsView: View {
    let store: WoodshedStore
    let databaseURL: URL
    @Environment(\.dismiss) private var dismiss
    @State private var usage: StorageUsage?
    @State private var document: TransferDocument?
    @State private var exportType: UTType = .json
    @State private var exportName = "Woodshed Backup"
    @State private var showingExporter = false
    @State private var showingImporter = false
    @State private var preview: RestorePreview?
    @State private var errorMessage: String?
    @State private var restored = false

    var body: some View {
        NavigationStack {
            Form {
                Section("Storage") {
                    LabeledContent("Database", value: databaseURL.path)
                        .font(.footnote)
                        .textSelection(.enabled)
                    if let usage {
                        LabeledContent("Database size", value: ByteCountFormatter.string(fromByteCount: Int64(usage.databaseBytes), countStyle: .file))
                        count("Instruments", usage.rows.instruments)
                        count("Pieces", usage.rows.pieces)
                        count("Sessions", usage.rows.sessions)
                        count("Session splits", usage.rows.sessionSplits)
                        count("Tempo logs", usage.rows.tempoLogs)
                        count("Practice notes", usage.rows.practiceNotes)
                    }
                }
                Section("Your data") {
                    Button("Save JSON backup") { prepareExport(json: true) }
                        .accessibilityIdentifier("settings.backup")
                    Button("Export sessions CSV") { prepareExport(json: false) }
                        .accessibilityIdentifier("settings.csv")
                    Button("Restore JSON backup") { showingImporter = true }
                        .accessibilityIdentifier("settings.restore")
                    Text("Woodshed keeps your practice data on this iPhone. It does not send data over the network. A backup or export leaves the app only when you choose a location in Files.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                if let preview {
                    Section("Restore preview") {
                        Text(preview.summary)
                            .accessibilityIdentifier("restore.summary")
                        previewCount("Instruments", preview.before.instruments, preview.after.instruments)
                        previewCount("Pieces", preview.before.pieces, preview.after.pieces)
                        previewCount("Sessions", preview.before.sessions, preview.after.sessions)
                        previewCount("Session splits", preview.before.sessionSplits, preview.after.sessionSplits)
                        previewCount("Tempo logs", preview.before.tempoLogs, preview.after.tempoLogs)
                        previewCount("Practice notes", preview.before.practiceNotes, preview.after.practiceNotes)
                        Text("Replacing removes the current database records and installs the backup as one operation.")
                            .font(.footnote)
                        Button("Confirm Replace", role: .destructive) { confirmRestore(preview) }
                            .accessibilityIdentifier("restore.confirm")
                        Button("Cancel Restore") { self.preview = nil }
                            .accessibilityIdentifier("restore.cancel")
                    }
                }
                if restored {
                    Text("Backup restored.").accessibilityIdentifier("restore.success")
                }
            }
            .navigationTitle("Settings")
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
            .onAppear {
                refresh()
                if ProcessInfo.processInfo.arguments.contains("-ui-testing-restore-preview"), preview == nil {
                    preview = try? store.previewRestore(BackupCodec.encode(Ledger()))
                }
            }
            .fileExporter(isPresented: $showingExporter, document: document, contentType: exportType, defaultFilename: exportName) { result in
                if case .failure(let error) = result { errorMessage = error.localizedDescription }
                document = nil
            }
            .fileImporter(isPresented: $showingImporter, allowedContentTypes: [.json]) { result in
                do {
                    let url = try result.get()
                    let accessed = url.startAccessingSecurityScopedResource()
                    defer { if accessed { url.stopAccessingSecurityScopedResource() } }
                    preview = try store.previewRestore(Data(contentsOf: url))
                    restored = false
                } catch {
                    preview = nil
                    errorMessage = readable(error)
                }
            }
            .alert("Transfer failed", isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })) {
                Button("OK") { errorMessage = nil }
            } message: { Text(errorMessage ?? "") }
        }
    }

    private func count(_ name: String, _ value: Int) -> some View {
        LabeledContent(name, value: "\(value)")
    }
    private func previewCount(_ name: String, _ before: Int, _ after: Int) -> some View {
        LabeledContent(name, value: "\(before) → \(after)")
            .accessibilityIdentifier("restore.count.\(name.lowercased().replacingOccurrences(of: " ", with: ""))")
    }
    private func refresh() { usage = try? store.storageUsage() }
    private func prepareExport(json: Bool) {
        do {
            let data = json ? try store.backupData() : try store.sessionCSV()
            document = TransferDocument(data: data)
            exportType = json ? .json : .commaSeparatedText
            exportName = json ? "Woodshed Backup" : "Woodshed Sessions"
            showingExporter = true
        } catch { errorMessage = readable(error) }
    }
    private func confirmRestore(_ preview: RestorePreview) {
        do {
            try store.replace(with: preview)
            self.preview = nil
            restored = true
            refresh()
        } catch { errorMessage = readable(error) }
    }
    private func readable(_ error: Error) -> String {
        if let codecError = error as? BackupCodec.BackupCodecError,
           case let .unsupportedSchemaVersion(found, supported) = codecError {
            return "This backup uses schema \(found). This version of Woodshed supports schema \(supported.lowerBound)–\(supported.upperBound). Update the app before restoring."
        }
        if error is BackupCodec.BackupCodecError {
            return "This is not a valid Woodshed backup. Check the selected JSON file."
        }
        return error.localizedDescription
    }
}

import Foundation
import SwiftUI
import WoodshedKit
import WoodshedStore

@main
struct WoodshedApp: App {
    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var captureModel = WoodshedApp.makeCaptureModel()

    /// `@MainActor` class default-value initializers are evaluated in a
    /// nonisolated context and fail to compile under Swift 6 (gift-vault #11).
    /// App entry always runs on the main thread, so this assertion is honest.
    nonisolated private static func makeCaptureModel() -> SessionCaptureViewModel {
        MainActor.assumeIsolated {
            SessionCaptureViewModel(store: WoodshedStoreContainer.store)
        }
    }

    var body: some Scene {
        WindowGroup {
            BootstrapHomeView(model: captureModel)
        }
        .onChange(of: scenePhase) { _, phase in
            captureModel.handleScenePhaseChange(phase)
        }
    }
}

enum WoodshedStoreContainer {
    static let uiTestingArgument = "-ui-testing"
    static let uiTesting = ProcessInfo.processInfo.arguments.contains(uiTestingArgument)

    static let freeInstrumentID = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
    static let freePieceID = UUID(uuidString: "00000000-0000-0000-0000-000000000002")!

    static let primaryInstrumentID = UUID(uuidString: "10000000-0000-0000-0000-000000000001")!
    static let seedEtudePieceID = UUID(uuidString: "10000000-0000-0000-0000-000000000101")!
    static let seedScalesPieceID = UUID(uuidString: "10000000-0000-0000-0000-000000000102")!
    static let seedSightReadingPieceID = UUID(uuidString: "10000000-0000-0000-0000-000000000103")!

    static let store: WoodshedStore = {
        do {
            if uiTesting {
                wipeContainerForUITesting()
                clearCaptureDefaultsForUITesting()
            }
            let opened = try WoodshedStore.open(at: storeURL())
            try ensureBaselineRecords(in: opened, includeUITestSeedData: uiTesting)
            return opened
        } catch {
            NSLog("WoodshedStore open failed: \(error)")
            let fallback = try! WoodshedStore.inMemory()
            try? ensureBaselineRecords(in: fallback, includeUITestSeedData: true)
            return fallback
        }
    }()

    static func storeURL() -> URL {
        let root = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("Woodshed", isDirectory: true)
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root.appendingPathComponent("woodshed.sqlite")
    }

    static func wipeContainerForUITesting() {
        let root = storeURL().deletingLastPathComponent()
        try? FileManager.default.removeItem(at: root)
    }

    static func clearCaptureDefaultsForUITesting() {
        let defaults = UserDefaults.standard
        defaults.removeObject(forKey: SessionCaptureViewModel.recentPiecesDefaultsKey)
        defaults.removeObject(forKey: SessionCaptureViewModel.favoritePiecesDefaultsKey)
        defaults.removeObject(forKey: SessionCaptureViewModel.runningDraftDefaultsKey)
    }

    static func ensureBaselineRecords(in store: WoodshedStore, includeUITestSeedData: Bool) throws {
        let commitDate = Date(timeIntervalSince1970: 1_790_381_800)

        if try store.instruments.instrument(id: freeInstrumentID) == nil {
            try store.instruments.append(
                Instrument(id: freeInstrumentID, name: "General Practice"),
                committedAt: commitDate
            )
        }
        if try store.instruments.instrument(id: primaryInstrumentID) == nil {
            try store.instruments.append(
                Instrument(id: primaryInstrumentID, name: "Primary Instrument"),
                committedAt: commitDate
            )
        }
        if try store.pieces.piece(id: freePieceID) == nil {
            try store.pieces.append(
                Piece(
                    id: freePieceID,
                    instrumentID: freeInstrumentID,
                    title: SessionCaptureViewModel.freePracticeTitle,
                    status: .active,
                    targetBPM: nil
                ),
                committedAt: commitDate
            )
        }

        guard includeUITestSeedData else { return }

        let seededPieces: [(UUID, String, Int?)] = [
            (seedEtudePieceID, "Etude Op.10 No.3", 96),
            (seedScalesPieceID, "Scales", 112),
            (seedSightReadingPieceID, "Sight Reading", nil),
        ]

        for (id, title, targetBPM) in seededPieces where try store.pieces.piece(id: id) == nil {
            try store.pieces.append(
                Piece(
                    id: id,
                    instrumentID: primaryInstrumentID,
                    title: title,
                    status: .active,
                    targetBPM: targetBPM
                ),
                committedAt: commitDate
            )
        }
    }
}

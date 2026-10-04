import Foundation
@testable import FUMINIWAIOS
import NovelAuth
import NovelCore
import NovelSyncV2
import NovelSyncV2Application
import Testing

@MainActor
struct CheckpointCoordinatorIOSTests {
    @Test("D2: late checkpoint success/failure never repaints another work/account", arguments: ["work", "account"], [false, true])
    func checkpointCompletionIsFenced(change: String, fails: Bool) async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("P8b-D2-\(UUID().uuidString)")
        let suite = "P8b-D2-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer {
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: root)
        }
        let store = IOSDocumentStore(userDefaults: defaults, libraryRoot: root)
        await store.bootstrap()
        #expect(await store.makeNewDocument())
        let application = try #require(store.snapshotSyncV2Application)
        let workID = try #require(store.syncV2ActiveWorkID)
        let document = store.document
        let pause = CheckpointCompletionPause()
        store.workspaceCheckpointOverride = { request in
            let result = try await application.checkpoint(
                workID: request.workID, document: request.document, reason: request.reason,
                documentCreatedAt: request.documentCreatedAt,
                attachments: request.attachments, resources: request.resources
            )
            await pause.pause()
            if fails {
                throw SyncV2ApplicationError.safeBoundaryRejected
            }
            return result
        }
        store.saveCoordinator.markDirty()
        let task = Task { await store.saveNow() }
        await pause.waitUntilPaused()
        if change == "work" {
            store.document = .newDocument(title: "新作品")
            store.syncV2ActiveWorkID = WorkID(UUID())
            store.advanceDocumentSessionGeneration()
        } else {
            store.invalidateSnapshotSyncV2AccountOperations()
        }
        store.saveState = .dirty
        store.operationErrorMessage = "新しい画面"
        let projection = store.snapshotSyncState
        let conflict = store.snapshotSyncConflict
        let outcome = store.snapshotSyncOutcome
        pause.release()
        #expect(await !task.value)
        #expect(store.saveState == .dirty)
        #expect(store.snapshotSyncState == projection)
        #expect(store.snapshotSyncConflict == conflict)
        #expect(store.snapshotSyncOutcome == outcome)
        #expect(store.operationErrorMessage == "新しい画面")
        #expect(try await application.openLocal(workID: workID).document == document)
    }
}

@MainActor
private final class CheckpointCompletionPause {
    private var started: CheckedContinuation<Void, Never>?
    private var completion: CheckedContinuation<Void, Never>?

    func pause() async {
        await withCheckedContinuation { continuation in
            completion = continuation
            started?.resume()
            started = nil
        }
    }

    func waitUntilPaused() async {
        if completion != nil {
            return
        }
        await withCheckedContinuation { started = $0 }
    }

    func release() {
        completion?.resume()
        completion = nil
    }
}

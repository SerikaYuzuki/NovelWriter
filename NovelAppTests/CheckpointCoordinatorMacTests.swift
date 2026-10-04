import Foundation
@testable import FUMINIWA
import NovelCore
import NovelSyncV2
import NovelSyncV2Application
import NovelSyncV2Runtime
import Testing

@MainActor
struct CheckpointCoordinatorMacTests {
    @Test("D2: late checkpoint success/failure never repaints another work/account", arguments: ["work", "account"], [false, true])
    @MainActor
    func checkpointCompletionIsFenced(change: String, fails: Bool) async throws {
        let configuration = try TestRuntimeConfiguration(account: nil)
        let application = try await SnapshotSyncV2Runtime.makeApplication(mode: .test(configuration))
        let pause = CheckpointCompletionPause()
        var dependencies = AppDependencies(userDefaults: makeIsolatedTestUserDefaults())
        dependencies.snapshotSyncV2CheckpointOverride = { app, workID, document, reason, date, attachments, resources in
            let result = try await app.checkpoint(workID: workID, document: document, reason: reason,
                                                  documentCreatedAt: date, attachments: attachments, resources: resources)
            await pause.pause()
            if fails {
                throw SyncV2ApplicationError.safeBoundaryRejected
            }
            return result
        }
        let state = AppState(dependencies: dependencies, initialStartupState: .ready)
        state.snapshotSyncV2Application = application
        let document = NovelDocument.newDocument(title: "保存元")
        let workID = WorkID(UUID())
        #expect(state.installV2Document(document, workID: workID, createdAt: Date()))
        state.saveCoordinator.markDirty()
        let task = Task { await state.saveNow() }
        await pause.waitUntilPaused()
        if change == "work" {
            #expect(state.installV2Document(.newDocument(title: "新作品"), workID: WorkID(UUID()), createdAt: Date()))
        } else {
            state.authSession = makeMacV2Session(accountID: "next-account", fence: "next-fence")
            state.snapshotSyncV2AccountScopeGeneration &+= 1
        }
        state.saveState = .unsaved
        state.operationMessage = "新しい画面"
        let projection = state.snapshotSyncV2UIState
        let conflict = state.snapshotSyncConflict
        pause.release()
        #expect(await !task.value)
        #expect(state.saveState == .unsaved)
        #expect(state.snapshotSyncV2UIState == projection)
        #expect(state.snapshotSyncConflict == conflict)
        #expect(state.operationMessage == "新しい画面")
        // The stale UI completion does not undo the old work's SQLite commit.
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

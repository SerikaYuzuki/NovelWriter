import Foundation
@testable import FUMINIWA
import NovelCore
import NovelSyncV2
import NovelSyncV2Application
import NovelSyncV2Runtime
import NovelSyncV2Store
import Testing

@MainActor @Suite("Library deletion")
struct LibraryDeletionTests {
    @Test("deleting the last local work flushes dirty edits before retiring the editor", arguments: [false, true])
    func lastWorkDeletion(dirty: Bool) async throws {
        let config = try TestRuntimeConfiguration(account: nil)
        let store = try LocalSyncV2Store(root: config.localRoot.url, policy: .createNew)
        let workID = WorkID(UUID())
        let document = NovelDocument.newDocument()
        let createdAt = Date(timeIntervalSince1970: 1_700_000_000)
        _ = try await store.checkpoint(
            V2CheckpointRequest(
                workID: workID,
                document: document,
                documentCreatedAt: createdAt,
                expectedGeneration: 0
            ),
            scope: .unbound
        )
        let app = try await SnapshotSyncV2Runtime.makeApplication(mode: .test(config))
        let defaults = makeIsolatedTestUserDefaults()
        let state = AppState(dependencies: AppDependencies(userDefaults: defaults), initialStartupState: .ready)
        state.snapshotSyncV2Application = app
        state.installV2Document(document, workID: workID, createdAt: createdAt)
        await state.refreshSnapshotLibrary()
        let work = try #require(state.snapshotSyncLibraryWorks.first)
        if dirty {
            state.workspaceModel.document.title = "last unsaved edit"
            state.markDocumentDirty()
        }
        #expect(await state.deleteLibraryWork(work, accountScope: state.snapshotSyncV2AccountScopeToken))
        #expect(state.currentSnapshotSyncV2WorkID == nil)
        #expect(!state.startupState.isReady)
        #expect(state.snapshotSyncLibraryWorks.isEmpty)
        #expect(await state.saveNow())
        #expect(await state.saveBeforeTermination())
        let restarted = AppState(dependencies: AppDependencies(userDefaults: defaults))
        restarted.snapshotSyncV2Application = app
        await restarted.bootstrap()
        #expect(restarted.currentSnapshotSyncV2WorkID == nil)
        #expect(!restarted.startupState.isReady)
        #expect(try await app.library().items.isEmpty)
        #expect(await config.remote.recordedDeletions().isEmpty)
        await store.close()
    }
}

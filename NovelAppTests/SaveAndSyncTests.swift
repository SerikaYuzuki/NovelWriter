import Foundation
@testable import FUMINIWA
import NovelCore
import NovelSyncV2
import NovelSyncV2Application
import NovelSyncV2Runtime
import NovelSyncV2Store
import Testing

@MainActor
struct SaveAndSyncTests {
    @Test("save shortcut checks remote even without edits, and keeps unbound works local", arguments: [false, true])
    func saveAndSync(isBound: Bool) async throws {
        let config = try TestRuntimeConfiguration(account: isBound ? TestAccount(accountID: "test-account", accountFence: "test-fence") : nil)
        let store = try LocalSyncV2Store(root: config.localRoot.url, policy: .createNew)
        let workID = WorkID(UUID())
        let document = NovelDocument.newDocument()
        let createdAt = Date(timeIntervalSince1970: 1_700_000_000)
        let scope: V2LocalWorkScope = isBound ? .bound(V2AccountBinding(accountID: "test-account", accountFence: "test-fence", serverInstanceID: "test-server")) : .unbound
        if isBound {
            let encoded = try SnapshotCodec.encode(SnapshotModel(workId: workID, document: document, documentCreatedAt: createdAt), parents: [])
            let inbox = try V2RemoteSnapshot(workID: workID, encoded: encoded, expectedCurrentSnapshotID: nil,
                                             expectedLocalGeneration: 0, expectedRemoteHead: V2RemoteHead(snapshotID: encoded.snapshotId, generation: 1))
            try await store.stageRemote(inbox, scope: scope)
            try await store.verifyInbox(inboxID: inbox.inboxID, scope: scope)
            try await store.adoptInbox(inboxID: inbox.inboxID, scope: scope)
            #expect(try await store.pendingIntents(scope: scope, workID: workID).isEmpty)
        } else {
            _ = try await store.checkpoint(V2CheckpointRequest(workID: workID, document: document,
                                                               documentCreatedAt: createdAt, expectedGeneration: 0), scope: scope)
        }
        let app = try await SnapshotSyncV2Runtime.makeApplication(mode: .test(config))
        let state = AppState(dependencies: AppDependencies(userDefaults: makeIsolatedTestUserDefaults()), initialStartupState: .ready)
        state.snapshotSyncV2Application = app
        state.installV2Document(document, workID: workID, createdAt: createdAt)
        state.snapshotSyncCurrentWorkAccountState = isBound ? .active : .unbound
        if isBound {
            state.authSession = makeMacV2Session(accountID: "test-account", fence: "test-fence")
            state.authUIState = .signedIn(accountID: "test-account")
        }
        state.saveState = .saved
        let observation = Task { await state.observeSnapshotSyncV2Status() }
        defer { observation.cancel() }
        await state.saveAndSyncCurrentWork()
        if isBound {
            try await eventuallyMac { await !(config.remote.recordedOperations()).isEmpty }
            #expect(try await store.pendingIntents(scope: scope, workID: workID).count == 1)
        } else {
            #expect(state.operationMessage == nil)
            #expect(await config.remote.recordedOperations().isEmpty)
            #expect(try await store.allSealedCommands(scope: .bound(V2AccountBinding(accountID: "test-account", accountFence: "test-fence", serverInstanceID: "test-server")), workID: workID).isEmpty)
        }
        #expect(try await store.open(workID: workID, scope: scope).document == document)
        state.cancelSnapshotSyncV2BackgroundOperations()
        await store.close()
    }
}

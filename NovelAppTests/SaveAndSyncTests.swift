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
    @Test("save shortcut checks remote even without edits, and keeps unbound works local", arguments: [false, true], [false, true])
    func saveAndSync(isBound: Bool, serverAhead: Bool) async throws {
        let config = try TestRuntimeConfiguration(account: isBound ? TestAccount(accountID: "test-account", accountFence: "test-fence") : nil)
        let store = try LocalSyncV2Store(root: config.localRoot.url, policy: .createNew)
        let workID = WorkID(UUID())
        let document = NovelDocument.newDocument()
        let createdAt = Date(timeIntervalSince1970: 1_700_000_000)
        let scope: V2LocalWorkScope = isBound ? .bound(V2AccountBinding(accountID: "test-account", accountFence: "test-fence", serverInstanceID: "test-server")) : .unbound
        var expectedRemoteSnapshotID: SnapshotID?
        if isBound {
            let encoded = try SnapshotCodec.encode(SnapshotModel(workId: workID, document: document, documentCreatedAt: createdAt), parents: [])
            let inbox = try V2RemoteSnapshot(workID: workID, encoded: encoded, expectedCurrentSnapshotID: nil,
                                             expectedLocalGeneration: 0, expectedRemoteHead: V2RemoteHead(snapshotID: encoded.snapshotId, generation: 1))
            try await store.stageRemote(inbox, scope: scope)
            try await store.verifyInbox(inboxID: inbox.inboxID, scope: scope)
            try await store.adoptInbox(inboxID: inbox.inboxID, scope: scope)
            #expect(try await store.pendingIntents(scope: scope, workID: workID).isEmpty)
            var updated = document
            updated.title = "サーバーの更新"
            let remote = try SnapshotCodec.encode(
                SnapshotModel(workId: workID, document: updated, documentCreatedAt: createdAt),
                parents: [encoded.snapshotId]
            )
            expectedRemoteSnapshotID = serverAhead ? remote.snapshotId : encoded.snapshotId
            await config.remote.setHeadHandler { _ in
                try SyncV2RemoteHead(snapshotID: serverAhead ? remote.snapshotId : encoded.snapshotId,
                                     generation: serverAhead ? 2 : 1)
            }
            await config.remote.setUpdateHandler { _ in
                try SyncV2RemoteInbox(inboxID: UUID(), workID: workID, headSnapshotID: remote.snapshotId,
                                      snapshots: [encoded, remote], expectedCurrentSnapshotID: nil,
                                      expectedLocalGeneration: 0,
                                      expectedRemoteHead: SyncV2RemoteHead(snapshotID: remote.snapshotId, generation: 2))
            }
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
        let expectedSnapshotID = expectedRemoteSnapshotID
        await state.saveAndSyncCurrentWork()
        if isBound {
            try await eventuallyMac { await config.remote.recordedHeadReads().contains(workID) }
            if serverAhead {
                try await eventuallyMac {
                    if let pending = try await app.pendingAdoption(workID: workID),
                       await app.uiState(workID: workID)?.remoteProgress == .readyForSafeAdoption(inboxID: pending.inboxID) {
                        return true
                    }
                    return try await store.open(workID: workID, scope: scope).summary.currentSnapshotID == expectedSnapshotID
                }
                #expect(await config.remote.recordedUpdateReads() == [workID])
            } else {
                try await eventuallyMac { await app.uiState(workID: workID)?.remoteProgress == .noChanges }
                #expect(await config.remote.recordedUpdateReads().isEmpty)
            }
            #expect(try await store.pendingIntents(scope: scope, workID: workID).isEmpty)
            #expect(try await store.allSealedCommands(scope: scope, workID: workID).isEmpty)
            #expect(await config.remote.recordedOperations().isEmpty)
        } else {
            #expect(await config.remote.recordedHeadReads().isEmpty)
            #expect(await config.remote.recordedUpdateReads().isEmpty)
            #expect(state.operationMessage == nil)
            #expect(await config.remote.recordedOperations().isEmpty)
            #expect(try await store.allSealedCommands(scope: .bound(V2AccountBinding(accountID: "test-account", accountFence: "test-fence", serverInstanceID: "test-server")), workID: workID).isEmpty)
        }
        if !isBound || !serverAhead {
            #expect(try await store.open(workID: workID, scope: scope).document == document)
        }
        state.cancelSnapshotSyncV2BackgroundOperations()
        await store.close()
    }

    @Test("toolbar saves an unbound work repeatedly without creating account copies, including after restart", arguments: [false, true])
    func unboundToolbarSaveDoesNotClone(signedIn: Bool) async throws {
        let config = try TestRuntimeConfiguration(account: signedIn ? TestAccount(accountID: "test-account", accountFence: "test-fence") : nil)
        let store = try LocalSyncV2Store(root: config.localRoot.url, policy: .createNew)
        let workID = WorkID(UUID())
        let document = NovelDocument.newDocument()
        let createdAt = Date(timeIntervalSince1970: 1_700_000_000)
        _ = try await store.checkpoint(V2CheckpointRequest(workID: workID, document: document, documentCreatedAt: createdAt, expectedGeneration: 0), scope: .unbound)
        let app = try await SnapshotSyncV2Runtime.makeApplication(mode: .test(config))
        let defaults = makeIsolatedTestUserDefaults()
        let state = AppState(dependencies: AppDependencies(userDefaults: defaults), initialStartupState: .ready)
        state.snapshotSyncV2Application = app
        state.installV2Document(document, workID: workID, createdAt: createdAt)
        state.snapshotSyncCurrentWorkAccountState = .unbound
        if signedIn {
            state.authSession = makeMacV2Session(accountID: "test-account", fence: "test-fence")
            state.authUIState = .signedIn(accountID: "test-account")
        }
        let presentation = ExplicitSyncPresentation()
        for revision in 1 ... 3 {
            state.document.title = "保存確認\(revision)"
            state.markDocumentDirty()
            presentation.requestSync(appState: state)
            #expect(!presentation.showingSetup)
            try await eventuallyMac { state.saveState == .saved }
            #expect(state.currentSnapshotSyncV2WorkID == workID)
            #expect(try await store.open(workID: workID, scope: .unbound).document?.title == state.document.title)
            #expect(try await app.library().items.count == 1)
        }
        let restarted = AppState(dependencies: AppDependencies(userDefaults: defaults))
        restarted.snapshotSyncV2Application = app
        await restarted.bootstrap()
        #expect(restarted.currentSnapshotSyncV2WorkID == workID)
        #expect(restarted.document.title == "保存確認3")
        #expect(try await app.library().items.count == 1)
        #expect(await config.remote.recordedOperations().isEmpty)
        await store.close()
    }
}

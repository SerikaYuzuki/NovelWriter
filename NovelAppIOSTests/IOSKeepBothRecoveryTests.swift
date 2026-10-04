import Foundation
@testable import FUMINIWAIOS
import NovelCore
import NovelSyncV2
@testable import NovelSyncV2Application
import NovelSyncV2Runtime
import NovelSyncV2Store
import Testing

@MainActor
struct IOSKeepBothRecoveryTests {
    @Test("failed keep-both can leave without checkpointing the source, open another work, or retry the same clone",
          arguments: ["library", "other", "retry"])
    func failedHandoffRecovery(action: String) async throws {
        let configuration = try TestRuntimeConfiguration()
        await configuration.remote.setBehaviors([.failure(.offline)])
        let application = try await SnapshotSyncV2Runtime.makeApplication(mode: .test(configuration))
        let sourceID = try await seedConflict(configuration: configuration, application: application)
        let suiteName = "FUMINIWA-iOS-keep-both-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let store = IOSDocumentStore(userDefaults: defaults, libraryRoot: configuration.localRoot.url,
                                     runtimeComposition: .test(configuration))
        store.snapshotSyncV2Application = application
        let opened = try await application.openLocal(workID: sourceID)
        let sourceDocument = try #require(opened.document)
        #expect(store.installSnapshotSyncV2Opened(opened, value: sourceDocument))
        await store.applySnapshotSyncV2State(application.uiState(workID: sourceID))
        let original = store.workspaceModel.document
        let selection = try #require(store.snapshotSyncV2DisplayedConflictSelection)
        store.snapshotSyncV2KeepBothInstallOverride = { false }
        #expect(await store.resolveSnapshotSyncV2Conflict(using: .keepBoth, expectedSelection: selection) == false)
        let duplicateID = try #require(store.workspaceModel.keepBothPendingWorkID)
        #expect(store.workspaceModel.activeWorkID == sourceID)
        #expect(store.workspaceModel.document == original)
        let sourceBeforeDeparture = try await application.openLocal(workID: sourceID)
        let historyBefore = try await application.historyPage(workID: sourceID).items
        let navigation = IOSWorkspaceNavigationCoordinator()
        let session = try #require(store.currentDocumentSessionToken)
        navigation.showProjectHome(for: session)
        navigation.showEditor(for: session, chapterID: original.chapters[0].id, episodeID: original.chapters[0].episodes[0].id)
        if action == "retry" {
            // Retrying a failed install never queues another conflict decision.
            store.snapshotSyncV2KeepBothInstallOverride = { true }
            #expect(await store.retryKeepBothHandoff())
            #expect(store.workspaceModel.activeWorkID == duplicateID)
        } else if action == "other" {
            let anotherID = WorkID(UUID())
            _ = try await application.checkpoint(workID: anotherID, document: .newDocument(title: "別作品"),
                                                 reason: .explicit, documentCreatedAt: Date())
            store.workspaceModel.saveState = .failed // Departure must bypass save for this frozen source.
            #expect(await store.openSnapshotSyncV2(workID: anotherID.rawValue))
            #expect(store.workspaceModel.activeWorkID == anotherID)
        } else {
            store.workspaceModel.saveState = .failed
            #expect(await navigation.returnToLibrary(using: store))
            #expect(navigation.path.isEmpty)
            #expect(store.startupState == .library)
            #expect(store.workspaceModel.activeWorkID == nil)
        }
        #expect(store.workspaceModel.keepBothPendingWorkID == nil)
        #expect(store.workspaceModel.keepBothHandoff == nil)
        let after = try await application.openLocal(workID: sourceID)
        #expect(after.generation == sourceBeforeDeparture.generation && after.document == original)
        #expect(try await application.historyPage(workID: sourceID).items == historyBefore)
    }

    private func seedConflict(configuration: TestRuntimeConfiguration, application: SyncV2Application) async throws -> WorkID {
        let storage = try LocalSyncV2Store(root: configuration.localRoot.url, policy: .openExisting)
        let workID = WorkID(UUID()), createdAt = Date(timeIntervalSince1970: 1_720_000_000)
        let scope = V2LocalWorkScope.bound(V2AccountBinding(accountID: "test-account", accountFence: "test-fence", serverInstanceID: "test-server"))
        let local = NovelDocument.newDocument(title: "端末版")
        let checkpoint = try await storage.checkpoint(
            V2CheckpointRequest(workID: workID, document: local, documentCreatedAt: createdAt, expectedGeneration: 0, reason: .migration), scope: scope
        )
        var remote = local
        remote.title = "サーバー版"
        let encoded = try SnapshotCodec.encode(SnapshotModel(workId: workID, document: remote, documentCreatedAt: createdAt), parents: [])
        let snapshot = try V2RemoteSnapshot(inboxID: UUID(), workID: workID, encoded: encoded,
                                            expectedCurrentSnapshotID: checkpoint.snapshotID, expectedLocalGeneration: checkpoint.generation,
                                            expectedRemoteHead: V2RemoteHead(snapshotID: encoded.snapshotId, generation: 1))
        let candidate = try await storage.appendConflict(workID: workID, baseSnapshotID: nil,
                                                         localSnapshotID: checkpoint.snapshotID, remote: snapshot,
                                                         sourceGeneration: checkpoint.generation, scope: scope)
        await storage.close()
        let projection = SyncV2ConflictProjection(conflictID: candidate.conflictID, revision: candidate.revision,
                                                  baseSnapshotID: candidate.baseSnapshotID, localSnapshotID: candidate.localSnapshotID,
                                                  remoteSnapshotID: candidate.remoteSnapshotID, sourceGeneration: candidate.sourceGeneration)
        await application.setState(workID: workID, localDurability: .saved(generation: checkpoint.generation, snapshotID: checkpoint.snapshotID),
                                   remoteProgress: .needsChoice, result: .conflictPending, conflict: .set(projection))
        return workID
    }
}

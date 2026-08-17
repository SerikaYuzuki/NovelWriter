import Foundation
import NovelCore
import NovelSyncV2
@testable import NovelSyncV2Application
@testable import NovelSyncV2Runtime
@testable import NovelSyncV2Store
import Testing

@Suite("Snapshot Sync v2 production inbox boundaries")
struct ProductionInboxIsolationTests {
    @Test("wrong-work inbox is rejected before any local staging")
    func wrongWorkInboxDoesNotChangeEitherWork() async throws {
        let configuration = try TestRuntimeConfiguration()
        let fixture = try await seedProductionConflict(configuration: configuration)
        let store = try LocalSyncV2Store(root: configuration.localRoot.url, policy: .openExisting)
        let targetWorkID = WorkID(UUID())
        let targetDocumentID = UUID()
        let targetDocument = applicationTestDocument(id: targetDocumentID, title: "受信対象")
        let targetBase = try encodedProductionSnapshot(
            workID: targetWorkID,
            documentID: targetDocumentID,
            title: "受信対象の基準",
            body: "基準"
        )
        let targetBaseInbox = try V2RemoteSnapshot(
            workID: targetWorkID,
            encoded: targetBase,
            expectedCurrentSnapshotID: nil,
            expectedLocalGeneration: 0,
            expectedRemoteHead: V2RemoteHead(
                snapshotID: targetBase.snapshotId,
                generation: 1
            )
        )
        try await store.stageRemote(targetBaseInbox, scope: productionScope)
        try await store.verifyInbox(inboxID: targetBaseInbox.inboxID, scope: productionScope)
        try await store.adoptInbox(inboxID: targetBaseInbox.inboxID, scope: productionScope)
        let checkpoint = try await store.checkpoint(
            V2CheckpointRequest(
                workID: targetWorkID,
                document: targetDocument,
                documentCreatedAt: applicationTestCreatedAt,
                expectedGeneration: 1,
                reason: .explicit
            ),
            scope: productionScope
        )
        let publish = try productionPublishCommand(
            workID: targetWorkID,
            checkpoint: checkpoint,
            expectedHead: V2RemoteHead(snapshotID: targetBase.snapshotId, generation: 1)
        )
        let checkpointIntentID = try #require(checkpoint.intentID)
        try await store.seal(
            publish,
            intentID: checkpointIntentID,
            scope: productionScope
        )
        let beforeWorks = try await store.listWorks(scope: productionScope)

        await configuration.remote.setCommandHandler { command in
            let execution = try productionExecution(command, fixture: fixture)
            guard command.kind == .publish else { return execution }
            guard case let .command(receipt, _) = execution else { return execution }
            let wrongWorkID = WorkID(UUID())
            let wrongHead = try SyncV2RemoteHead(
                snapshotID: fixture.remoteHead.snapshotID,
                generation: fixture.remoteHead.generation
            )
            let wrongInbox = SyncV2RemoteInbox(
                inboxID: UUID(),
                workID: wrongWorkID,
                headSnapshotID: fixture.remote.snapshotId,
                snapshots: [fixture.remote],
                expectedCurrentSnapshotID: nil,
                expectedLocalGeneration: 0,
                expectedRemoteHead: wrongHead
            )
            return .command(receipt: receipt, remoteInbox: wrongInbox)
        }

        let app = try await SnapshotSyncV2Runtime.makeApplication(mode: .test(configuration))
        _ = try await app.open(workID: targetWorkID)
        try await app.resumePending()
        try await eventually {
            await configuration.remote.recordedOperations().contains {
                commandKind($0) == .publish
            }
        }
        #expect(await app.uiState(workID: targetWorkID)?.lastFailure == .receiptMismatch)

        let afterWorks = try await store.listWorks(scope: productionScope)
        #expect(afterWorks.map(\.workID) == beforeWorks.map(\.workID))
        let target = try await store.open(workID: targetWorkID, scope: productionScope)
        #expect(target.summary.currentSnapshotID == checkpoint.snapshotID)
        #expect(try await store.listWorks(scope: .unbound).isEmpty)
    }
}

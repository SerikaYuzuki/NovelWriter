import Foundation
import NovelCore
import NovelSyncV2
@testable import NovelSyncV2Application
@testable import NovelSyncV2Runtime
@testable import NovelSyncV2Store
import Testing

extension ProductionRestartTests {
    @Test("keep-both blocks a newer publish until clone acknowledgement, including restart")
    func keepBothBlocksNewerPublishUntilCloneAcknowledgement() async throws {
        let configuration = try TestRuntimeConfiguration()
        let fixture = try await seedProductionConflict(configuration: configuration)
        await configuration.remote.setBehaviors([.suspended])
        let store = try LocalSyncV2Store(root: configuration.localRoot.url, policy: .openExisting)
        let app = try await SnapshotSyncV2Runtime.makeApplication(mode: .test(configuration))
        let opened = try await app.open(workID: fixture.workID)
        _ = try await app.checkpoint(
            workID: fixture.workID,
            document: applicationTestDocument(
                id: #require(opened.document?.id), title: "解決待ちの追加入力", body: "後続編集"
            ),
            reason: .explicit, documentCreatedAt: applicationTestCreatedAt
        )
        let newerIntent = try #require(try await store.pendingIntents(scope: productionScope, workID: fixture.workID)
            .first { $0.kind == "checkpoint" && $0.sourceGeneration > fixture.sourceGeneration })
        let conflict = try #require(try await store.activeConflict(workID: fixture.workID, scope: productionScope))
        let result = try await app.resolveConflict(workID: fixture.workID, action: SyncV2ConflictAction(
            workID: fixture.workID, conflictID: conflict.conflictID, revision: conflict.revision,
            baseSnapshotID: conflict.baseSnapshotID, localSnapshotID: conflict.localSnapshotID,
            remoteSnapshotID: conflict.remoteSnapshotID, sourceGeneration: conflict.sourceGeneration,
            choice: .keepBoth, inboxID: store.conflictInbox(conflict)
        ))
        let clone = try #require(result.openedWork)
        try await app.resumePending()
        try await eventually {
            await configuration.remote.recordedOperations().contains { commandKind($0) == .cloneWork }
        }
        for _ in 0 ..< 3 {
            try await app.resumePending()
            try await assertKeepBothWaiting(store: store, fixture: fixture, cloneID: clone.workID, remote: configuration.remote)
        }
        // Cancellation cannot force a suspended transport to return. The
        // restarted worker must replay the clone, never bypass its receipt.
        await app.cancelWorker(for: fixture.workID)
        let restarted = try await SnapshotSyncV2Runtime.makeApplicationForTesting(
            mode: .test(configuration), resumeOnLaunch: false
        )
        try await restarted.resumePending()
        try await eventually {
            await configuration.remote.recordedOperations().count { commandKind($0) == .cloneWork } >= 2
        }
        for _ in 0 ..< 3 {
            try await restarted.resumePending()
            try await assertKeepBothWaiting(store: store, fixture: fixture, cloneID: clone.workID, remote: configuration.remote)
        }
        let publishGate = ProductionPublishGate()
        await installProductionResponder(configuration.remote, fixture: fixture, publishGate: publishGate)
        await configuration.remote.resumeSuspended()
        try await restarted.resumePending()
        try await eventually {
            await configuration.remote.recordedOperations().contains { commandKind($0) == .publish }
        }
        let records = try await store.allSealedCommands(scope: productionScope, workID: fixture.workID)
        let cloneCommand = try #require(records.first { $0.commandKind == "cloneWork" })
        #expect(cloneCommand.lifecycle == .completed)
        let reservation = try #require(try await store.keepBothReservation(
            sourceWorkID: fixture.workID, newWorkID: clone.workID, scope: productionScope
        ))
        #expect(reservation.state == "finalized")
        #expect(records.first { $0.commandKind == "publish" && $0.sourceGeneration == newerIntent.sourceGeneration }?.intentID == newerIntent.intentID)
        let operations = await configuration.remote.recordedOperations()
        let cloneReplays = operations.compactMap(sealedCommand).filter { $0.kind == .cloneWork }
        #expect(cloneReplays.count >= 3)
        #expect(cloneReplays.allSatisfy { $0.command.commandId == cloneCommand.commandID })
        #expect(cloneReplays.allSatisfy { $0.command.canonicalBytes == cloneCommand.canonicalRequest })
        await restarted.cancelWorker(for: fixture.workID)
        await store.close()
    }
}

private func assertKeepBothWaiting(
    store: LocalSyncV2Store,
    fixture: ProductionConflictFixture,
    cloneID: WorkID,
    remote: FakeSyncV2RemoteClient
) async throws {
    #expect(try await store.activeConflict(workID: fixture.workID, scope: productionScope) != nil)
    let reservation = try #require(try await store.keepBothReservation(
        sourceWorkID: fixture.workID, newWorkID: cloneID, scope: productionScope
    ))
    #expect(reservation.state == "sealed")
    let records = try await store.allSealedCommands(scope: productionScope, workID: fixture.workID)
    #expect(records.allSatisfy { $0.commandKind != "publish" || $0.sourceGeneration <= fixture.sourceGeneration })
    #expect(records.first { $0.commandKind == "cloneWork" }?.lifecycle == .sending)
    #expect(await remote.recordedOperations().allSatisfy { commandKind($0) != .publish })
}

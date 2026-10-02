import Foundation
import NovelCore
import NovelSyncV2
@testable import NovelSyncV2Application
@testable import NovelSyncV2Runtime
@testable import NovelSyncV2Store
import Testing

@Suite("D-106 priority history")
struct PriorityBackfillTests {
    @Test func restoreUnfetchedVersionAfterPriorityFetch() async throws {
        let fixture = try await PriorityHistoryFixture.make()
        defer { fixture.cleanup() }
        let selected = fixture.snapshots[0]
        #expect(try await fixture.app.historySnapshotAvailability(workID: fixture.workID, snapshotID: selected.snapshotId) == .unfetched)
        await #expect(throws: SyncV2Failure.retryable(.historyIncomplete)) {
            try await fixture.app.restore(workID: fixture.workID, snapshotID: selected.snapshotId)
        }
        try await eventually { await fixture.remote.started == 1 }
        #expect(try await fixture.store.open(workID: fixture.workID, scope: productionScope).summary.currentSnapshotID == fixture.head.snapshotId)
        await fixture.remote.release()
        try await eventually { try await fixture.app.historySnapshotAvailability(workID: fixture.workID, snapshotID: selected.snapshotId) == .local }
        // Arrival alone never restores: the normal explicit confirmation calls restore.
        #expect(try await fixture.store.open(workID: fixture.workID, scope: productionScope).summary.currentSnapshotID == fixture.head.snapshotId)
        _ = try await fixture.app.restore(workID: fixture.workID, snapshotID: selected.snapshotId)
        let expected = try SnapshotCodec.decode(manifestBytes: selected.manifestBytes, objects: selected.objects)
        #expect(try await fixture.store.open(workID: fixture.workID, scope: productionScope).document?.title == expected.document.title)
        #expect(try await fixture.store.pendingIntents(scope: productionScope, workID: fixture.workID).count == 1)
        _ = await fixture.app.beginAccountTransitionRemoteSuspension()
        await fixture.store.close()
    }

    @Test func constrainedAndOfflineRequireExplicitConsent() async throws {
        let fixture = try await PriorityHistoryFixture.make()
        defer { fixture.cleanup() }
        await fixture.app.setHistoryBackfillNetwork(online: false, constrained: false)
        #expect(try await fixture.app.historyFetchState(workID: fixture.workID) == .offline)
        #expect(try await fixture.app.fetchHistoryNow(workID: fixture.workID, allowConstrained: true) == .offline)
        await fixture.app.setHistoryBackfillNetwork(online: true, constrained: true)
        #expect(try await fixture.app.historyFetchState(workID: fixture.workID) == .constrained)
        #expect(try await fixture.app.fetchHistoryNow(workID: fixture.workID) == .needsNetworkConfirmation)
        #expect(await fixture.remote.started == 0)
        #expect(try await fixture.app.fetchHistoryNow(workID: fixture.workID, allowConstrained: true) == .queued)
        try await eventually { await fixture.remote.started == 1 }
        #expect(await fixture.remote.manualRequests == [true])
        #expect(await fixture.remote.constrainedPermissions == [true])
        await fixture.remote.release()
        try await eventually { try await fixture.app.historyFetchState(workID: fixture.workID) == .complete }
        await fixture.store.close()
    }

    @Test func switchingToCostlyNetworkRevokesUnconfirmedManualFetch() async throws {
        let fixture = try await PriorityHistoryFixture.make()
        defer { fixture.cleanup() }
        _ = try await fixture.app.fetchHistoryNow(workID: fixture.workID)
        try await eventually { await fixture.remote.started == 1 }
        #expect(await fixture.remote.constrainedPermissions == [false])
        await fixture.app.setHistoryBackfillNetwork(online: true, constrained: true)
        try await eventually { await fixture.app.backfillTask == nil }
        #expect(try await fixture.app.historyFetchState(workID: fixture.workID) == .constrained)
        #expect(try await fixture.app.fetchHistoryNow(workID: fixture.workID) == .needsNetworkConfirmation)
        _ = try await fixture.app.fetchHistoryNow(workID: fixture.workID, allowConstrained: true)
        try await eventually { await fixture.remote.started == 2 }
        #expect(await fixture.remote.constrainedPermissions == [false, true])
        await fixture.remote.release()
        try await eventually { try await fixture.app.historyFetchState(workID: fixture.workID) == .complete }
        await fixture.store.close()
    }

    @Test func validationFailureNeverAutoRetriesButManualRetryWorks() async throws {
        let fixture = try await PriorityHistoryFixture.make()
        defer { fixture.cleanup() }
        try await fixture.store.setBackfillStatus(workID: fixture.workID, binding: productionBinding, status: .failed, failureCode: "invalidRemoteData")
        _ = await fixture.app.record(failure: .retryable(.historyIncomplete), workID: fixture.workID)
        try await eventually { await fixture.app.backfillTask == nil }
        try await fixture.app.resumePending()
        await fixture.app.setHistoryBackfillNetwork(online: true, constrained: false)
        #expect(await fixture.remote.started == 0)
        #expect(try await fixture.app.historyFetchState(workID: fixture.workID) == .validationFailed)
        #expect(try await fixture.app.fetchHistoryNow(workID: fixture.workID) == .queued)
        try await eventually { await fixture.remote.started == 1 }
        await fixture.remote.release()
        try await eventually { try await fixture.app.historyFetchState(workID: fixture.workID) == .complete }
        await fixture.store.close()
    }

    @Test func deepParentMergeWaitsThenAdopts() async throws {
        let fixture = try await PriorityHistoryFixture.make()
        defer { fixture.cleanup() }
        let model = try SnapshotCodec.decode(manifestBytes: fixture.head.manifestBytes, objects: fixture.head.objects)
        var document = model.document
        document.title = "合流後"
        let deepParent = try #require(fixture.snapshots.first { $0.snapshotId != fixture.head.snapshotId && !fixture.head.manifest.parentSnapshotIds.contains($0.snapshotId) })
        let merge = try SnapshotCodec.encode(SnapshotModel(workId: fixture.workID, document: document, documentCreatedAt: model.documentCreatedAt),
                                             parents: [fixture.head.snapshotId, deepParent.snapshotId].sorted { $0.rawValue < $1.rawValue })
        let graph = V2RemoteSnapshotGraph(workID: fixture.workID, headSnapshotID: merge.snapshotId, snapshots: [merge],
                                          expectedCurrentSnapshotID: fixture.head.snapshotId, expectedLocalGeneration: 1,
                                          expectedRemoteHead: V2RemoteHead(validatedSnapshotID: merge.snapshotId, generation: 2))
        await #expect(throws: SyncV2StoreError.historyIncomplete) { try await fixture.store.stageRemoteGraph(graph, scope: productionScope) }
        let remote = try ReceiptHistoryRemote(backfill: fixture.remote, reply: .noChanges(inbox: fixture.inbox(graph)))
        let app = try fixture.workerApp(remote: remote)
        await app.scheduleWorker(for: fixture.workID)
        try await eventually { await app.uiState(workID: fixture.workID)?.remoteProgress == .retryable(.historyIncomplete) }
        #expect(try await fixture.store.open(workID: fixture.workID, scope: productionScope).summary.currentSnapshotID == fixture.head.snapshotId)
        await fixture.remote.release()
        try await eventually { await app.uiState(workID: fixture.workID)?.remoteProgress == .noChanges }
        try await fixture.store.adoptInbox(inboxID: graph.inboxID, scope: productionScope)
        #expect(try await fixture.store.open(workID: fixture.workID, scope: productionScope).document?.title == "合流後")
        #expect(await remote.attempts >= 2)
        _ = await app.beginAccountTransitionRemoteSuspension()
        await fixture.store.close()
    }

    @Test func conflictWithOldBaseWaitsThenSucceeds() async throws {
        let fixture = try await PriorityHistoryFixture.make()
        defer { fixture.cleanup() }
        let model = try SnapshotCodec.decode(manifestBytes: fixture.head.manifestBytes, objects: fixture.head.objects)
        var document = model.document
        document.title = "競合のサーバー版"
        // Parent is the immediate boundary, but the proposed base lies deeper.
        let remoteSnapshot = try SnapshotCodec.encode(SnapshotModel(workId: fixture.workID, document: document, documentCreatedAt: model.documentCreatedAt),
                                                      parents: fixture.head.manifest.parentSnapshotIds)
        let graph = V2RemoteSnapshotGraph(workID: fixture.workID, headSnapshotID: remoteSnapshot.snapshotId, snapshots: [remoteSnapshot],
                                          expectedCurrentSnapshotID: fixture.head.snapshotId, expectedLocalGeneration: 1,
                                          expectedRemoteHead: V2RemoteHead(validatedSnapshotID: remoteSnapshot.snapshotId, generation: 2))
        try await fixture.store.stageRemoteGraph(graph, scope: productionScope)
        try await fixture.store.verifyInbox(inboxID: graph.inboxID, scope: productionScope)
        let candidate = V2ConflictCandidate(conflictID: UUID(), revision: 1, workID: fixture.workID,
                                            baseSnapshotID: fixture.snapshots[0].snapshotId, localSnapshotID: fixture.head.snapshotId,
                                            remoteSnapshotID: remoteSnapshot.snapshotId, sourceGeneration: 1)
        let conflict = SyncV2ConflictProjection(conflictID: candidate.conflictID, revision: candidate.revision,
                                                baseSnapshotID: candidate.baseSnapshotID, localSnapshotID: candidate.localSnapshotID,
                                                remoteSnapshotID: candidate.remoteSnapshotID, sourceGeneration: candidate.sourceGeneration)
        let remote = try ReceiptHistoryRemote(backfill: fixture.remote, reply: .conflict(conflict, inbox: fixture.inbox(graph)))
        let app = try fixture.workerApp(remote: remote, expectedHead: candidate.baseSnapshotID)
        await app.scheduleWorker(for: fixture.workID)
        try await eventually { await app.uiState(workID: fixture.workID)?.remoteProgress == .retryable(.historyIncomplete) }
        #expect(try await fixture.store.activeConflict(workID: fixture.workID, scope: productionScope) == nil)
        await fixture.remote.release()
        try await eventually { try await fixture.store.activeConflict(workID: fixture.workID, scope: productionScope)?.conflictID == candidate.conflictID }
        #expect(try await fixture.store.open(workID: fixture.workID, scope: productionScope).summary.currentSnapshotID == fixture.head.snapshotId)
        try await eventually { await app.uiState(workID: fixture.workID)?.remoteProgress == .needsChoice }
        _ = await app.beginAccountTransitionRemoteSuspension()
        await fixture.store.close()
    }
}

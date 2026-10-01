import Foundation
import NovelCore
import NovelSyncV2
@testable import NovelSyncV2Application
@testable import NovelSyncV2Runtime
import NovelSyncV2Store
import Testing

@Suite("Explicit production sync")
struct ExplicitSyncIntegrationTests {
    @Test("manual and automatic sync receive a remote descendant through the document gate", arguments: [false, true])
    func unchangedWorkReceivesRemoteUpdate(automatic: Bool) async throws {
        let configuration = try TestRuntimeConfiguration()
        let workID = WorkID(UUID())
        let document = applicationTestDocument(title: "local")
        let local = try SnapshotCodec.encode(SnapshotModel(
            workId: workID, document: document, documentCreatedAt: applicationTestCreatedAt
        ), parents: [])
        var updated = document
        updated.title = "remote update"
        let remote = try SnapshotCodec.encode(SnapshotModel(
            workId: workID, document: updated, documentCreatedAt: applicationTestCreatedAt
        ), parents: [local.snapshotId])
        let remoteHead = try V2RemoteHead(snapshotID: remote.snapshotId, generation: 2)
        let fixture = ProductionConflictFixture(
            workID: workID, baseSnapshotID: local.snapshotId, localSnapshotID: local.snapshotId,
            sourceGeneration: 1, remote: remote, remoteHead: remoteHead
        )
        let store = try LocalSyncV2Store(root: configuration.localRoot.url, policy: .createNew)
        let seed = try V2RemoteSnapshot(
            workID: workID, encoded: local, expectedCurrentSnapshotID: nil, expectedLocalGeneration: 0,
            expectedRemoteHead: V2RemoteHead(snapshotID: local.snapshotId, generation: 1)
        )
        try await store.stageRemote(seed, scope: productionScope)
        try await store.verifyInbox(inboxID: seed.inboxID, scope: productionScope)
        try await store.adoptInbox(inboxID: seed.inboxID, scope: productionScope)
        #expect(try await store.pendingIntents(scope: productionScope).isEmpty)
        await configuration.remote.setCommandHandler { command in
            if command.kind != .publish {
                return try productionExecution(command, fixture: fixture)
            }
            return try Self.unchangedReceipt(command, workID: workID, remote: remote, local: local)
        }
        let app = try await SnapshotSyncV2Runtime.makeApplication(mode: .test(configuration))
        _ = try await app.openLocal(workID: workID)
        if automatic {
            try await eventually { await app.lanes[workID]?.workerTask == nil }
            await configuration.remote.setHeadHandler { _ in throw SyncV2Failure.offline }
            await #expect(throws: SyncV2Failure.offline) {
                try await app.checkForRemoteUpdates(workID: workID)
            }
            #expect(await app.uiState(workID: workID)?.remoteProgress == .offline)
            #expect(try await store.pendingIntents(scope: productionScope).isEmpty)
            await configuration.remote.setHeadHandler { _ in
                try SyncV2RemoteHead(snapshotID: local.snapshotId, generation: 1)
            }
            #expect(try await !app.checkForRemoteUpdates(workID: workID))
            #expect(await app.uiState(workID: workID)?.remoteProgress == .noChanges)
            #expect(await configuration.remote.recordedOperations().isEmpty)
            #expect(try await store.pendingIntents(scope: productionScope).isEmpty)
            await configuration.remote.setHeadHandler { _ in
                try SyncV2RemoteHead(snapshotID: remote.snapshotId, generation: 2)
            }
            #expect(try await app.checkForRemoteUpdates(workID: workID))
        } else {
            let result = try await app.synchronize(workID: workID)
            #expect(result.typedResult == .queued)
        }
        try await eventually { try await app.pendingAdoption(workID: workID) != nil }
        #expect(try await store.open(workID: workID, scope: productionScope).document == document)
        let pending = try #require(try await app.pendingAdoption(workID: workID))
        #expect(pending.conflictID == nil)
        let session = await app.beginSession(workID: workID)
        let gate = try await app.documentGateToken(for: session)
        let adopted = try await app.applyStagedRemote(at: SafeAdoptionBoundary(
            workID: workID, inboxID: pending.inboxID, session: session, gate: gate
        ))
        #expect(adopted.document == updated)
        #expect(try await app.pendingAdoption(workID: workID) == nil)
        if automatic {
            try await eventually { await app.lanes[workID]?.workerTask == nil }
            let count = await configuration.remote.recordedOperations().count
            #expect(try await !app.checkForRemoteUpdates(workID: workID))
            #expect(await app.uiState(workID: workID)?.remoteProgress == .noChanges)
            #expect(await configuration.remote.recordedOperations().count == count)
        }
        await store.close()
    }

    private static func unchangedReceipt(
        _ sealed: SyncV2SealedRemoteCommand, workID: WorkID,
        remote: EncodedSnapshot, local: EncodedSnapshot
    ) throws -> SyncV2RemoteExecution {
        let command = sealed.command
        let head = try V2RemoteHead(snapshotID: remote.snapshotId, generation: 2)
        let response = try productionResponse(command: command, result: .noChanges, head: head, cloneHead: nil, status: 200)
        let envelope = try productionEnvelope(command: command, response: response, result: .noChanges, status: 200)
        let remoteHead = try SyncV2RemoteHead(snapshotID: remote.snapshotId, generation: 2)
        return .command(receipt: SyncV2ReceiptReadback(
            commandID: command.commandId, requestDigest: command.requestDigest, responseStatus: 200,
            canonicalResponse: envelope,
            predicates: SyncV2ReadBackPredicates(accountMatched: true, commandDigestMatched: true, resourceMatched: true, headMatched: true, stateMatched: true),
            result: .noChanges, remoteHead: remoteHead
        ), remoteInbox: SyncV2RemoteInbox(
            inboxID: UUID(), workID: workID, headSnapshotID: remote.snapshotId, snapshots: [local, remote],
            expectedCurrentSnapshotID: command.sourceSnapshotId, expectedLocalGeneration: command.sourceGeneration,
            expectedRemoteHead: remoteHead
        ))
    }
}

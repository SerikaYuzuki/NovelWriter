import Foundation
import NovelSyncV2
@testable import NovelSyncV2Store
import Testing

@Test
func editingBeforeRemoteAdoptionUsesAncestralHeadAndRecoversLegacyRejection() async throws {
    let root = temporaryStoreRoot("publish-base-recovery")
    defer { try? FileManager.default.removeItem(at: root) }
    let store = try LocalSyncV2Store(root: root, policy: .createNew)
    let workID = WorkID(UUID())
    let document = makeDocument(title: "base")
    let base = try await store.checkpoint(V2CheckpointRequest(
        workID: workID, document: document, documentCreatedAt: testDate, expectedGeneration: 0
    ), scope: scopeA)
    let baseHead = try V2RemoteHead(snapshotID: base.snapshotID, generation: 1)
    let first = try publishCommand(workID: workID, checkpoint: base)
    try await store.seal(first, intentID: base.intentID, scope: scopeA)
    try await store.acknowledge(commandAcknowledgement(first, head: baseHead), scope: scopeA)
    try await store.requestSynchronization(workID: workID, scope: scopeA)
    let pending = try #require(await store.pendingIntents(scope: scopeA).first)
    let probe = try publishCommand(workID: workID, checkpoint: base, expectedHead: baseHead)
    try await store.seal(probe, intentID: pending.intentID, scope: scopeA)

    var edited = document
    edited.title = "offline edit"
    let local = try await store.checkpoint(V2CheckpointRequest(
        workID: workID, document: edited, documentCreatedAt: testDate, expectedGeneration: base.generation
    ), scope: scopeA)
    var remoteDocument = document
    remoteDocument.title = "other device edit"
    let remote = try encodeSnapshot(workID: workID, document: remoteDocument, parents: [base.snapshotID])
    let remoteHead = try V2RemoteHead(snapshotID: remote.snapshotId, generation: 2)
    let graph = V2RemoteSnapshotGraph(
        workID: workID, headSnapshotID: remote.snapshotId, snapshots: [remote],
        expectedCurrentSnapshotID: base.snapshotID, expectedLocalGeneration: base.generation,
        expectedRemoteHead: remoteHead
    )
    try await store.stageRemoteGraph(graph, scope: scopeA)
    try await store.verifyInbox(inboxID: graph.inboxID, scope: scopeA)
    try await store.acknowledge(commandAcknowledgement(probe, result: .noChanges, head: remoteHead),
                                scope: scopeA, verifiedPublishInboxID: graph.inboxID)
    #expect(try await store.immutableTransferView(workID: workID, scope: scopeA)?.expectedRemoteHead == baseHead)

    let corrected = try publishCommand(workID: workID, checkpoint: local, expectedHead: baseHead)
    try await store.seal(corrected, intentID: local.intentID, scope: scopeA)
    let legacy = try publishCommand(workID: workID, checkpoint: local, expectedHead: remoteHead,
                                    commandID: corrected.commandId)
    // Seed only the isolated test DB with the old release's sealed request.
    try await store.exec("UPDATE sealed_commands SET canonical_request=?,request_digest=? WHERE command_id=?",
                         [.blob(legacy.canonicalBytes), .blob(legacy.requestDigest.bytes),
                          .text(legacy.commandId.uuidString.lowercased())])
    _ = try await store.markSending(commandID: legacy.commandId, scope: scopeA)
    try await store.replanRejectedPublish(commandID: legacy.commandId, scope: scopeA)
    let records = try await store.allSealedCommands(scope: scopeA, workID: workID)
    let preserved = try #require(records.first { $0.commandID == legacy.commandId })
    #expect(preserved.canonicalRequest == legacy.canonicalBytes)
    #expect(preserved.lifecycle == .quarantined)
    #expect(try await store.open(workID: workID, scope: scopeA).document == edited)
    let next = try #require(await store.immutableTransferView(workID: workID, scope: scopeA))
    #expect(next.expectedRemoteHead == baseHead)
    #expect(next.pendingIntent.intentID != local.intentID)
    let replacement = try publishCommand(workID: workID, checkpoint: local, expectedHead: baseHead)
    try await store.seal(replacement, intentID: next.pendingIntent.intentID, scope: scopeA)
    // An unproven failure or an unchanged base must never create a retry loop.
    _ = try await store.markSending(commandID: replacement.commandId, scope: scopeA)
    await #expect(throws: SyncV2StoreError.invalidCommand) {
        try await store.replanRejectedPublish(commandID: replacement.commandId, scope: scopeA)
    }
    await store.close()
}

@Test
func remoteConflictPreservesVerifiedGraphBaseAndServerIdentity() async throws {
    let root = temporaryStoreRoot("remote-conflict-identity")
    defer { try? FileManager.default.removeItem(at: root) }
    let store = try LocalSyncV2Store(root: root, policy: .createNew)
    let workID = WorkID(UUID())
    let document = makeDocument(title: "base")
    let base = try await store.checkpoint(V2CheckpointRequest(
        workID: workID, document: document, documentCreatedAt: testDate, expectedGeneration: 0
    ), scope: scopeA)
    var edited = document
    edited.title = "local"
    let local = try await store.checkpoint(V2CheckpointRequest(
        workID: workID, document: edited, documentCreatedAt: testDate, expectedGeneration: base.generation
    ), scope: scopeA)
    var remoteDocument = document
    remoteDocument.title = "remote first"
    let parent = try encodeSnapshot(workID: workID, document: remoteDocument, parents: [base.snapshotID])
    remoteDocument.title = "remote second"
    let remote = try encodeSnapshot(workID: workID, document: remoteDocument, parents: [parent.snapshotId])
    let graph = try V2RemoteSnapshotGraph(
        workID: workID, headSnapshotID: remote.snapshotId, snapshots: [parent, remote],
        expectedCurrentSnapshotID: local.snapshotID, expectedLocalGeneration: local.generation,
        expectedRemoteHead: V2RemoteHead(snapshotID: remote.snapshotId, generation: 3)
    )
    try await store.stageRemoteGraph(graph, scope: scopeA)
    let identity = UUID()
    await #expect(throws: SyncV2StoreError.self) {
        try await store.appendConflictFromVerifiedInbox(
            V2ConflictCandidate(
                conflictID: identity, revision: 2, workID: workID,
                baseSnapshotID: base.snapshotID, localSnapshotID: local.snapshotID,
                remoteSnapshotID: remote.snapshotId, sourceGeneration: local.generation
            ), inboxID: graph.inboxID, scope: scopeA
        )
    }
    try await store.verifyInbox(inboxID: graph.inboxID, scope: scopeA)
    for _ in 0 ..< 2 {
        let conflict = try await store.appendConflictFromVerifiedInbox(
            V2ConflictCandidate(
                conflictID: identity, revision: 2, workID: workID,
                baseSnapshotID: base.snapshotID, localSnapshotID: local.snapshotID,
                remoteSnapshotID: remote.snapshotId, sourceGeneration: local.generation
            ), inboxID: graph.inboxID, scope: scopeA
        )
        #expect(conflict.conflictID == identity)
        #expect(conflict.revision == 2)
        #expect(conflict.baseSnapshotID == base.snapshotID)
    }
    await #expect(throws: SyncV2StoreError.staleConflictAction) {
        try await store.appendConflictFromVerifiedInbox(
            V2ConflictCandidate(
                conflictID: UUID(), revision: 2, workID: workID,
                baseSnapshotID: base.snapshotID, localSnapshotID: local.snapshotID,
                remoteSnapshotID: remote.snapshotId, sourceGeneration: local.generation
            ), inboxID: graph.inboxID, scope: scopeA
        )
    }
    #expect(try await store.open(workID: workID, scope: scopeA).document == edited)
    await store.close()
}

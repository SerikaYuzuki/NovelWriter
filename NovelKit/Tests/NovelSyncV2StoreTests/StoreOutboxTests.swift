import Foundation
import NovelCore
import NovelSyncV2
import NovelSyncV2Store
import Testing

@Test
func publishNoChangesRequiresVerifiedLineageAndAcknowledgesExactIntent() async throws {
    let root = temporaryStoreRoot("publish-lineage-nochanges")
    defer { try? FileManager.default.removeItem(at: root) }
    let workID = WorkID(UUID())
    let document = makeDocument(title: "candidate")
    let store = try LocalSyncV2Store(root: root, policy: .createNew)
    let checkpoint = try await store.checkpoint(
        V2CheckpointRequest(
            workID: workID,
            document: document,
            documentCreatedAt: testDate,
            expectedGeneration: 0
        ),
        scope: scopeA
    )
    let command = try publishCommand(workID: workID, checkpoint: checkpoint)
    try await store.seal(command, intentID: checkpoint.intentID, scope: scopeA)
    var remoteDocument = document
    remoteDocument.title = "remote descendant"
    let remote = try encodeSnapshot(
        workID: workID,
        document: remoteDocument,
        parents: [checkpoint.snapshotID]
    )
    let graph = try V2RemoteSnapshotGraph(
        workID: workID,
        headSnapshotID: remote.snapshotId,
        snapshots: [remote],
        expectedCurrentSnapshotID: checkpoint.snapshotID,
        expectedLocalGeneration: checkpoint.generation,
        expectedRemoteHead: V2RemoteHead(snapshotID: remote.snapshotId, generation: 2)
    )
    try await store.stageRemoteGraph(graph, scope: scopeA)
    try await store.verifyInbox(inboxID: graph.inboxID, scope: scopeA)
    let acknowledgement = try commandAcknowledgement(
        command,
        result: .noChanges,
        head: graph.expectedRemoteHead
    )
    do {
        try await store.acknowledge(acknowledgement, scope: scopeA)
        Issue.record("publish noChanges accepted without a verified Inbox graph")
    } catch SyncV2StoreError.invalidAcknowledgement {}
    #expect(try await store.pendingSealedCommands(scope: scopeA).count == 1)
    #expect(try await store.pendingIntents(scope: scopeA).count == 1)

    try await store.acknowledge(
        acknowledgement,
        scope: scopeA,
        verifiedPublishInboxID: graph.inboxID
    )
    try await store.acknowledge(
        acknowledgement,
        scope: scopeA,
        verifiedPublishInboxID: graph.inboxID
    )
    #expect(try await store.pendingSealedCommands(scope: scopeA).isEmpty)
    #expect(try await store.pendingIntents(scope: scopeA).isEmpty)
    #expect(try await store.receiptReadback(commandID: command.commandId, scope: scopeA)?.result == .noChanges)
}

@Test
func normalPublishCannotBeSealedWhileConflictIsActive() async throws {
    let root = temporaryStoreRoot("publish-active-conflict")
    defer { try? FileManager.default.removeItem(at: root) }
    let workID = WorkID(UUID())
    let store = try LocalSyncV2Store(root: root, policy: .createNew)
    let fixture = try await createConflict(store: store, workID: workID)
    let command = try publishCommand(workID: workID, checkpoint: fixture.localCheckpoint)
    do {
        try await store.seal(command, intentID: fixture.localCheckpoint.intentID, scope: scopeA)
        Issue.record("normal publish sealed while an active conflict existed")
    } catch SyncV2StoreError.staleConflictAction {}
    #expect(try await store.pendingSealedCommands(scope: scopeA).isEmpty)
}

@Test
func sealedSendingCommandReopensWithExactIdentityAndBytes() async throws {
    let root = temporaryStoreRoot("sealed-restart")
    defer { try? FileManager.default.removeItem(at: root) }
    let workID = WorkID(UUID())
    let document = makeDocument(title: "restart")
    let store = try LocalSyncV2Store(root: root, policy: .createNew)
    let checkpoint = try await store.checkpoint(
        V2CheckpointRequest(
            workID: workID,
            document: document,
            documentCreatedAt: testDate,
            expectedGeneration: 0
        ),
        scope: scopeA
    )
    let command = try publishCommand(workID: workID, checkpoint: checkpoint)
    try await store.seal(command, intentID: checkpoint.intentID, scope: scopeA)
    let sending = try await store.markSending(
        commandID: command.commandId,
        scope: scopeA
    )
    #expect(sending.lifecycle == .sending)
    await store.close()

    let reopened = try LocalSyncV2Store(root: root, policy: .openExisting)
    let pending = try await reopened.pendingSealedCommands(scope: scopeA)
    #expect(pending.count == 1)
    #expect(pending[0].commandID == command.commandId)
    #expect(pending[0].canonicalRequest == command.canonicalBytes)
    #expect(pending[0].requestDigest == command.requestDigest)
    #expect(pending[0].lifecycle == .sending)
    try await reopened.requeue(commandID: command.commandId, scope: scopeA)
    #expect(try await reopened.pendingSealedCommands(scope: scopeA)[0].lifecycle == .sealed)
}

@Test
func sealRequiresClosedIntentAndExactPayloadIdentity() async throws {
    let root = temporaryStoreRoot("seal-validation")
    defer { try? FileManager.default.removeItem(at: root) }
    let workID = WorkID(UUID())
    let document = makeDocument(title: "seal")
    let store = try LocalSyncV2Store(root: root, policy: .createNew)
    let checkpoint = try await store.checkpoint(
        V2CheckpointRequest(
            workID: workID,
            document: document,
            documentCreatedAt: testDate,
            expectedGeneration: 0
        ),
        scope: scopeA
    )
    let publish = try publishCommand(workID: workID, checkpoint: checkpoint)
    do {
        try await store.seal(publish, scope: scopeA)
        Issue.record("publish sealed without its intent")
    } catch SyncV2StoreError.invalidCommand {}
    let transfer = try createWorkCommand(
        workID: workID,
        documentID: document.id,
        checkpoint: checkpoint
    )
    do {
        try await store.seal(transfer, intentID: checkpoint.intentID, scope: scopeA)
        Issue.record("transfer command consumed checkpoint intent")
    } catch SyncV2StoreError.invalidCommand {}
    do {
        try await store.seal(publish, intentID: checkpoint.intentID, scope: .unbound)
        Issue.record("unbound scope sealed a remote command")
    } catch SyncV2StoreError.invalidCommand {}
    try await store.seal(publish, intentID: checkpoint.intentID, scope: scopeA)
    try await store.seal(publish, intentID: checkpoint.intentID, scope: scopeA)
    #expect(try await store.pendingSealedCommands(scope: scopeA).count == 1)
    var newerDocument = document
    newerDocument.title = "new intent"
    let newer = try await store.checkpoint(
        V2CheckpointRequest(
            workID: workID,
            document: newerDocument,
            documentCreatedAt: testDate,
            expectedGeneration: checkpoint.generation
        ),
        scope: scopeA
    )
    do {
        try await store.seal(publish, intentID: newer.intentID, scope: scopeA)
        Issue.record("same command identity was rebound to a different intent")
    } catch SyncV2StoreError.commandAlreadySealed {}
}

@Test
func transferAcknowledgementNeverClearsCheckpointIntent() async throws {
    let root = temporaryStoreRoot("transfer-ack")
    defer { try? FileManager.default.removeItem(at: root) }
    let workID = WorkID(UUID())
    let document = makeDocument(title: "transfer")
    let store = try LocalSyncV2Store(root: root, policy: .createNew)
    let checkpoint = try await store.checkpoint(
        V2CheckpointRequest(
            workID: workID,
            document: document,
            documentCreatedAt: testDate,
            expectedGeneration: 0
        ),
        scope: scopeA
    )
    let command = try createWorkCommand(
        workID: workID,
        documentID: document.id,
        checkpoint: checkpoint
    )
    try await store.seal(command, scope: scopeA)
    do {
        try await store.acknowledge(
            commandAcknowledgement(command, status: 200),
            scope: scopeA
        )
        Issue.record("createWork accepted a non-contract success status")
    } catch SyncV2StoreError.invalidAcknowledgement {}
    do {
        try await store.acknowledge(
            commandAcknowledgement(command, status: 201, result: .noChanges),
            scope: scopeA
        )
        Issue.record("createWork accepted a non-contract terminal result")
    } catch SyncV2StoreError.invalidAcknowledgement {}
    #expect(try await store.receiptReadback(
        commandID: command.commandId,
        scope: scopeA
    ) == nil)
    let acknowledgement = try commandAcknowledgement(command, status: 201)
    try await store.acknowledge(acknowledgement, scope: scopeA)
    try await store.acknowledge(acknowledgement, scope: scopeA)
    #expect(try await store.pendingIntents(scope: scopeA).count == 1)
    let receipt = try await store.receiptReadback(
        commandID: command.commandId,
        scope: scopeA
    )
    #expect(receipt?.result == .applied)
    #expect(receipt?.predicates.allVerified == true)
}

@Test
func parkedAcknowledgementCannotCompleteAReceipt() async throws {
    let root = temporaryStoreRoot("parked-ack")
    defer { try? FileManager.default.removeItem(at: root) }
    let workID = WorkID(UUID())
    let document = makeDocument(title: "parked")
    let store = try LocalSyncV2Store(root: root, policy: .createNew)
    let checkpoint = try await store.checkpoint(
        V2CheckpointRequest(
            workID: workID,
            document: document,
            documentCreatedAt: testDate,
            expectedGeneration: 0
        ),
        scope: scopeA
    )
    let command = try createWorkCommand(
        workID: workID,
        documentID: document.id,
        checkpoint: checkpoint
    )
    try await store.seal(command, scope: scopeA)
    let acknowledgement = try commandAcknowledgement(
        command,
        status: 409,
        result: .parked
    )
    do {
        try await store.acknowledge(acknowledgement, scope: scopeA)
        Issue.record("local parked result completed a remote receipt")
    } catch SyncV2StoreError.invalidAcknowledgement {}
    #expect(try await store.receiptReadback(
        commandID: command.commandId,
        scope: scopeA
    ) == nil)
    #expect(try await store.pendingSealedCommands(scope: scopeA).count == 1)
    #expect(try await store.pendingIntents(scope: scopeA).count == 1)
}

@Test
func incompleteReadbackCannotCompleteAndRemoteHeadIsMonotonic() async throws {
    let root = temporaryStoreRoot("ack-monotonic")
    defer { try? FileManager.default.removeItem(at: root) }
    let workID = WorkID(UUID())
    var document = makeDocument(title: "one")
    let store = try LocalSyncV2Store(root: root, policy: .createNew)
    let first = try await store.checkpoint(
        V2CheckpointRequest(
            workID: workID,
            document: document,
            documentCreatedAt: testDate,
            expectedGeneration: 0
        ),
        scope: scopeA
    )
    let firstCommand = try publishCommand(workID: workID, checkpoint: first)
    try await store.seal(firstCommand, intentID: first.intentID, scope: scopeA)
    try await assertMismatchedPublishHeadRejected(
        store: store,
        command: firstCommand
    )
    let incomplete = try commandAcknowledgement(
        firstCommand,
        head: V2RemoteHead(snapshotID: first.snapshotID, generation: 7),
        predicates: V2ReadBackPredicates(
            accountMatched: true,
            commandDigestMatched: true,
            resourceMatched: true,
            headMatched: false,
            stateMatched: true
        )
    )
    do {
        try await store.acknowledge(incomplete, scope: scopeA)
        Issue.record("incomplete readback completed")
    } catch SyncV2StoreError.invalidAcknowledgement {}
    #expect(try await store.receiptReadback(
        commandID: firstCommand.commandId,
        scope: scopeA
    ) == nil)
    try await store.acknowledge(
        commandAcknowledgement(
            firstCommand,
            head: V2RemoteHead(snapshotID: first.snapshotID, generation: 7)
        ),
        scope: scopeA
    )

    document.title = "two"
    let second = try await store.checkpoint(
        V2CheckpointRequest(
            workID: workID,
            document: document,
            documentCreatedAt: testDate,
            expectedGeneration: 1
        ),
        scope: scopeA
    )
    let expected = try V2RemoteHead(snapshotID: first.snapshotID, generation: 7)
    let secondCommand = try publishCommand(
        workID: workID,
        checkpoint: second,
        expectedHead: expected
    )
    try await store.seal(secondCommand, intentID: second.intentID, scope: scopeA)
    do {
        try await store.acknowledge(
            commandAcknowledgement(
                secondCommand,
                head: V2RemoteHead(
                    snapshotID: second.snapshotID,
                    generation: 7
                )
            ),
            scope: scopeA
        )
        Issue.record("same generation accepted a different head")
    } catch SyncV2StoreError.invalidRemoteHead {}
    #expect(try await store.pendingSealedCommands(scope: scopeA).contains {
        $0.commandID == secondCommand.commandId
    })
}

private func assertMismatchedPublishHeadRejected(
    store: LocalSyncV2Store,
    command: SealedCommand
) async throws {
    let wrongHead = try V2RemoteHead(
        snapshotID: SnapshotID(rawValue: String(repeating: "b", count: 64)),
        generation: 7
    )
    do {
        try await store.acknowledge(
            commandAcknowledgement(command, head: wrongHead),
            scope: scopeA
        )
        Issue.record("publish receipt accepted a different remote snapshot")
    } catch SyncV2StoreError.invalidAcknowledgement {}
}

@Test
func oldAcknowledgementPreservesNewerEditAndIntent() async throws {
    let root = temporaryStoreRoot("newer-edit")
    defer { try? FileManager.default.removeItem(at: root) }
    let workID = WorkID(UUID())
    var document = makeDocument(title: "old")
    let store = try LocalSyncV2Store(root: root, policy: .createNew)
    let first = try await store.checkpoint(
        V2CheckpointRequest(
            workID: workID,
            document: document,
            documentCreatedAt: testDate,
            expectedGeneration: 0
        ),
        scope: scopeA
    )
    let command = try publishCommand(workID: workID, checkpoint: first)
    try await store.seal(command, intentID: first.intentID, scope: scopeA)
    document.title = "newer"
    let newer = try await store.checkpoint(
        V2CheckpointRequest(
            workID: workID,
            document: document,
            documentCreatedAt: testDate,
            expectedGeneration: 1
        ),
        scope: scopeA
    )
    try await store.acknowledge(
        commandAcknowledgement(
            command,
            head: V2RemoteHead(snapshotID: first.snapshotID, generation: 1)
        ),
        scope: scopeA
    )
    let opened = try await store.open(workID: workID, scope: scopeA)
    let pending = try await store.pendingIntents(scope: scopeA)
    #expect(opened.document?.title == "newer")
    #expect(opened.summary.currentSnapshotID == newer.snapshotID)
    #expect(pending.count == 1)
    #expect(pending[0].sourceSnapshotID == newer.snapshotID)
}

@Test
func delayedOlderReceiptAcknowledgesExactIntentWithoutRegressingHead() async throws {
    let root = temporaryStoreRoot("older-receipt-head")
    defer { try? FileManager.default.removeItem(at: root) }
    let workID = WorkID(UUID())
    var document = makeDocument(title: "one")
    let store = try LocalSyncV2Store(root: root, policy: .createNew)
    let first = try await store.checkpoint(
        V2CheckpointRequest(
            workID: workID,
            document: document,
            documentCreatedAt: testDate,
            expectedGeneration: 0
        ),
        scope: scopeA
    )
    let firstCommand = try publishCommand(workID: workID, checkpoint: first)
    try await store.seal(firstCommand, intentID: first.intentID, scope: scopeA)
    document.title = "two"
    let second = try await store.checkpoint(
        V2CheckpointRequest(
            workID: workID,
            document: document,
            documentCreatedAt: testDate,
            expectedGeneration: first.generation
        ),
        scope: scopeA
    )
    #expect(try sqliteExecutionSucceeded(
        databaseURL: root.appendingPathComponent("snapshot-sync-v2.sqlite"),
        sql: "UPDATE works SET acknowledged_head_snapshot_id=X'\(second.snapshotID.rawValue)', acknowledged_head_generation=2 WHERE work_id='\(workID.description)'"
    ))
    try await store.acknowledge(
        commandAcknowledgement(
            firstCommand,
            head: V2RemoteHead(snapshotID: first.snapshotID, generation: 1)
        ),
        scope: scopeA
    )
    let summary = try await store.open(workID: workID, scope: scopeA).summary
    #expect(summary.acknowledgedHeadGeneration == 2)
    #expect(summary.currentSnapshotID == second.snapshotID)
    #expect(try await store.pendingSealedCommands(scope: scopeA).isEmpty)
}

@Test
func fenceRotationQuarantinesAndDifferentAccountParksWithoutRebinding() async throws {
    let root = temporaryStoreRoot("binding-transition")
    defer { try? FileManager.default.removeItem(at: root) }
    let workID = WorkID(UUID())
    let document = makeDocument(title: "scope")
    let store = try LocalSyncV2Store(root: root, policy: .createNew)
    let checkpoint = try await store.checkpoint(
        V2CheckpointRequest(
            workID: workID,
            document: document,
            documentCreatedAt: testDate,
            expectedGeneration: 0
        ),
        scope: scopeA
    )
    let command = try publishCommand(workID: workID, checkpoint: checkpoint)
    try await store.seal(command, intentID: checkpoint.intentID, scope: scopeA)
    _ = try await store.markSending(commandID: command.commandId, scope: scopeA)
    let rotated = V2AccountBinding(
        accountID: bindingA.accountID,
        accountFence: "fence-rotated",
        serverInstanceID: bindingA.serverInstanceID
    )
    try await store.rebindWork(workID: workID, from: bindingA, to: rotated)
    #expect(try await store.listWorks(scope: scopeA).isEmpty)
    #expect(try await store.listWorks(scope: .bound(rotated)).map(\.workID) == [workID])
    #expect(try await store.pendingSealedCommands(scope: scopeA).isEmpty)
    #expect(try await store.pendingIntents(scope: scopeA).isEmpty)

    let anotherAccount = V2AccountBinding(
        accountID: "account-b",
        accountFence: "fence-b",
        serverInstanceID: bindingA.serverInstanceID
    )
    try await store.rebindWork(workID: workID, from: rotated, to: anotherAccount)
    #expect(try await store.listWorks(scope: .bound(rotated)).isEmpty)
    #expect(try await store.listWorks(scope: .bound(anotherAccount)).isEmpty)
    #expect(try await store.listWorks(scope: .unbound).isEmpty)
}

@Test
func invalidRemoteHeadConstructionThrowsInsteadOfTrapping() throws {
    let snapshot = try SnapshotID(rawValue: String(repeating: "a", count: 64))
    #expect(throws: SyncV2StoreError.invalidRemoteHead) {
        _ = try V2RemoteHead(snapshotID: snapshot, generation: 0)
    }
}

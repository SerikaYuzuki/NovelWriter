import Foundation
import NovelCore
import NovelSyncV2
import NovelSyncV2Store
import Testing

@Test
func accountTransitionReplansEveryWorkAndParksDifferentAccountAtomically() async throws {
    let root = temporaryStoreRoot("account-transition-all-works")
    defer { try? FileManager.default.removeItem(at: root) }
    let store = try LocalSyncV2Store(root: root, policy: .createNew)
    let workIDs = [WorkID(UUID()), WorkID(UUID())]
    for workID in workIDs {
        _ = try await store.checkpoint(
            V2CheckpointRequest(
                workID: workID,
                document: makeDocument(title: "work"),
                documentCreatedAt: testDate,
                expectedGeneration: 0
            ),
            scope: scopeA
        )
    }
    let rotated = V2AccountBinding(
        accountID: bindingA.accountID,
        accountFence: "fence-rotated",
        serverInstanceID: bindingA.serverInstanceID
    )
    try await store.transitionAccountScopes(from: bindingA, to: rotated)
    // A lost response after a multi-Work commit must be safely retryable: all
    // active rows may already be at the destination binding.
    try await store.transitionAccountScopes(from: bindingA, to: rotated)
    #expect(try await store.listWorks(scope: scopeA).isEmpty)
    #expect(try await store.listWorks(scope: .bound(rotated)).map(\.workID) == workIDs.sorted {
        $0.description < $1.description
    })
    #expect(try await store.pendingIntents(scope: scopeA).isEmpty)
    #expect(try await store.pendingIntents(scope: .bound(rotated)).count == workIDs.count)

    let other = V2AccountBinding(
        accountID: "account-b",
        accountFence: "fence-b",
        serverInstanceID: bindingA.serverInstanceID
    )
    try await store.transitionAccountScopes(from: rotated, to: other)
    #expect(try await store.listWorks(scope: .bound(rotated)).isEmpty)
    #expect(try await store.listWorks(scope: .bound(other)).isEmpty)
    #expect(try await store.listWorks(scope: .unbound).isEmpty)
    #expect(try await store.listWorks(scope: .parked).map(\.workID) == workIDs.sorted {
        $0.description < $1.description
    })
    #expect(try await store.pendingIntents(scope: .parked).isEmpty)
    for workID in workIDs {
        #expect(try await store.open(workID: workID, scope: .parked).document != nil)
    }
}

@Test
func repeatedAccountTransitionsAreIdempotentAfterCommit() async throws {
    let root = temporaryStoreRoot("account-transition-idempotent")
    defer { try? FileManager.default.removeItem(at: root) }
    let store = try LocalSyncV2Store(root: root, policy: .createNew)
    let workID = WorkID(UUID())
    _ = try await store.checkpoint(
        V2CheckpointRequest(
            workID: workID,
            document: makeDocument(title: "idempotent"),
            documentCreatedAt: testDate,
            expectedGeneration: 0
        ),
        scope: scopeA
    )
    let rotated = V2AccountBinding(
        accountID: bindingA.accountID,
        accountFence: "fence-idempotent",
        serverInstanceID: bindingA.serverInstanceID
    )
    try await store.transitionAccountScopes(from: bindingA, to: rotated)
    try await store.transitionAccountScopes(from: bindingA, to: rotated)
    #expect(try await store.listWorks(scope: .bound(rotated)).map(\.workID) == [workID])

    try await store.transitionAccountScopes(from: rotated, to: nil)
    try await store.transitionAccountScopes(from: rotated, to: nil)
    #expect(try await store.listWorks(scope: .parked).map(\.workID) == [workID])
}

@Test
func exactReauthenticationReactivatesParkedWorkWithFreshIntent() async throws {
    let root = temporaryStoreRoot("account-transition-reactivate")
    defer { try? FileManager.default.removeItem(at: root) }
    let store = try LocalSyncV2Store(root: root, policy: .createNew)
    let workID = WorkID(UUID())
    let first = try await store.checkpoint(
        V2CheckpointRequest(
            workID: workID,
            document: makeDocument(title: "park me"),
            documentCreatedAt: testDate,
            expectedGeneration: 0
        ),
        scope: scopeA
    )
    try await store.transitionAccountScopes(from: bindingA, to: nil)
    #expect(try await store.listWorks(scope: .parked).map(\.workID) == [workID])
    try await store.transitionAccountScopes(from: nil, to: bindingA)
    #expect(try await store.listWorks(scope: scopeA).map(\.workID) == [workID])
    #expect(try await store.listWorks(scope: .parked).isEmpty)
    let pending = try await store.pendingIntents(scope: scopeA, workID: workID)
    #expect(pending.count == 1)
    #expect(pending[0].sourceSnapshotID == first.snapshotID)
    #expect(try await store.pendingIntents(scope: .parked, workID: workID).isEmpty)
}

@Test
func reauthenticationWithNewFenceQuarantinesParkedLaneAndBootstraps() async throws {
    let root = temporaryStoreRoot("account-transition-parked-fence")
    defer { try? FileManager.default.removeItem(at: root) }
    let store = try LocalSyncV2Store(root: root, policy: .createNew)
    let workID = WorkID(UUID())
    _ = try await store.checkpoint(
        V2CheckpointRequest(
            workID: workID,
            document: makeDocument(title: "fenced"),
            documentCreatedAt: testDate,
            expectedGeneration: 0
        ),
        scope: scopeA
    )
    try await store.transitionAccountScopes(from: bindingA, to: nil)
    let rotated = V2AccountBinding(
        accountID: bindingA.accountID,
        accountFence: "fence-new",
        serverInstanceID: bindingA.serverInstanceID
    )
    try await store.transitionAccountScopes(from: nil, to: rotated)
    #expect(try await store.listWorks(scope: .bound(rotated)).map(\.workID) == [workID])
    #expect(try await store.listWorks(scope: .parked).isEmpty)
    #expect(try await store.pendingIntents(scope: .bound(rotated)).count == 1)
    #expect(try await store.pendingIntents(scope: scopeA).isEmpty)
}

@Test
func sameAccountInAnotherServerNamespaceStaysParked() async throws {
    let root = temporaryStoreRoot("account-transition-server-collision")
    defer { try? FileManager.default.removeItem(at: root) }
    let store = try LocalSyncV2Store(root: root, policy: .createNew)
    let workID = WorkID(UUID())
    _ = try await store.checkpoint(
        V2CheckpointRequest(
            workID: workID,
            document: makeDocument(title: "namespace"),
            documentCreatedAt: testDate,
            expectedGeneration: 0
        ),
        scope: scopeA
    )
    try await store.transitionAccountScopes(from: bindingA, to: nil)
    let collision = V2AccountBinding(
        accountID: bindingA.accountID,
        accountFence: "fence-new",
        serverInstanceID: "server-other"
    )
    try await store.transitionAccountScopes(from: nil, to: collision)
    #expect(try await store.listWorks(scope: .parked).map(\.workID) == [workID])
    #expect(try await store.listWorks(scope: .bound(collision)).isEmpty)
}

@Test
func mixedActiveBindingsFailClosedWithoutPartialParking() async throws {
    let root = temporaryStoreRoot("account-transition-mixed")
    defer { try? FileManager.default.removeItem(at: root) }
    let store = try LocalSyncV2Store(root: root, policy: .createNew)
    let first = WorkID(UUID())
    let second = WorkID(UUID())
    _ = try await store.checkpoint(
        V2CheckpointRequest(
            workID: first,
            document: makeDocument(title: "first"),
            documentCreatedAt: testDate,
            expectedGeneration: 0
        ),
        scope: scopeA
    )
    let other = V2AccountBinding(
        accountID: "account-b",
        accountFence: "fence-b",
        serverInstanceID: bindingA.serverInstanceID
    )
    _ = try await store.checkpoint(
        V2CheckpointRequest(
            workID: second,
            document: makeDocument(title: "second"),
            documentCreatedAt: testDate,
            expectedGeneration: 0
        ),
        scope: .bound(other)
    )
    await #expect(throws: SyncV2StoreError.accountMismatch) {
        try await store.transitionAccountScopes(from: bindingA, to: nil)
    }
    #expect(try await store.listWorks(scope: scopeA).map(\.workID) == [first])
    #expect(try await store.listWorks(scope: .bound(other)).map(\.workID) == [second])
    #expect(try await store.listWorks(scope: .parked).isEmpty)
}

@Test
func accountTransitionRollsBackWhenALinkedRestoreCannotBeRetired() async throws {
    let root = temporaryStoreRoot("account-transition-injected-failure")
    defer { try? FileManager.default.removeItem(at: root) }
    let store = try LocalSyncV2Store(root: root, policy: .createNew)
    let workIDs = [WorkID(UUID()), WorkID(UUID())]
    var restoreIntentIDs: [UUID] = []
    for workID in workIDs {
        var document = makeDocument(title: "before")
        let first = try await store.checkpoint(
            V2CheckpointRequest(
                workID: workID,
                document: document,
                documentCreatedAt: testDate,
                expectedGeneration: 0
            ),
            scope: scopeA
        )
        document.title = "after"
        let second = try await store.checkpoint(
            V2CheckpointRequest(
                workID: workID,
                document: document,
                documentCreatedAt: testDate,
                expectedGeneration: first.generation
            ),
            scope: scopeA
        )
        let prepared = try await store.prepareRestore(
            V2RestorePreparationRequest(
                workID: workID,
                selectedSnapshotID: first.snapshotID,
                expectedLocalGeneration: second.generation
            ),
            scope: scopeA
        )
        try restoreIntentIDs.append(#require(prepared.checkpoint.intentID))
    }

    // Inject a legal but inconsistent lifecycle state for the second row. The
    // first row must be rolled back when retirement reaches this failure.
    let injectedSQL = "UPDATE sync_intents SET status='acknowledged' WHERE intent_id='\(restoreIntentIDs[1].uuidString.lowercased())'"
    let databaseURL = await store.databaseURL
    #expect(try sqliteExecutionSucceeded(databaseURL: databaseURL, sql: injectedSQL))
    let rotated = V2AccountBinding(
        accountID: bindingA.accountID,
        accountFence: "fence-injected-failure",
        serverInstanceID: bindingA.serverInstanceID
    )
    await #expect(throws: SyncV2StoreError.invalidLifecycle) {
        try await store.transitionAccountScopes(from: bindingA, to: rotated)
    }
    #expect(try await store.listWorks(scope: scopeA).map(\.workID) == workIDs.sorted {
        $0.description < $1.description
    })
    #expect(try await store.listWorks(scope: .bound(rotated)).isEmpty)
    #expect(try await store.listWorks(scope: .parked).isEmpty)
}

@Test
func preparedRestoreIsParkedAndTransitionKeepsLocalHead() async throws {
    let root = temporaryStoreRoot("account-transition-rollback")
    defer { try? FileManager.default.removeItem(at: root) }
    let store = try LocalSyncV2Store(root: root, policy: .createNew)
    let workID = WorkID(UUID())
    var document = makeDocument(title: "before")
    let first = try await store.checkpoint(
        V2CheckpointRequest(
            workID: workID,
            document: document,
            documentCreatedAt: testDate,
            expectedGeneration: 0
        ),
        scope: scopeA
    )
    document.title = "after"
    let second = try await store.checkpoint(
        V2CheckpointRequest(
            workID: workID,
            document: document,
            documentCreatedAt: testDate,
            expectedGeneration: first.generation
        ),
        scope: scopeA
    )
    let prepared = try await store.prepareRestore(
        V2RestorePreparationRequest(
            workID: workID,
            selectedSnapshotID: first.snapshotID,
            expectedLocalGeneration: second.generation
        ),
        scope: scopeA
    )
    let rotated = V2AccountBinding(
        accountID: bindingA.accountID,
        accountFence: "fence-rollback",
        serverInstanceID: bindingA.serverInstanceID
    )
    try await store.transitionAccountScopes(from: bindingA, to: rotated)
    #expect(try await store.listWorks(scope: scopeA).isEmpty)
    #expect(try await store.listWorks(scope: .bound(rotated)).map(\.workID) == [workID])
    #expect(try await store.pendingIntents(scope: scopeA).isEmpty)
    #expect(try await store.pendingIntents(scope: .bound(rotated)).count == 1)
    #expect(try await store.open(workID: workID, scope: .bound(rotated)).summary.currentSnapshotID ==
        prepared.checkpoint.snapshotID)
}

@Test
func sealedRestoreIsParkedAndReauthRestartKeepsNewerEdit() async throws {
    let root = temporaryStoreRoot("account-transition-sealed-restore")
    defer { try? FileManager.default.removeItem(at: root) }
    let store = try LocalSyncV2Store(root: root, policy: .createNew)
    let workID = WorkID(UUID())
    var document = makeDocument(title: "before")
    let first = try await store.checkpoint(
        V2CheckpointRequest(
            workID: workID,
            document: document,
            documentCreatedAt: testDate,
            expectedGeneration: 0
        ),
        scope: scopeA
    )
    document.title = "second"
    let second = try await store.checkpoint(
        V2CheckpointRequest(
            workID: workID,
            document: document,
            documentCreatedAt: testDate,
            expectedGeneration: first.generation
        ),
        scope: scopeA
    )
    let prepared = try await store.prepareRestore(
        V2RestorePreparationRequest(
            workID: workID,
            selectedSnapshotID: first.snapshotID,
            expectedLocalGeneration: second.generation
        ),
        scope: scopeA
    )
    let command = try restoreCommand(
        workID: workID,
        source: second,
        selected: first.snapshotID,
        restored: prepared
    )
    try await store.seal(
        command,
        intentID: prepared.checkpoint.intentID,
        scope: scopeA
    )
    let rotated = V2AccountBinding(
        accountID: bindingA.accountID,
        accountFence: "fence-sealed-restore",
        serverInstanceID: bindingA.serverInstanceID
    )
    try await store.transitionAccountScopes(from: bindingA, to: rotated)
    #expect(try await store.pendingSealedCommands(scope: scopeA).isEmpty)
    await #expect(throws: SyncV2StoreError.accountMismatch) {
        _ = try await store.receiptReadback(commandID: command.commandId, scope: scopeA)
    }
    await #expect(throws: SyncV2StoreError.accountMismatch) {
        _ = try await store.receiptReadback(commandID: command.commandId, scope: .bound(rotated))
    }

    document.title = "typed after restore"
    let edited = try await store.checkpoint(
        V2CheckpointRequest(
            workID: workID,
            document: document,
            documentCreatedAt: testDate,
            expectedGeneration: prepared.checkpoint.generation
        ),
        scope: .bound(rotated)
    )
    #expect(edited.generation == prepared.checkpoint.generation + 1)
    try await store.transitionAccountScopes(from: rotated, to: nil)
    await store.close()

    let reopened = try LocalSyncV2Store(root: root, policy: .openExisting)
    try await reopened.transitionAccountScopes(from: nil, to: rotated)
    let opened = try await reopened.open(workID: workID, scope: .bound(rotated))
    #expect(opened.document?.title == "typed after restore")
    #expect(try await reopened.pendingIntents(scope: .bound(rotated), workID: workID).count == 1)
}

@Test
func lateReceiptAndUploadCompletionCannotCrossFence() async throws {
    let root = temporaryStoreRoot("account-transition-late-completion")
    defer { try? FileManager.default.removeItem(at: root) }
    let store = try LocalSyncV2Store(root: root, policy: .createNew)
    let workID = WorkID(UUID())
    let checkpoint = try await store.checkpoint(
        V2CheckpointRequest(
            workID: workID,
            document: makeDocument(title: "late"),
            documentCreatedAt: testDate,
            expectedGeneration: 0
        ),
        scope: scopeA
    )
    let command = try publishCommand(workID: workID, checkpoint: checkpoint)
    try await store.seal(command, intentID: checkpoint.intentID, scope: scopeA)
    let acknowledgement = try commandAcknowledgement(
        command,
        head: V2RemoteHead(snapshotID: checkpoint.snapshotID, generation: checkpoint.generation)
    )
    let bytes = Data("late-upload".utf8)
    let transferExpiry = Date(timeIntervalSince1970: 1_800_000_000)
    let transfer = V2UploadTransferRecord(
        transferID: UUID(),
        commandID: command.commandId,
        workID: workID,
        objectID: ObjectID(data: bytes),
        sourceSnapshotID: checkpoint.snapshotID,
        sourceGeneration: checkpoint.generation,
        uploadID: UUID(),
        capability: "late-capability",
        exactBytes: bytes,
        bytesDigest: ObjectID(data: bytes),
        acknowledgedOffset: 0,
        expiresAt: transferExpiry,
        lifecycle: "prepared"
    )
    try await store.persistUploadTransfer(transfer, scope: scopeA)
    let readback = try await store.uploadTransfer(commandID: command.commandId, scope: scopeA)
    #expect(readback == transfer)
    let rotated = V2AccountBinding(
        accountID: bindingA.accountID,
        accountFence: "fence-late",
        serverInstanceID: bindingA.serverInstanceID
    )
    try await store.transitionAccountScopes(from: bindingA, to: rotated)
    let databaseURL = await store.databaseURL
    #expect(try !sqliteExecutionSucceeded(
        databaseURL: databaseURL,
        sql: """
        UPDATE upload_transfers
        SET server_instance_id='\(rotated.serverInstanceID)',
            protocol_epoch=\(rotated.protocolEpoch),
            account_id='\(rotated.accountID)',
            account_fence='\(rotated.accountFence)'
        WHERE command_id='\(command.commandId.uuidString.lowercased())'
        """
    ))
    await #expect(throws: SyncV2StoreError.accountMismatch) {
        _ = try await store.receiptReadback(commandID: command.commandId, scope: scopeA)
    }
    await #expect(throws: SyncV2StoreError.accountMismatch) {
        _ = try await store.receiptReadback(commandID: command.commandId, scope: .bound(rotated))
    }
    let beforeLateAcknowledgement = try await store.open(workID: workID, scope: .bound(rotated)).summary
    let beforeLateIntents = try await store.pendingIntents(scope: .bound(rotated), workID: workID)
    for scope in [scopeA, .bound(rotated)] {
        await #expect(throws: SyncV2StoreError.accountMismatch) {
            try await store.acknowledge(acknowledgement, scope: scope)
        }
        await #expect(throws: SyncV2StoreError.accountMismatch) {
            try await store.acknowledgeUploadTransfer(
                transferID: transfer.transferID,
                byteCount: bytes.count,
                scope: scope
            )
        }
    }
    #expect(try await store.open(workID: workID, scope: .bound(rotated)).summary == beforeLateAcknowledgement)
    #expect(try await store.pendingIntents(scope: .bound(rotated), workID: workID) == beforeLateIntents)
    #expect(try sqliteScalarInt(
        databaseURL: databaseURL,
        sql: "SELECT acknowledged_offset FROM upload_transfers WHERE transfer_id='\(transfer.transferID.uuidString.lowercased())'"
    ) == 0)
    #expect(try sqliteScalarInt(
        databaseURL: databaseURL,
        sql: "SELECT COUNT(*) FROM upload_transfers WHERE transfer_id='\(transfer.transferID.uuidString.lowercased())' AND lifecycle='quarantined'"
    ) == 1)
    await #expect(throws: SyncV2StoreError.invalidCommand) {
        try await store.persistUploadTransfer(transfer, scope: scopeA)
    }
    #expect(try await store.pendingIntents(scope: .bound(rotated)).count == 1)
}

@Test
func uploadTransferReadbackRejectsTamperedDigest() async throws {
    let root = temporaryStoreRoot("upload-transfer-readback")
    defer { try? FileManager.default.removeItem(at: root) }
    let store = try LocalSyncV2Store(root: root, policy: .createNew)
    let workID = WorkID(UUID())
    let checkpoint = try await store.checkpoint(
        V2CheckpointRequest(
            workID: workID,
            document: makeDocument(title: "transfer"),
            documentCreatedAt: testDate,
            expectedGeneration: 0
        ),
        scope: scopeA
    )
    let command = try publishCommand(workID: workID, checkpoint: checkpoint)
    try await store.seal(command, intentID: checkpoint.intentID, scope: scopeA)
    let bytes = Data("transfer-bytes".utf8)
    let transfer = V2UploadTransferRecord(
        transferID: UUID(),
        commandID: command.commandId,
        workID: workID,
        objectID: ObjectID(data: bytes),
        sourceSnapshotID: checkpoint.snapshotID,
        sourceGeneration: checkpoint.generation,
        uploadID: UUID(),
        capability: "capability",
        exactBytes: bytes,
        bytesDigest: ObjectID(data: bytes),
        acknowledgedOffset: 0,
        expiresAt: Date().addingTimeInterval(60),
        lifecycle: "prepared"
    )
    try await store.persistUploadTransfer(transfer, scope: scopeA)
    let databaseURL = await store.databaseURL
    #expect(try sqliteExecutionSucceeded(
        databaseURL: databaseURL,
        sql: "UPDATE upload_transfers SET bytes_digest=zeroblob(32) WHERE transfer_id='\(transfer.transferID.uuidString.lowercased())'"
    ))
    await #expect(throws: SyncV2StoreError.invalidCommand) {
        _ = try await store.uploadTransfer(commandID: command.commandId, scope: scopeA)
    }
}

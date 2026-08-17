import Foundation
import NovelCore
import NovelSyncV2
import NovelSyncV2Store
import Testing

@Test
func restorePinsCurrentUsesTwoParentsAndAckPreservesNewerEdit() async throws {
    let root = temporaryStoreRoot("restore")
    defer { try? FileManager.default.removeItem(at: root) }
    let workID = WorkID(UUID())
    var document = makeDocument(title: "first")
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
    document.title = "second"
    let second = try await store.checkpoint(
        V2CheckpointRequest(
            workID: workID,
            document: document,
            documentCreatedAt: testDate,
            expectedGeneration: 1
        ),
        scope: scopeA
    )
    let restored = try await store.prepareRestore(
        V2RestorePreparationRequest(
            workID: workID,
            selectedSnapshotID: first.snapshotID,
            expectedLocalGeneration: 2
        ),
        scope: scopeA
    )
    #expect(restored.restoreID != nil)
    #expect(try await store.snapshotParents(
        workID: workID,
        snapshotID: restored.checkpoint.snapshotID,
        scope: scopeA
    ) == [first.snapshotID, second.snapshotID].sorted { $0.rawValue < $1.rawValue })
    let history = try await store.history(workID: workID, scope: scopeA)
    #expect(history.contains { $0.snapshotID == second.snapshotID && $0.pinned })
    #expect(!history.contains { $0.snapshotID == first.snapshotID && $0.reason == "preRestore" })

    let noOp = try await store.prepareRestore(
        V2RestorePreparationRequest(
            workID: workID,
            selectedSnapshotID: restored.checkpoint.snapshotID,
            expectedLocalGeneration: 3
        ),
        scope: scopeA
    )
    #expect(noOp.restoreID == nil)
    #expect(noOp.checkpoint.noChanges)

    let command = try restoreCommand(
        workID: workID,
        source: second,
        selected: first.snapshotID,
        restored: restored
    )
    try await store.seal(
        command,
        intentID: restored.checkpoint.intentID,
        scope: scopeA
    )
    var typedLater = makeDocument(title: "ignored", id: document.id)
    typedLater.chapters = document.chapters
    typedLater.title = "typed after restore"
    let newer = try await store.checkpoint(
        V2CheckpointRequest(
            workID: workID,
            document: typedLater,
            documentCreatedAt: testDate,
            expectedGeneration: 3
        ),
        scope: scopeA
    )
    try await store.acknowledge(
        commandAcknowledgement(
            command,
            head: V2RemoteHead(
                snapshotID: restored.checkpoint.snapshotID,
                generation: 5
            )
        ),
        scope: scopeA
    )
    let opened = try await store.open(workID: workID, scope: scopeA)
    let pending = try await store.pendingIntents(scope: scopeA)
    #expect(opened.document?.title == "typed after restore")
    #expect(opened.summary.currentSnapshotID == newer.snapshotID)
    #expect(pending.count == 1)
    #expect(pending[0].sourceSnapshotID == newer.snapshotID)
}

@Test
func localOnlyRestoreDoesNotCreateAnUnboundRemoteLane() async throws {
    let root = temporaryStoreRoot("restore-local-only")
    defer { try? FileManager.default.removeItem(at: root) }
    let workID = WorkID(UUID())
    var document = makeDocument(title: "local-first")
    let store = try LocalSyncV2Store(root: root, policy: .createNew)
    let first = try await store.checkpoint(
        V2CheckpointRequest(
            workID: workID,
            document: document,
            documentCreatedAt: testDate,
            expectedGeneration: 0
        ),
        scope: .unbound
    )
    document.title = "newer"
    let second = try await store.checkpoint(
        V2CheckpointRequest(
            workID: workID,
            document: document,
            documentCreatedAt: testDate,
            expectedGeneration: first.generation
        ),
        scope: .unbound
    )

    let restored = try await store.prepareRestore(
        V2RestorePreparationRequest(
            workID: workID,
            selectedSnapshotID: first.snapshotID,
            expectedLocalGeneration: second.generation
        ),
        scope: .unbound
    )
    #expect(restored.restoreID == nil)
    #expect(restored.checkpoint.intentID == nil)
    #expect(try await store.pendingIntents(scope: .unbound, workID: workID).isEmpty)
    #expect(try await store.open(workID: workID, scope: .unbound).document?.title == "local-first")

    let parkedWorkID = WorkID(UUID())
    var parkedDocument = makeDocument(title: "parked-first")
    let parkedFirst = try await store.checkpoint(
        V2CheckpointRequest(
            workID: parkedWorkID,
            document: parkedDocument,
            documentCreatedAt: testDate,
            expectedGeneration: 0
        ),
        scope: scopeA
    )
    parkedDocument.title = "parked-newer"
    _ = try await store.checkpoint(
        V2CheckpointRequest(
            workID: parkedWorkID,
            document: parkedDocument,
            documentCreatedAt: testDate,
            expectedGeneration: parkedFirst.generation
        ),
        scope: scopeA
    )
    try await store.parkWork(workID: parkedWorkID, binding: bindingA)
    let parkedRestore = try await store.prepareRestore(
        V2RestorePreparationRequest(
            workID: parkedWorkID,
            selectedSnapshotID: parkedFirst.snapshotID,
            expectedLocalGeneration: 2
        ),
        scope: .parked
    )
    #expect(parkedRestore.restoreID == nil)
    #expect(parkedRestore.checkpoint.intentID == nil)
    #expect(try await store.pendingIntents(scope: .parked, workID: parkedWorkID).isEmpty)
    #expect(try await store.open(workID: parkedWorkID, scope: .parked).document?.title == "parked-first")
}

@Test
func keepBothReservationSurvivesRestartAndFinalizesAtomically() async throws {
    let root = temporaryStoreRoot("keep-both")
    defer { try? FileManager.default.removeItem(at: root) }
    let sourceWorkID = WorkID(UUID())
    let newWorkID = WorkID(UUID())
    let newDocumentID = DocumentID(UUID())
    let store = try LocalSyncV2Store(root: root, policy: .createNew)
    let fixture = try await createConflict(store: store, workID: sourceWorkID)
    let reservation = try await store.prepareKeepBoth(
        V2KeepBothPreparationRequest(
            workID: sourceWorkID,
            conflictID: fixture.conflict.conflictID,
            revision: fixture.conflict.revision,
            sourceGeneration: fixture.conflict.sourceGeneration,
            localSnapshotID: fixture.conflict.localSnapshotID,
            remoteSnapshotID: fixture.conflict.remoteSnapshotID,
            newWorkID: newWorkID,
            newDocumentID: newDocumentID
        ),
        scope: scopeA
    )
    #expect(try await store.pendingIntents(scope: scopeA, workID: newWorkID).isEmpty)
    let openedClone = try await store.open(workID: newWorkID, scope: scopeA)
    var cloneEdit = try #require(openedClone.document)
    cloneEdit.title = "clone edited while reserved"
    let cloneCheckpoint = try await store.checkpoint(
        V2CheckpointRequest(
            workID: newWorkID,
            document: cloneEdit,
            documentCreatedAt: testDate,
            expectedGeneration: 1
        ),
        scope: scopeA
    )
    #expect(cloneCheckpoint.intentID == nil)
    #expect(try await store.pendingIntents(scope: scopeA, workID: newWorkID).isEmpty)

    let command = try cloneWorkCommand(
        conflict: fixture.conflict,
        reservation: reservation,
        expectedHead: fixture.remoteHead
    )
    try await store.seal(command, scope: scopeA)
    var sourceEdit = fixture.localDocument
    sourceEdit.title = "source typed after keep both"
    let sourceCheckpoint = try await store.checkpoint(
        V2CheckpointRequest(
            workID: sourceWorkID,
            document: sourceEdit,
            documentCreatedAt: testDate,
            expectedGeneration: fixture.conflict.sourceGeneration
        ),
        scope: scopeA
    )
    _ = try await store.markSending(commandID: command.commandId, scope: scopeA)
    await store.close()

    try await verifyKeepBothAfterRestart(
        KeepBothRestartContext(
            root: root,
            sourceWorkID: sourceWorkID,
            newWorkID: newWorkID,
            fixture: fixture,
            reservation: reservation,
            command: command,
            cloneCheckpoint: cloneCheckpoint,
            sourceCheckpoint: sourceCheckpoint
        )
    )
}

private struct KeepBothRestartContext {
    let root: URL
    let sourceWorkID: WorkID
    let newWorkID: WorkID
    let fixture: ConflictFixture
    let reservation: V2KeepBothReservation
    let command: SealedCommand
    let cloneCheckpoint: V2CheckpointResult
    let sourceCheckpoint: V2CheckpointResult
}

private func verifyKeepBothAfterRestart(
    _ context: KeepBothRestartContext
) async throws {
    let root = context.root
    let sourceWorkID = context.sourceWorkID
    let newWorkID = context.newWorkID
    let reservation = context.reservation
    let command = context.command
    let cloneCheckpoint = context.cloneCheckpoint
    let sourceCheckpoint = context.sourceCheckpoint
    let reopened = try LocalSyncV2Store(root: root, policy: .openExisting)
    let replay = try await reopened.pendingSealedCommands(scope: scopeA)
    #expect(replay.count == 1)
    #expect(replay[0].canonicalRequest == command.canonicalBytes)
    let sameReservation = try await reopened.keepBothReservation(
        sourceWorkID: sourceWorkID,
        newWorkID: newWorkID,
        scope: scopeA
    )
    #expect(sameReservation?.reservationID == reservation.reservationID)
    #expect(sameReservation?.newRootSnapshotID == reservation.newRootSnapshotID)

    do {
        try await reopened.acknowledge(
            commandAcknowledgement(
                command,
                head: V2RemoteHead(
                    snapshotID: cloneCheckpoint.snapshotID,
                    generation: 1
                )
            ),
            scope: scopeA
        )
        Issue.record("stale clone head finalized reservation")
    } catch SyncV2StoreError.invalidAcknowledgement {}
    #expect(try await reopened.keepBothReservation(
        sourceWorkID: sourceWorkID,
        newWorkID: newWorkID,
        scope: scopeA
    )?.state == "sealed")

    let acknowledgement = try commandAcknowledgement(
        command,
        head: V2RemoteHead(
            snapshotID: reservation.newRootSnapshotID,
            generation: 1
        )
    )
    try await reopened.acknowledge(acknowledgement, scope: scopeA)
    try await reopened.acknowledge(acknowledgement, scope: scopeA)
    let source = try await reopened.open(workID: sourceWorkID, scope: scopeA)
    let clone = try await reopened.open(workID: newWorkID, scope: scopeA)
    let pending = try await reopened.pendingIntents(scope: scopeA)
    #expect(source.document?.title == "source typed after keep both")
    #expect(source.summary.currentSnapshotID == sourceCheckpoint.snapshotID)
    #expect(clone.document?.title == "clone edited while reserved")
    #expect(try await reopened.activeConflict(workID: sourceWorkID, scope: scopeA) == nil)
    #expect(try await reopened.keepBothReservation(
        sourceWorkID: sourceWorkID,
        newWorkID: newWorkID,
        scope: scopeA
    )?.state == "finalized")
    #expect(pending.count == 2)
    #expect(pending.contains {
        $0.workID == sourceWorkID && $0.sourceSnapshotID == sourceCheckpoint.snapshotID
    })
    #expect(pending.contains {
        $0.workID == newWorkID && $0.sourceSnapshotID == cloneCheckpoint.snapshotID
    })
}

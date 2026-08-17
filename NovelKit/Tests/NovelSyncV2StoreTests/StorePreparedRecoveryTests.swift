import Foundation
import NovelCore
import NovelSyncV2
import NovelSyncV2Store
import Testing

@Test
func deviceChoiceCanBeSealedAfterEditAndRestart() async throws {
    let root = temporaryStoreRoot("device-prepare-restart")
    defer { try? FileManager.default.removeItem(at: root) }
    let workID = WorkID(UUID())
    let store = try LocalSyncV2Store(root: root, policy: .createNew)
    let fixture = try await createConflict(store: store, workID: workID)
    let request = deviceRequest(workID: workID, fixture: fixture)
    let first = try await store.prepareUseDevice(request, scope: scopeA)
    var edited = fixture.localDocument
    edited.title = "typed before seal"
    let edit = try await store.checkpoint(
        V2CheckpointRequest(
            workID: workID,
            document: edited,
            documentCreatedAt: testDate,
            expectedGeneration: first.generation
        ),
        scope: scopeA
    )
    await store.close()

    let reopened = try LocalSyncV2Store(root: root, policy: .openExisting)
    let recovered = try await reopened.prepareUseDevice(request, scope: scopeA)
    #expect(recovered.snapshotID == first.snapshotID)
    #expect(recovered.generation == first.generation)
    #expect(recovered.intentID == first.intentID)
    let command = try resolveDeviceCommand(
        workID: workID,
        conflict: fixture.conflict,
        decision: recovered,
        expectedHead: fixture.remoteHead
    )
    try await reopened.seal(command, intentID: recovered.intentID, scope: scopeA)
    #expect(try await reopened.pendingSealedCommands(scope: scopeA).map(\.commandID) == [
        command.commandId
    ])
    #expect(try await reopened.open(workID: workID, scope: scopeA).summary.currentSnapshotID ==
        edit.snapshotID)
}

@Test
func restoreCanBeSealedAfterEditAndRestart() async throws {
    let root = temporaryStoreRoot("restore-prepare-restart")
    defer { try? FileManager.default.removeItem(at: root) }
    let workID = WorkID(UUID())
    let store = try LocalSyncV2Store(root: root, policy: .createNew)
    var document = makeDocument(title: "one")
    let first = try await checkpoint(store, workID: workID, document: document, generation: 0)
    document.title = "two"
    let second = try await checkpoint(store, workID: workID, document: document, generation: 1)
    let request = V2RestorePreparationRequest(
        workID: workID,
        selectedSnapshotID: first.snapshotID,
        expectedLocalGeneration: second.generation
    )
    let prepared = try await store.prepareRestore(request, scope: scopeA)
    document.title = "typed before restore seal"
    let edit = try await checkpoint(
        store,
        workID: workID,
        document: document,
        generation: prepared.checkpoint.generation
    )
    await store.close()

    let reopened = try LocalSyncV2Store(root: root, policy: .openExisting)
    let recovered = try await reopened.prepareRestore(request, scope: scopeA)
    #expect(recovered.restoreID == prepared.restoreID)
    #expect(recovered.checkpoint.snapshotID == prepared.checkpoint.snapshotID)
    #expect(recovered.checkpoint.intentID == prepared.checkpoint.intentID)
    #expect(recovered.expectedRemoteHead == prepared.expectedRemoteHead)
    let command = try restoreCommand(
        workID: workID,
        source: second,
        selected: first.snapshotID,
        restored: recovered
    )
    try await reopened.seal(
        command,
        intentID: recovered.checkpoint.intentID,
        scope: scopeA
    )
    #expect(try await reopened.pendingSealedCommands(scope: scopeA).map(\.commandID) == [
        command.commandId
    ])
    #expect(try await reopened.open(workID: workID, scope: scopeA).summary.currentSnapshotID ==
        edit.snapshotID)
}

@Test
func keepBothReturnsOneConflictReservationAfterSourceEdit() async throws {
    let root = temporaryStoreRoot("keep-both-one-reservation")
    defer { try? FileManager.default.removeItem(at: root) }
    let workID = WorkID(UUID())
    let store = try LocalSyncV2Store(root: root, policy: .createNew)
    let fixture = try await createConflict(store: store, workID: workID)
    let firstRequest = keepBothRequest(fixture: fixture, newWorkID: WorkID(UUID()))
    let first = try await store.prepareKeepBoth(firstRequest, scope: scopeA)
    var edited = fixture.localDocument
    edited.title = "typed before clone seal"
    let edit = try await checkpoint(
        store,
        workID: workID,
        document: edited,
        generation: fixture.conflict.sourceGeneration
    )

    let unusedWorkID = WorkID(UUID())
    let second = try await store.prepareKeepBoth(
        keepBothRequest(fixture: fixture, newWorkID: unusedWorkID),
        scope: scopeA
    )
    #expect(second.reservationID == first.reservationID)
    #expect(second.newWorkID == first.newWorkID)
    #expect(try await store.listWorks(scope: scopeA).contains {
        $0.workID == unusedWorkID
    } == false)
    let command = try cloneWorkCommand(
        conflict: fixture.conflict,
        reservation: second,
        expectedHead: second.expectedOriginalHead
    )
    try await store.seal(command, scope: scopeA)
    #expect(try await store.pendingSealedCommands(scope: scopeA).map(\.commandID) == [
        command.commandId
    ])
    #expect(try await store.open(workID: workID, scope: scopeA).summary.currentSnapshotID ==
        edit.snapshotID)
}

private func deviceRequest(
    workID: WorkID,
    fixture: ConflictFixture
) -> V2DeviceResolutionRequest {
    V2DeviceResolutionRequest(
        workID: workID,
        conflictID: fixture.conflict.conflictID,
        revision: fixture.conflict.revision,
        sourceGeneration: fixture.conflict.sourceGeneration,
        localSnapshotID: fixture.conflict.localSnapshotID,
        remoteSnapshotID: fixture.conflict.remoteSnapshotID,
        inboxID: fixture.remote.inboxID,
        remoteHead: fixture.remoteHead
    )
}

private func keepBothRequest(
    fixture: ConflictFixture,
    newWorkID: WorkID
) -> V2KeepBothPreparationRequest {
    V2KeepBothPreparationRequest(
        workID: fixture.conflict.workID,
        conflictID: fixture.conflict.conflictID,
        revision: fixture.conflict.revision,
        sourceGeneration: fixture.conflict.sourceGeneration,
        localSnapshotID: fixture.conflict.localSnapshotID,
        remoteSnapshotID: fixture.conflict.remoteSnapshotID,
        newWorkID: newWorkID,
        newDocumentID: DocumentID(UUID())
    )
}

private func checkpoint(
    _ store: LocalSyncV2Store,
    workID: WorkID,
    document: NovelDocument,
    generation: Int64
) async throws -> V2CheckpointResult {
    try await store.checkpoint(
        V2CheckpointRequest(
            workID: workID,
            document: document,
            documentCreatedAt: testDate,
            expectedGeneration: generation
        ),
        scope: scopeA
    )
}

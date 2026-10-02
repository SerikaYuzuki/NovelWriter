import Foundation
import NovelCore
import NovelSyncV2
import NovelSyncV2Store
import Testing

@Test
func rejectedUploadSurvivesRestartAndRequiresExplicitRetry() async throws {
    let root = temporaryStoreRoot("rejected-upload")
    defer { try? FileManager.default.removeItem(at: root) }
    let store = try LocalSyncV2Store(root: root, policy: .createNew)
    let workID = WorkID(UUID())
    let checkpoint = try await store.checkpoint(V2CheckpointRequest(
        workID: workID, document: makeDocument(title: "upload"),
        documentCreatedAt: testDate, expectedGeneration: 0, reason: .explicit
    ), scope: scopeA)
    let command = try publishCommand(workID: workID, checkpoint: checkpoint)
    try await store.seal(command, intentID: checkpoint.intentID, scope: scopeA)
    let bytes = Data("retained upload".utf8)
    let transfer = V2UploadTransferRecord(
        transferID: UUID(), commandID: command.commandId, workID: workID,
        objectID: ObjectID(data: bytes), sourceSnapshotID: checkpoint.snapshotID,
        sourceGeneration: checkpoint.generation, uploadID: UUID(), capability: "fixture",
        exactBytes: bytes, bytesDigest: ObjectID(data: bytes), acknowledgedOffset: 0,
        expiresAt: Date(timeIntervalSince1970: 2_000_000_000), lifecycle: "prepared"
    )
    try await store.persistUploadTransfer(transfer, scope: scopeA)
    try await store.quarantineUpload(transferID: transfer.transferID, workID: workID,
                                     reason: "uploadTooLarge", scope: scopeA)
    // Replanning the identical transfer must not reset the permanent failure.
    try await store.persistUploadTransfer(transfer, scope: scopeA)
    await store.close()
    let reopened = try LocalSyncV2Store(root: root, policy: .openExisting)
    #expect(try await reopened.quarantinedUploadReason(workID: workID, scope: scopeA) == "uploadTooLarge")
    #expect(try await reopened.uploadTransfer(commandID: command.commandId, scope: scopeA)?.lifecycle == "quarantined")
    await #expect(throws: SyncV2StoreError.accountMismatch) {
        try await reopened.requestSynchronization(workID: workID, scope: .bound(V2AccountBinding(accountID: "other", accountFence: "other", serverInstanceID: "server-a")))
    }
    try await reopened.requestSynchronization(workID: workID, scope: scopeA)
    #expect(try await reopened.quarantinedUploadReason(workID: workID, scope: scopeA) == nil)
    let retry = try await reopened.uploadTransfer(commandID: command.commandId, scope: scopeA)
    #expect(retry?.lifecycle == "prepared")
    #expect(retry?.exactBytes == bytes)
    #expect(retry?.uploadID == transfer.uploadID)
    await reopened.close()
}

@Test
func unavailableRemoteCommandKeepsReasonUntilExplicitRetry() async throws {
    let root = temporaryStoreRoot("unavailable-command")
    defer { try? FileManager.default.removeItem(at: root) }
    let store = try LocalSyncV2Store(root: root, policy: .createNew)
    let workID = WorkID(UUID())
    let checkpoint = try await store.checkpoint(V2CheckpointRequest(
        workID: workID, document: makeDocument(title: "local original"),
        documentCreatedAt: testDate, expectedGeneration: 0, reason: .explicit
    ), scope: scopeA)
    let command = try publishCommand(workID: workID, checkpoint: checkpoint)
    try await store.seal(command, intentID: checkpoint.intentID, scope: scopeA)
    try await store.quarantine(commandID: command.commandId, scope: scopeA, reason: "remoteDataUnavailable")
    await store.close()
    let reopened = try LocalSyncV2Store(root: root, policy: .openExisting)
    #expect(try await reopened.quarantinedCommandReason(workID: workID, scope: scopeA) == "remoteDataUnavailable")
    #expect(try await reopened.open(workID: workID, scope: scopeA).summary.localGeneration == checkpoint.generation)
    try await reopened.requestSynchronization(workID: workID, scope: scopeA)
    #expect(try await reopened.quarantinedCommandReason(workID: workID, scope: scopeA) == nil)
    #expect(try await reopened.pendingSealedCommands(scope: scopeA, workID: workID).first?.commandID == command.commandId)
    await reopened.close()
}

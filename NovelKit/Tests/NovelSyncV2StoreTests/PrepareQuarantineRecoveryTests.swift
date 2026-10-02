import Foundation
import NovelSyncV2
@testable import NovelSyncV2Store
import Testing

@Test(arguments: ["unexpected", "receiptMismatch", "differentAccount", "noReason", "response", "transfer", "evidence", "verified", "reservedLane"])
func automaticPrepareRecoveryIsNarrowAndPreservesIdentity(scenario: String) async throws {
    let root = temporaryStoreRoot("prepare-recovery")
    defer { try? FileManager.default.removeItem(at: root) }
    let store = try LocalSyncV2Store(root: root, policy: .createNew)
    let workID = WorkID(UUID())
    let bytes = Data("local cover bytes".utf8)
    let objectID = ObjectID(data: bytes)
    let checkpoint = try await store.checkpoint(V2CheckpointRequest(
        workID: workID, document: makeDocument(title: "retained"), documentCreatedAt: testDate,
        expectedGeneration: 0, reason: .explicit,
        attachments: [SyncAttachment(attachmentId: UUID(), fileName: "cover.jpg", bytes: bytes)]
    ), scope: scopeA)
    let command = try canonicalCommand(
        kind: "prepareObject", sourceGeneration: checkpoint.generation, sourceSnapshotID: checkpoint.snapshotID,
        payload: "{\"byteCount\":\(bytes.count),\"objectId\":\"\(objectID.rawValue)\",\"workId\":\"\(workID.description)\"}"
    )
    try await store.seal(command, scope: scopeA)
    let reason: String? = switch scenario {
    case "noReason": nil
    case "response", "transfer", "evidence", "verified", "reservedLane": "unexpected"
    default: scenario
    }
    try await store.quarantine(commandID: command.commandId, scope: scopeA, reason: reason)
    if scenario == "response" {
        try await store.exec("UPDATE sealed_commands SET response_status=201,canonical_response=X'7B7D' WHERE command_id=?", [.text(command.commandId.uuidString.lowercased())])
    }
    if scenario == "transfer" {
        try await store.persistUploadTransfer(V2UploadTransferRecord(
            transferID: command.commandId, commandID: command.commandId, workID: workID,
            objectID: objectID, sourceSnapshotID: checkpoint.snapshotID, sourceGeneration: checkpoint.generation,
            uploadID: UUID(), capability: String(repeating: "a", count: 64), exactBytes: bytes,
            bytesDigest: objectID, acknowledgedOffset: 0, expiresAt: .distantFuture, lifecycle: "prepared"
        ), scope: scopeA)
    }
    if scenario == "evidence" {
        try await store.exec("UPDATE quarantine_records SET evidence_bytes=X'01' WHERE quarantine_id=?", [.text(command.commandId.uuidString.lowercased())])
    }
    if scenario == "verified" {
        try await store.exec("UPDATE sealed_commands SET receipt_verified=1 WHERE command_id=?", [.text(command.commandId.uuidString.lowercased())])
    }
    if scenario == "reservedLane" {
        try await store.exec("UPDATE works SET sync_lane='keepBothReserved' WHERE work_id=?", [.text(workID.description)])
    }
    try await store.prepareLegacyCommandRecoveryFixture()
    await store.close()
    let reopened = try LocalSyncV2Store(root: root, policy: .openExisting)
    for binding in [
        V2AccountBinding(accountID: "other", accountFence: "fence-a", serverInstanceID: "server-a"),
        V2AccountBinding(accountID: "account-a", accountFence: "other", serverInstanceID: "server-a")
    ] {
        await #expect(throws: SyncV2StoreError.accountMismatch) {
            try await reopened.requestSynchronization(workID: workID, scope: .bound(binding))
        }
    }
    try await reopened.retryUnacknowledgedCommands(scope: scopeA)
    let records = try await reopened.allSealedCommands(scope: scopeA, workID: workID)
    let retained = try #require(records.first)
    #expect(records.count == 1)
    #expect(retained.commandID == command.commandId)
    #expect(retained.canonicalRequest == command.canonicalBytes)
    #expect(retained.requestDigest == command.requestDigest)
    #expect(retained.lifecycle == (scenario == "unexpected" ? .sealed : .quarantined))
    let local = try await reopened.open(workID: workID, scope: scopeA)
    #expect(local.summary.currentSnapshotID == checkpoint.snapshotID)
    #expect(local.summary.localGeneration == checkpoint.generation)
    #expect(local.attachments.first?.bytes == bytes)
    await reopened.close()
}

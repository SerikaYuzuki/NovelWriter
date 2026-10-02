import Foundation
import NovelSyncV2
@testable import NovelSyncV2Store
import Testing

@Test(arguments: ["createWork", "publish"], ["unexpected", "remoteDataUnavailable", "receiptMismatch", "noReason", "response"])
func automaticRecoveryPreservesManualQuarantines(kind: String, scenario: String) async throws {
    let root = temporaryStoreRoot("manual-automatic-recovery")
    defer { try? FileManager.default.removeItem(at: root) }
    let store = try LocalSyncV2Store(root: root, policy: .createNew)
    let workID = WorkID(UUID())
    let document = makeDocument(title: "retained")
    let checkpoint = try await store.checkpoint(V2CheckpointRequest(
        workID: workID, document: document, documentCreatedAt: testDate,
        expectedGeneration: 0, reason: .explicit
    ), scope: scopeA)
    let command = try kind == "createWork"
        ? createWorkCommand(workID: workID, documentID: document.id, checkpoint: checkpoint)
        : publishCommand(workID: workID, checkpoint: checkpoint)
    try await store.seal(command, intentID: kind == "publish" ? checkpoint.intentID : nil, scope: scopeA)
    let reason = scenario == "noReason" ? nil : (scenario == "response" ? "unexpected" : scenario)
    try await store.quarantine(commandID: command.commandId, scope: scopeA, reason: reason)
    if scenario == "response" {
        try await store.exec("UPDATE sealed_commands SET response_status=200,canonical_response=X'7B7D' WHERE command_id=?",
                             [.text(command.commandId.uuidString.lowercased())])
    }
    await store.close()
    let reopened = try LocalSyncV2Store(root: root, policy: .openExisting)
    // The wake scan and per-work backoff planner both use this narrow recovery.
    try await reopened.retryUnacknowledgedCommands(scope: scopeA)
    try await reopened.retryUnacknowledgedCommands(workID: workID, scope: scopeA)
    #expect(try await reopened.allSealedCommands(scope: scopeA, workID: workID).first?.lifecycle == .quarantined)
    #expect(try await reopened.quarantinedCommandReason(workID: workID, scope: scopeA) == reason)
    try await reopened.requestSynchronization(workID: workID, scope: scopeA)
    let retried = try #require(await reopened.pendingSealedCommands(scope: scopeA, workID: workID).first)
    #expect(retried.commandID == command.commandId)
    #expect(retried.canonicalRequest == command.canonicalBytes)
    #expect(retried.requestDigest == command.requestDigest)
    #expect(try await reopened.quarantinedCommandReason(workID: workID, scope: scopeA) == nil)
    await reopened.close()
}

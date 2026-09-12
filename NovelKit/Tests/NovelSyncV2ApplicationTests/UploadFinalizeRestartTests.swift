import Foundation
import NovelSyncV2
@testable import NovelSyncV2Application
@testable import NovelSyncV2Runtime
import NovelSyncV2Store
import Testing

@Test func restartedPlannerFinalizesEveryUploadBeforeRegistration() async throws {
    let config = try TestRuntimeConfiguration()
    let store = try LocalSyncV2Store(root: config.localRoot.url, policy: .createNew)
    let workID = WorkID(UUID())
    _ = try await store.checkpoint(V2CheckpointRequest(
        workID: workID, document: applicationTestDocument(title: "restart", body: "body"),
        documentCreatedAt: applicationTestCreatedAt, expectedGeneration: 0
    ), scope: productionScope)
    let scope = TestScopeResolver(vault: config.vault, store: store)
    var uploaded = Set<UUID>()
    var finalized = Set<UUID>()
    for _ in 0 ..< 100 {
        // Drop all in-memory transfer and object-presence caches at every step.
        let planner = ProductionSyncV2Planner(store: store, scope: scope)
        switch try await planner.nextCommand(workID: workID) {
        case let .upload(transfer):
            #expect(!uploaded.contains(transfer.uploadID))
            try await planner.acknowledgeUpload(SyncV2UploadCompletion(
                transferID: transfer.transferID, uploadID: transfer.uploadID,
                objectID: transfer.objectID, acknowledgedByteCount: transfer.exactBytes.count
            ))
            uploaded.insert(transfer.uploadID)
        case let .command(command):
            if command.commandKind == "registerSnapshot" {
                #expect(!uploaded.isEmpty)
                #expect(finalized == uploaded)
                await store.close()
                return
            }
            if command.commandKind == "finalizeObject" {
                let payload = try productionPayload(command)
                let id = try #require(try UUID(uuidString: productionString(payload, key: "uploadId")))
                #expect(uploaded.contains(id))
                finalized.insert(id)
            }
            let status = ["createWork", "prepareObject"].contains(command.commandKind) ? 201 : 200
            let response = try productionResponse(command: command, result: .applied, head: nil, cloneHead: nil, status: status)
            let envelope = try productionEnvelope(command: command, response: response, result: .applied, status: status)
            try await store.acknowledge(V2CommandAcknowledgement(
                commandID: command.commandId, canonicalReceiptEnvelope: envelope
            ), scope: productionScope)
        default:
            Issue.record("transfer stopped before registration")
            await store.close()
            return
        }
    }
    Issue.record("transfer did not reach registration")
    await store.close()
}

import Foundation
import NovelAuth
import NovelSyncV2
@testable import NovelSyncV2Application
@testable import NovelSyncV2Runtime
import NovelSyncV2Store
import Testing

@Test(arguments: [false, true])
func restartedPlannerFinalizesEveryUploadBeforeRegistration(expireFirstUpload: Bool) async throws {
    let config = try TestRuntimeConfiguration()
    let store = try LocalSyncV2Store(root: config.localRoot.url, policy: .createNew)
    let workID = WorkID(UUID())
    _ = try await store.checkpoint(V2CheckpointRequest(
        workID: workID, document: applicationTestDocument(title: "restart", body: "body"),
        documentCreatedAt: applicationTestCreatedAt, expectedGeneration: 0, reason: .explicit
    ), scope: productionScope)
    let scope = TestScopeResolver(vault: config.vault, store: store)
    var uploaded = Set<UUID>()
    var finalized = Set<UUID>()
    var published = false
    var expiredUpload: UUID?
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
            if expireFirstUpload, expiredUpload == nil {
                let stored = try #require(try await store.uploadTransfer(
                    commandID: transfer.transferID, scope: productionScope
                ))
                try await store.persistUploadTransfer(V2UploadTransferRecord(
                    transferID: stored.transferID, commandID: stored.commandID,
                    workID: stored.workID, objectID: stored.objectID,
                    sourceSnapshotID: stored.sourceSnapshotID, sourceGeneration: stored.sourceGeneration,
                    uploadID: stored.uploadID, capability: stored.capability,
                    exactBytes: stored.exactBytes, bytesDigest: stored.bytesDigest,
                    acknowledgedOffset: stored.acknowledgedOffset,
                    expiresAt: Date(timeIntervalSince1970: 0), lifecycle: stored.lifecycle
                ), scope: productionScope)
                expiredUpload = transfer.uploadID
                uploaded.remove(transfer.uploadID)
            }
        case let .command(command):
            if command.commandKind == "registerSnapshot" {
                #expect(!uploaded.isEmpty)
                #expect(finalized == uploaded)
            }
            if command.commandKind == "finalizeObject" {
                let payload = try productionPayload(command)
                let id = try #require(try UUID(uuidString: productionString(payload, key: "uploadId")))
                #expect(id != expiredUpload)
                #expect(uploaded.contains(id))
                // Use the exact pre-commit error body emitted by the server.
                let client = try ProductionSyncV2RemoteClient(
                    origin: ProductionHTTPSOrigin(url: #require(URL(string: "https://expiry.test"))),
                    vault: InMemoryAuthSessionVault()
                )
                let responseURL = try #require(URL(string: "https://expiry.test/v2/objects/finalize"))
                let response = try #require(HTTPURLResponse(
                    url: responseURL,
                    statusCode: 409, httpVersion: nil,
                    headerFields: ["Content-Type": "application/vnd.fuminiwa.sync.v2+jcs",
                                   "Cache-Control": "no-store", "Pragma": "no-cache"]
                ))
                await #expect(throws: SyncV2Failure.retryable(.uploadExpired)) {
                    _ = try await client.decode(
                        data: Data(#"{"error":"uploadExpired","result":"parked","retryable":false}"#.utf8),
                        response: response, command: command
                    )
                }
                finalized.insert(id)
            }
            if command.commandKind == "publish" {
                let payload = try productionPayload(command)
                #expect(payload["expectedRemoteHead"] is NSNull)
                published = true
            }
            let head = command.commandKind == "publish"
                ? try V2RemoteHead(snapshotID: command.sourceSnapshotId, generation: 1) : nil
            let status = ["createWork", "prepareObject"].contains(command.commandKind) ? 201 : 200
            let response = try productionResponse(command: command, result: .applied, head: head, cloneHead: nil, status: status)
            let envelope = try productionEnvelope(command: command, response: response, result: .applied, status: status)
            try await store.acknowledge(V2CommandAcknowledgement(
                commandID: command.commandId, canonicalReceiptEnvelope: envelope
            ), scope: productionScope)
        case .idle:
            #expect(published)
            #expect(try await store.pendingIntents(scope: productionScope, workID: workID).isEmpty)
            await store.close()
            return
        default:
            Issue.record("transfer stopped before publication")
            await store.close()
            return
        }
    }
    Issue.record("transfer did not reach registration")
    await store.close()
}

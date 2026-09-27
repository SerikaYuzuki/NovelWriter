import Foundation
import NovelSyncV2
@testable import NovelSyncV2Application
@testable import NovelSyncV2Runtime
import NovelSyncV2Store
import Testing

@Test("offline checkpoints register parents before the latest snapshot, including after restart", arguments: [false, true])
func offlineCheckpointsRegisterParents(restartEveryStep: Bool) async throws {
    let config = try TestRuntimeConfiguration()
    let store = try LocalSyncV2Store(root: config.localRoot.url, policy: .createNew)
    let workID = WorkID(UUID())
    var document = applicationTestDocument(title: "offline", body: "first")
    var expectedSnapshots: [SnapshotID] = []
    for generation in 0 ..< 3 {
        document.title = "offline \(generation)"
        let saved = try await store.checkpoint(V2CheckpointRequest(
            workID: workID, document: document, documentCreatedAt: applicationTestCreatedAt,
            expectedGeneration: Int64(generation)
        ), scope: productionScope)
        expectedSnapshots.append(saved.snapshotID)
    }
    let scope = TestScopeResolver(vault: config.vault, store: store)
    var planner = ProductionSyncV2Planner(store: store, scope: scope)
    var registered: [SnapshotID] = []
    var published: [SnapshotID] = []
    var uploaded = Set<ObjectID>()
    var available = Set<ObjectID>()
    for _ in 0 ..< 250 {
        if restartEveryStep {
            planner = ProductionSyncV2Planner(store: store, scope: scope)
        }
        switch try await planner.nextCommand(workID: workID) {
        case let .upload(transfer):
            uploaded.insert(transfer.objectID)
            try await planner.acknowledgeUpload(SyncV2UploadCompletion(
                transferID: transfer.transferID, uploadID: transfer.uploadID,
                objectID: transfer.objectID, acknowledgedByteCount: transfer.exactBytes.count
            ))
        case let .command(command):
            let payload = try productionPayload(command)
            var result = V2CommandTerminalResult.applied
            var status = ["createWork", "prepareObject"].contains(command.commandKind) ? 201 : 200
            if command.commandKind == "prepareObject" {
                let object = try ObjectID(rawValue: productionString(payload, key: "objectId"))
                if available.contains(object) {
                    result = .noChanges; status = 200
                }
            }
            if command.commandKind == "finalizeObject" {
                let object = try ObjectID(rawValue: productionString(payload, key: "objectId"))
                #expect(uploaded.contains(object))
                available.insert(object)
            }
            if command.commandKind == "registerSnapshot" {
                let raw = try productionString(payload, key: "manifestBase64URL")
                let data = try #require(Data(base64Encoded: raw.replacingOccurrences(of: "-", with: "+")
                        .replacingOccurrences(of: "_", with: "/") + String(repeating: "=", count: (4 - raw.count % 4) % 4)))
                let manifest = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
                let parents = try #require(manifest["parentSnapshotIds"] as? [String])
                // Same prerequisites as the server's registration transaction.
                #expect(Set(parents).isSubset(of: Set(registered.map(\.rawValue))))
                let entries = try #require(manifest["entries"] as? [[String: Any]])
                for entry in entries {
                    let rawObject = try #require(entry["objectId"] as? String)
                    #expect(try available.contains(ObjectID(rawValue: rawObject)))
                }
                #expect(command.sourceGeneration == Int64(registered.count + 1))
                registered.append(command.sourceSnapshotId)
            }
            if command.commandKind == "publish" {
                #expect(registered == expectedSnapshots)
                #expect(command.sourceSnapshotId == expectedSnapshots.last)
                #expect(command.sourceGeneration == 3)
                published.append(command.sourceSnapshotId)
            }
            let head = command.commandKind == "publish"
                ? try V2RemoteHead(snapshotID: command.sourceSnapshotId, generation: 1) : nil
            let response = try productionResponse(command: command, result: result, head: head, cloneHead: nil, status: status)
            let envelope = try productionEnvelope(command: command, response: response, result: result, status: status)
            try await store.acknowledge(V2CommandAcknowledgement(
                commandID: command.commandId, canonicalReceiptEnvelope: envelope
            ), scope: productionScope)
        case .idle:
            #expect(registered == expectedSnapshots)
            #expect(published == [expectedSnapshots[2]])
            #expect(try await store.pendingIntents(scope: productionScope, workID: workID).isEmpty)
            #expect(try await store.open(workID: workID, scope: productionScope).document == document)
            await store.close()
            return
        default:
            Issue.record("offline lineage transfer stopped")
            await store.close()
            return
        }
    }
    Issue.record("offline lineage transfer did not finish")
    await store.close()
}

@Test("concurrent planning seals one publish intent after a verified download")
func concurrentPlanningSealsOnePublish() async throws {
    let config = try TestRuntimeConfiguration()
    let store = try LocalSyncV2Store(root: config.localRoot.url, policy: .createNew)
    let workID = WorkID(UUID())
    let snapshot = try SnapshotCodec.encode(SnapshotModel(
        workId: workID, document: applicationTestDocument(title: "verified"),
        documentCreatedAt: applicationTestCreatedAt
    ), parents: [])
    let inbox = try V2RemoteSnapshot(
        workID: workID, encoded: snapshot,
        expectedCurrentSnapshotID: nil, expectedLocalGeneration: 0,
        expectedRemoteHead: V2RemoteHead(snapshotID: snapshot.snapshotId, generation: 1)
    )
    try await store.stageRemote(inbox, scope: productionScope)
    try await store.verifyInbox(inboxID: inbox.inboxID, scope: productionScope)
    try await store.adoptInbox(inboxID: inbox.inboxID, scope: productionScope)
    let planner = ProductionSyncV2Planner(
        store: store, scope: TestScopeResolver(vault: config.vault, store: store)
    )
    try await planner.requestSynchronization(workID: workID)
    let ids = try await withThrowingTaskGroup(of: UUID.self) { group in
        for _ in 0 ..< 20 {
            group.addTask {
                let plan = try await planner.nextCommand(workID: workID)
                guard case let .command(command) = plan else {
                    throw SyncV2Failure.fatal(.unexpected)
                }
                #expect(command.commandKind == "publish")
                return command.commandId
            }
        }
        var ids = Set<UUID>()
        for try await id in group {
            ids.insert(id)
        }
        return ids
    }
    #expect(ids.count == 1)
    #expect(try await store.allSealedCommands(scope: productionScope, workID: workID).count == 1)
    await store.close()
}

import Foundation
import NovelCore
import NovelSyncV2
@testable import NovelSyncV2Application
@testable import NovelSyncV2Runtime
@testable import NovelSyncV2Store
import Testing

private actor PresenceLoadSpy {
    private var counts: [WorkID: Int] = [:]

    func load(store: LocalSyncV2Store, workID: WorkID, scope: V2LocalWorkScope) async throws -> Set<ObjectID> {
        counts[workID, default: 0] += 1
        return try await store.knownRemoteObjectIDs(workID: workID, scope: scope)
    }

    func count(_ workID: WorkID) -> Int {
        counts[workID, default: 0]
    }
}

/// Drives real sealing, upload persistence and verified receipts against a
/// synthetic server's available-object set. No network or existing DB is used.
private func drainPresencePlanner(
    _ planner: ProductionSyncV2Planner, workID: WorkID,
    available: inout Set<ObjectID>, remoteGeneration: inout Int64
) async throws -> [ObjectID] {
    var prepared: [ObjectID] = []
    for _ in 0 ..< 2500 {
        switch try await planner.nextCommand(workID: workID) {
        case .idle: return prepared
        case let .upload(transfer):
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
                prepared.append(object)
                if available.contains(object) {
                    result = .noChanges; status = 200
                }
            }
            if command.commandKind == "finalizeObject" {
                try available.insert(ObjectID(rawValue: productionString(payload, key: "objectId")))
            }
            let head: V2RemoteHead?
            if command.commandKind == "publish" {
                remoteGeneration += 1
                head = try V2RemoteHead(snapshotID: command.sourceSnapshotId, generation: remoteGeneration)
            } else {
                head = nil
            }
            let response = try productionResponse(command: command, result: result, head: head, cloneHead: nil, status: status)
            let envelope = try productionEnvelope(command: command, response: response, result: result, status: status)
            try await planner.acknowledgeCommand(SyncV2ReceiptReadback(
                commandID: command.commandId, requestDigest: command.requestDigest,
                responseStatus: status, canonicalResponse: envelope,
                predicates: SyncV2ReadBackPredicates(accountMatched: true, commandDigestMatched: true,
                                                     resourceMatched: true, headMatched: true, stateMatched: true),
                result: result == .noChanges ? .noChanges : .applied
            ), command: command, verifiedInboxID: nil)
        default: throw SyncV2Failure.fatal(.unexpected)
        }
    }
    throw SyncV2Failure.fatal(.unexpected)
}

@Test("presence loads once across long history and checkpoints, and reloads after binding changes")
func plannerPresenceLoadIsIndependentOfCheckpointCount() async throws {
    let config = try TestRuntimeConfiguration()
    defer { try? FileManager.default.removeItem(at: config.localRoot.url) }
    let store = try LocalSyncV2Store(root: config.localRoot.url, policy: .createNew)
    let resolver = TestScopeResolver(vault: config.vault, store: store)
    let workID = WorkID(UUID())
    var document = applicationTestDocument(title: "history", body: "unchanged body")
    for generation in 0 ..< 256 {
        document.title = "history-\(generation)"
        _ = try await store.checkpoint(V2CheckpointRequest(workID: workID, document: document,
                                                           documentCreatedAt: applicationTestCreatedAt,
                                                           expectedGeneration: Int64(generation)), scope: productionScope)
    }
    var available = Set<ObjectID>()
    var remoteGeneration: Int64 = 0
    _ = try await drainPresencePlanner(ProductionSyncV2Planner(store: store, scope: resolver), workID: workID,
                                       available: &available, remoteGeneration: &remoteGeneration)
    #expect(try await store.allSealedCommands(scope: productionScope, workID: workID).count > 750)

    // A fresh planner loads historical evidence through the actual store API.
    let spy = PresenceLoadSpy()
    let planner = ProductionSyncV2Planner(store: store, scope: resolver, loadKnownRemoteObjects: { work, scope in
        try await spy.load(store: store, workID: work, scope: scope)
    })
    var generation: Int64 = 256
    for index in 0 ..< 8 {
        // Alternate entities so the preceding checkpoint's newly finalized
        // object remains necessary on the next checkpoint.
        if index.isMultiple(of: 2) {
            document.title = "new title-\(index)"
        } else {
            document.chapters[0].episodes[0].content = "new body-\(index)"
        }
        let saved = try await store.checkpoint(V2CheckpointRequest(workID: workID, document: document,
                                                                   documentCreatedAt: applicationTestCreatedAt,
                                                                   expectedGeneration: generation), scope: productionScope)
        generation = saved.generation
        let prepared = try await drainPresencePlanner(planner, workID: workID, available: &available,
                                                      remoteGeneration: &remoteGeneration)
        #expect(prepared.count == 1)
        #expect(await spy.count(workID) == 1)
        if index == 0 {
            // An unrelated work must not evict the first work's load marker.
            let other = WorkID(UUID())
            _ = try await store.checkpoint(V2CheckpointRequest(workID: other, document: applicationTestDocument(title: "other"),
                                                               documentCreatedAt: applicationTestCreatedAt, expectedGeneration: 0),
                                           scope: productionScope)
            var otherGeneration: Int64 = 0
            _ = try await drainPresencePlanner(planner, workID: other, available: &available, remoteGeneration: &otherGeneration)
            #expect(await spy.count(other) == 1)
        }
    }
    let newBinding = V2AccountBinding(accountID: productionBinding.accountID, accountFence: "new-fence",
                                      serverInstanceID: productionBinding.serverInstanceID)
    try await store.rebindWork(workID: workID, from: productionBinding, to: newBinding)
    await config.vault.replaceAccount(TestAccount(accountID: newBinding.accountID, accountFence: newBinding.accountFence))
    document.title = "after binding change"
    _ = try await store.checkpoint(V2CheckpointRequest(workID: workID, document: document,
                                                       documentCreatedAt: applicationTestCreatedAt, expectedGeneration: generation),
                                   scope: .bound(newBinding))
    generation += 1
    let reboundPrepares = try await drainPresencePlanner(planner, workID: workID, available: &available,
                                                         remoteGeneration: &remoteGeneration)
    // A new fence clears the acknowledged head. Old-fence evidence must not
    // leak into the new lane: the synthetic server reconfirms it via noChanges.
    #expect(reboundPrepares.count > 1)
    #expect(await spy.count(workID) == 2)

    await planner.invalidateCaches(for: [workID])
    document.title = "after explicit invalidation"
    _ = try await store.checkpoint(V2CheckpointRequest(workID: workID, document: document,
                                                       documentCreatedAt: applicationTestCreatedAt, expectedGeneration: generation),
                                   scope: .bound(newBinding))
    #expect(try await drainPresencePlanner(planner, workID: workID, available: &available,
                                           remoteGeneration: &remoteGeneration).count == 1)
    #expect(await spy.count(workID) == 3)
    await store.close()
}

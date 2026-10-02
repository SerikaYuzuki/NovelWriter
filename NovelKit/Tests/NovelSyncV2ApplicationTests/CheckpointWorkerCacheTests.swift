import Foundation
import NovelCore
import NovelSyncV2
@testable import NovelSyncV2Application
@testable import NovelSyncV2Runtime
@testable import NovelSyncV2Store
import Testing

@Test(arguments: [false, true])
func checkpointCacheWithUploadAcknowledgements(syncOn: Bool) async throws {
    let config = try TestRuntimeConfiguration(account: syncOn ? TestAccount(
        accountID: "test-account",
        accountFence: "test-fence"
    ) : nil)
    defer { try? FileManager.default.removeItem(at: config.localRoot.url) }
    let store = try LocalSyncV2Store(root: config.localRoot.url, policy: .createNew)
    let resolver = TestScopeResolver(vault: config.vault, store: store)
    let kernel = ProductionSyncV2Kernel(store: store, scope: resolver)
    let app = try SyncV2Application(mode: .test(config), composition: SyncV2RuntimeComposition(
        identity: .test, kernel: kernel, planner: ProductionSyncV2Planner(store: store, scope: resolver),
        remote: config.remote, gate: InMemorySyncV2DocumentGate(), library: kernel
    ))
    await config.remote.setCommandHandler { command in try cacheWorkerExecution(command) }
    let work = WorkID(UUID())
    var document = applicationTestDocument()
    var hits = 0
    for index in 0 ..< 7 {
        document.chapters[0].episodes[0].content += "字"
        let before = await store.checkpointFullValidationCount
        _ = try await app.checkpoint(workID: work, document: document, reason: .autosave,
                                     documentCreatedAt: applicationTestCreatedAt)
        if index > 0, await store.checkpointFullValidationCount == before {
            hits += 1
        }
        if syncOn {
            let snapshot = try #require(await store.workSummary(workID: work, scope: productionScope).currentSnapshotID)
            try await drainCacheWorker(app: app, store: store, work: work, snapshot: snapshot)
        }
        await app.cancelLeafPromotion(workID: work)
        await app.cancelWorker(for: work)
    }
    #expect(hits == 6)
    let operations = await config.remote.recordedOperations()
    let uploads = operations.count {
        if case .upload = $0 {
            true
        } else {
            false
        }
    }
    #expect(!syncOn || uploads > 0)
    await print(
        "CACHE worker syncOn=\(syncOn) hits=\(hits)/6 " +
            "fullValidations=\(store.checkpointFullValidationCount) uploads=\(uploads)"
    )
    await store.close()
}

private func cacheWorkerExecution(_ sealed: SyncV2SealedRemoteCommand) throws -> SyncV2RemoteExecution {
    let command = sealed.command
    let payload = try productionPayload(command)
    let head: V2RemoteHead? = if sealed.kind == .publish {
        try V2RemoteHead(snapshotID: SnapshotID(rawValue: productionString(payload, key: "candidateSnapshotId")),
                         generation: command.sourceGeneration)
    } else {
        nil
    }
    let status = [.createWork, .prepareObject].contains(sealed.kind) ? 201 : 200
    let response = try productionResponse(
        command: command,
        result: .applied,
        head: head,
        cloneHead: nil,
        status: status
    )
    return try .command(receipt: SyncV2ReceiptReadback(
        commandID: command.commandId, requestDigest: command.requestDigest, responseStatus: status,
        canonicalResponse: productionEnvelope(command: command, response: response, result: .applied, status: status),
        predicates: SyncV2ReadBackPredicates(accountMatched: true, commandDigestMatched: true, resourceMatched: true,
                                             headMatched: true, stateMatched: true),
        result: .applied, remoteHead: head.flatMap { try? SyncV2RemoteHead(
            snapshotID: $0.snapshotID,
            generation: $0.generation
        ) }
    ), remoteInbox: nil)
}

private func drainCacheWorker(app: SyncV2Application, store: LocalSyncV2Store,
                              work: WorkID, snapshot: SnapshotID) async throws {
    // Advance the usual promotion boundary, then run the real planner/worker.
    _ = try await app.synchronize(workID: work)
    try await eventually(timeout: .seconds(10)) {
        if let failure = await app.uiState(workID: work)?.lastFailure {
            throw failure
        }
        return try await store.isAcknowledgedContent(workID: work, snapshotID: snapshot, scope: productionScope)
    }
    try await eventually {
        let commands = try await store.pendingSealedCommands(scope: productionScope, workID: work)
        let intents = try await store.pendingIntents(scope: productionScope, workID: work)
        return commands.isEmpty && intents.isEmpty
    }
}

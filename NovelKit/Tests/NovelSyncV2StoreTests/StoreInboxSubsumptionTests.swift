import Foundation
import NovelCore
import NovelSyncV2
import NovelSyncV2Store
import Testing

@Test
func pendingIntentSubsumptionSurvivesRestartAndReplaysExactly() async throws {
    let root = temporaryStoreRoot("inbox-subsumption-restart")
    defer { try? FileManager.default.removeItem(at: root) }
    let workID = WorkID(UUID())
    let store = try LocalSyncV2Store(root: root, policy: .createNew)
    let localDocument = makeDocument(title: "local")
    let local = try await store.checkpoint(
        V2CheckpointRequest(
            workID: workID,
            document: localDocument,
            documentCreatedAt: testDate,
            expectedGeneration: 0
        ),
        scope: scopeA
    )
    let graph = try descendantGraph(
        workID: workID,
        localDocument: localDocument,
        local: local
    )
    try await store.stageRemoteGraph(graph, scope: scopeA)
    try await store.verifyInbox(inboxID: graph.inboxID, scope: scopeA)
    await store.close()

    let reopened = try LocalSyncV2Store(root: root, policy: .openExisting)
    let intentID = try #require(local.intentID)
    try await reopened.adoptInboxSubsumingPendingIntent(
        inboxID: graph.inboxID,
        intentID: intentID,
        scope: scopeA
    )
    try await reopened.adoptInboxSubsumingPendingIntent(
        inboxID: graph.inboxID,
        intentID: intentID,
        scope: scopeA
    )

    let opened = try await reopened.open(workID: workID, scope: scopeA)
    let history = try await reopened.history(workID: workID, scope: scopeA)
    #expect(opened.document?.title == "remote descendant")
    #expect(opened.summary.currentSnapshotID == graph.headSnapshotID)
    #expect(opened.summary.localGeneration == local.generation + 1)
    #expect(opened.summary.acknowledgedHeadGeneration == 2)
    #expect(try await reopened.pendingIntents(scope: scopeA).isEmpty)
    #expect(history.contains {
        $0.snapshotID == local.snapshotID &&
            $0.reason == "preRemoteAdoption" && $0.pinned
    })
}

@Test
func sealedIntentCannotUseLineageAsAReceipt() async throws {
    let root = temporaryStoreRoot("inbox-subsumption-sealed")
    defer { try? FileManager.default.removeItem(at: root) }
    let workID = WorkID(UUID())
    let store = try LocalSyncV2Store(root: root, policy: .createNew)
    let localDocument = makeDocument(title: "local")
    let local = try await store.checkpoint(
        V2CheckpointRequest(
            workID: workID,
            document: localDocument,
            documentCreatedAt: testDate,
            expectedGeneration: 0
        ),
        scope: scopeA
    )
    let intentID = try #require(local.intentID)
    let command = try publishCommand(workID: workID, checkpoint: local)
    try await store.seal(command, intentID: intentID, scope: scopeA)
    let graph = try descendantGraph(
        workID: workID,
        localDocument: localDocument,
        local: local
    )
    try await store.stageRemoteGraph(graph, scope: scopeA)
    try await store.verifyInbox(inboxID: graph.inboxID, scope: scopeA)

    do {
        try await store.adoptInboxSubsumingPendingIntent(
            inboxID: graph.inboxID,
            intentID: intentID,
            scope: scopeA
        )
        Issue.record("sealed Intent was cleared without its exact receipt")
    } catch SyncV2StoreError.staleCAS {}

    let opened = try await store.open(workID: workID, scope: scopeA)
    #expect(opened.summary.currentSnapshotID == local.snapshotID)
    #expect(try await store.pendingIntents(scope: scopeA).map(\.intentID) == [intentID])
    #expect(try await store.pendingSealedCommands(scope: scopeA).map(\.commandID) == [
        command.commandId
    ])
}

@Test
func concurrentEditAndSubsumptionPreserveExactlyOneCurrentBranch() async throws {
    let root = temporaryStoreRoot("inbox-subsumption-race")
    defer { try? FileManager.default.removeItem(at: root) }
    let workID = WorkID(UUID())
    let firstStore = try LocalSyncV2Store(root: root, policy: .createNew)
    let localDocument = makeDocument(title: "local")
    let local = try await firstStore.checkpoint(
        V2CheckpointRequest(
            workID: workID,
            document: localDocument,
            documentCreatedAt: testDate,
            expectedGeneration: 0
        ),
        scope: scopeA
    )
    let graph = try descendantGraph(
        workID: workID,
        localDocument: localDocument,
        local: local
    )
    try await firstStore.stageRemoteGraph(graph, scope: scopeA)
    try await firstStore.verifyInbox(inboxID: graph.inboxID, scope: scopeA)
    let secondStore = try LocalSyncV2Store(root: root, policy: .openExisting)
    let intentID = try #require(local.intentID)
    var editedDocument = localDocument
    editedDocument.title = "local concurrent edit"

    async let adopted = attemptSubsumption(
        store: firstStore,
        inboxID: graph.inboxID,
        intentID: intentID
    )
    async let edited = attemptCheckpoint(
        store: secondStore,
        workID: workID,
        document: editedDocument,
        generation: local.generation
    )
    let (didAdopt, edit) = await (adopted, edited)
    #expect(didAdopt != (edit != nil))

    let opened = try await firstStore.open(workID: workID, scope: scopeA)
    let pending = try await firstStore.pendingIntents(scope: scopeA, workID: workID)
    if didAdopt {
        #expect(opened.document?.title == "remote descendant")
        #expect(opened.summary.currentSnapshotID == graph.headSnapshotID)
        #expect(pending.isEmpty)
    } else {
        let edit = try #require(edit)
        #expect(opened.document?.title == "local concurrent edit")
        #expect(opened.summary.currentSnapshotID == edit.snapshotID)
        #expect(pending.map(\.sourceSnapshotID) == [edit.snapshotID])
    }
}

private func descendantGraph(
    workID: WorkID,
    localDocument: NovelDocument,
    local: V2CheckpointResult
) throws -> V2RemoteSnapshotGraph {
    var remoteDocument = localDocument
    remoteDocument.title = "remote descendant"
    let remote = try encodeSnapshot(
        workID: workID,
        document: remoteDocument,
        parents: [local.snapshotID]
    )
    return try V2RemoteSnapshotGraph(
        workID: workID,
        headSnapshotID: remote.snapshotId,
        snapshots: [remote],
        expectedCurrentSnapshotID: local.snapshotID,
        expectedLocalGeneration: local.generation,
        expectedRemoteHead: V2RemoteHead(snapshotID: remote.snapshotId, generation: 2)
    )
}

private func attemptSubsumption(
    store: LocalSyncV2Store,
    inboxID: UUID,
    intentID: UUID
) async -> Bool {
    do {
        try await store.adoptInboxSubsumingPendingIntent(
            inboxID: inboxID,
            intentID: intentID,
            scope: scopeA
        )
        return true
    } catch SyncV2StoreError.staleCAS {
        return false
    } catch {
        Issue.record("unexpected subsumption race failure: \(error)")
        return false
    }
}

private func attemptCheckpoint(
    store: LocalSyncV2Store,
    workID: WorkID,
    document: NovelDocument,
    generation: Int64
) async -> V2CheckpointResult? {
    do {
        return try await store.checkpoint(
            V2CheckpointRequest(
                workID: workID,
                document: document,
                documentCreatedAt: testDate,
                expectedGeneration: generation
            ),
            scope: scopeA
        )
    } catch SyncV2StoreError.generationMismatch {
        return nil
    } catch {
        Issue.record("unexpected checkpoint race failure: \(error)")
        return nil
    }
}

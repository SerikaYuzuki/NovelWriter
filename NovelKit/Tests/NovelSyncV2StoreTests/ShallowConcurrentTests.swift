import Foundation
import NovelSyncV2
@testable import NovelSyncV2Store
import Testing

@Test func newerInboxHeadCanAdvanceWhileBackfillStaysPinned() async throws {
    let root = temporaryStoreRoot("shallow-inbox")
    defer { try? FileManager.default.removeItem(at: root) }
    let fixture = try ShallowFixture()
    let store = try LocalSyncV2Store(root: root, policy: .createNew)
    try await store.installShallowHead(fixture.graph, scope: scopeA)
    var document = try #require(try await store.open(workID: fixture.workID, scope: scopeA).document)
    document.title = "H1"
    let next = try encodeSnapshot(workID: fixture.workID, document: document, parents: [fixture.head.snapshotId])
    let graph = V2RemoteSnapshotGraph(workID: fixture.workID, headSnapshotID: next.snapshotId, snapshots: [next],
                                      expectedCurrentSnapshotID: fixture.head.snapshotId, expectedLocalGeneration: 1,
                                      expectedRemoteHead: V2RemoteHead(validatedSnapshotID: next.snapshotId, generation: 2))
    try await store.stageRemoteGraph(graph, scope: scopeA)
    try await store.verifyInbox(inboxID: graph.inboxID, scope: scopeA)
    try await store.adoptInbox(inboxID: graph.inboxID, scope: scopeA)
    #expect(try await store.backfillState(workID: fixture.workID)?.rootSnapshotID == fixture.head.snapshotId)
    try await store.applyBackfillPage(fixture.page(), workID: fixture.workID, binding: bindingA,
                                      root: fixture.head.snapshotId, expectedCursor: nil)
    #expect(try await store.open(workID: fixture.workID, scope: scopeA).document?.title == "H1")
    await store.close()
}

@Test func explicitLocalPurgeRemovesShallowTablesAndRestoresTriggers() async throws {
    let root = temporaryStoreRoot("shallow-purge")
    defer { try? FileManager.default.removeItem(at: root) }
    let fixture = try ShallowFixture()
    let store = try LocalSyncV2Store(root: root, policy: .createNew)
    try await store.installShallowHead(fixture.graph, scope: scopeA)
    // Exercise the complete physical purge using a disposable local deletion
    // journal. Ordinary bound-work deletion still keeps the rescue graph.
    try await store.exec("INSERT INTO work_deletions(work_id,phase,created_at) VALUES(?,'pending',?)",
                         [.text(fixture.workID.description), .text("2026-10-02T00:00:00.000Z")])
    let deletion = try #require(try await store.workDeletion(workID: fixture.workID))
    try await store.completeWorkDeletion(deletion)
    for table in ["history_backfills", "shallow_boundaries", "snapshots", "snapshot_parents"] {
        #expect(try await store.query("SELECT COUNT(*) FROM \(table)").first?.scalar.int64 == 0)
    }
    await store.close()
    let reopened = try LocalSyncV2Store(root: root, policy: .openExisting)
    await reopened.close()
}

@Test(.enabled(if: ProcessInfo.processInfo.environment["FUMINIWA_IMPORT_BENCHMARK"] == "1"))
func backfill256ItemsWriteLockUnder100ms() async throws {
    let root = temporaryStoreRoot("shallow-lock-budget")
    defer { try? FileManager.default.removeItem(at: root) }
    // One new title object and one manifest per ancestor: 256 wire items.
    let fixture = try ShallowFixture(count: 129)
    let store = try LocalSyncV2Store(root: root, policy: .createNew)
    try await store.installShallowHead(fixture.graph, scope: scopeA)
    try await store.applyBackfillPage(fixture.page(), workID: fixture.workID, binding: bindingA,
                                      root: fixture.head.snapshotId, expectedCursor: nil)
    let held = try #require(await store.lastBackfillWriteDuration)
    print("BENCH backfill 256 items BEGIN IMMEDIATE-through-COMMIT \(held)")
    #expect(held < .milliseconds(100))
    await store.close()
}

@Test func boundaryAncestorWithDifferentDocumentAnchorIsRejected() async throws {
    let root = temporaryStoreRoot("shallow-anchor")
    defer { try? FileManager.default.removeItem(at: root) }
    let workID = WorkID(UUID())
    let parent = try encodeSnapshot(workID: workID, document: makeDocument(title: "different anchor"))
    let head = try encodeSnapshot(workID: workID, document: makeDocument(title: "head"), parents: [parent.snapshotId])
    let store = try LocalSyncV2Store(root: root, policy: .createNew)
    try await store.installShallowHead(V2RemoteSnapshotGraph(workID: workID, headSnapshotID: head.snapshotId,
                                                             snapshots: [head], expectedCurrentSnapshotID: nil, expectedLocalGeneration: 0,
                                                             expectedRemoteHead: V2RemoteHead(validatedSnapshotID: head.snapshotId, generation: 1)), scope: scopeA)
    await #expect(throws: SyncV2StoreError.invalidSnapshot) {
        try await store.applyBackfillPage(V2BackfillPage(snapshots: [parent], resumeCursor: nil, terminal: true),
                                          workID: workID, binding: bindingA, root: head.snapshotId, expectedCursor: nil)
    }
    #expect(try await store.query("SELECT COUNT(*) FROM snapshots").first?.scalar.int64 == 1)
    await store.close()
}

@Test func ordinaryFullWorksStillRequireEveryParentRow() async throws {
    let root = temporaryStoreRoot("ordinary-full-attestation")
    defer { try? FileManager.default.removeItem(at: root) }
    let fixture = try ShallowFixture()
    let store = try LocalSyncV2Store(root: root, policy: .createNew)
    try await store.installInitialGraph(V2RemoteSnapshotGraph(workID: fixture.workID, headSnapshotID: fixture.head.snapshotId,
                                                              snapshots: fixture.snapshots, expectedCurrentSnapshotID: nil, expectedLocalGeneration: 0,
                                                              expectedRemoteHead: fixture.graph.expectedRemoteHead), scope: scopeA)
    #expect(try await store.backfillState(workID: fixture.workID) == nil)
    try await store.exec("DROP TRIGGER snapshot_parents_immutable_delete")
    try await store.exec("DELETE FROM snapshot_parents WHERE snapshot_id=?", [.blob(fixture.head.snapshotId.bytes)])
    await #expect(throws: SyncV2StoreError.invalidSnapshot) {
        try await store.open(workID: fixture.workID, scope: scopeA)
    }
    await store.close()
}

@Test func incompleteConflictBaseNeverBecomesNilOrDisjoint() async throws {
    let root = temporaryStoreRoot("incomplete-base")
    defer { try? FileManager.default.removeItem(at: root) }
    let fixture = try ShallowFixture()
    let store = try LocalSyncV2Store(root: root, policy: .createNew)
    try await store.installShallowHead(fixture.graph, scope: scopeA)
    var document = try #require(try await store.open(workID: fixture.workID, scope: scopeA).document)
    document.title = "apparently disjoint"
    let remote = try encodeSnapshot(workID: fixture.workID, document: document)
    let graph = V2RemoteSnapshotGraph(workID: fixture.workID, headSnapshotID: remote.snapshotId, snapshots: [remote],
                                      expectedCurrentSnapshotID: fixture.head.snapshotId, expectedLocalGeneration: 1,
                                      expectedRemoteHead: V2RemoteHead(validatedSnapshotID: remote.snapshotId, generation: 2))
    for base: SnapshotID? in [nil, fixture.snapshots[0].snapshotId] {
        await #expect(throws: SyncV2StoreError.historyIncomplete) {
            try await store.validateConflictBase(base, localSnapshotID: fixture.head.snapshotId,
                                                 remoteSnapshotID: remote.snapshotId, workID: fixture.workID, graph: graph)
        }
    }
    await store.close()
}

@Test func ordinaryConflictAboveMaterializedHeadRemainsAvailable() async throws {
    let root = temporaryStoreRoot("shallow-ordinary-conflict")
    defer { try? FileManager.default.removeItem(at: root) }
    let fixture = try ShallowFixture()
    let store = try LocalSyncV2Store(root: root, policy: .createNew)
    try await store.installShallowHead(fixture.graph, scope: scopeA)
    var document = try #require(try await store.open(workID: fixture.workID, scope: scopeA).document)
    document.title = "local branch"
    let local = try await store.checkpoint(V2CheckpointRequest(workID: fixture.workID, document: document,
                                                               documentCreatedAt: testDate, expectedGeneration: 1, reason: .explicit), scope: scopeA)
    document.title = "remote branch"
    let remote = try encodeSnapshot(workID: fixture.workID, document: document, parents: [fixture.head.snapshotId])
    let graph = V2RemoteSnapshotGraph(workID: fixture.workID, headSnapshotID: remote.snapshotId, snapshots: [remote],
                                      expectedCurrentSnapshotID: local.snapshotID, expectedLocalGeneration: 2,
                                      expectedRemoteHead: V2RemoteHead(validatedSnapshotID: remote.snapshotId, generation: 2))
    try await store.validateConflictBase(fixture.head.snapshotId, localSnapshotID: local.snapshotID,
                                         remoteSnapshotID: remote.snapshotId, workID: fixture.workID, graph: graph)
    #expect(try await store.pendingIntents(scope: scopeA, workID: fixture.workID).count == 1)
    await store.close()
}

@Test func editPromoteAndPublishUsePinnedHeadDuringBackfill() async throws {
    let root = temporaryStoreRoot("shallow-publish")
    defer { try? FileManager.default.removeItem(at: root) }
    let fixture = try ShallowFixture()
    let store = try LocalSyncV2Store(root: root, policy: .createNew)
    try await store.installShallowHead(fixture.graph, scope: scopeA)
    var document = try #require(try await store.open(workID: fixture.workID, scope: scopeA).document)
    document.title = "published while backfilling"
    let checkpoint = try await store.checkpoint(V2CheckpointRequest(workID: fixture.workID, document: document,
                                                                    documentCreatedAt: testDate, expectedGeneration: 1, reason: .autosave), scope: scopeA)
    #expect(try await store.promoteCurrentLeaf(workID: fixture.workID, scope: scopeA))
    let transfer = try #require(try await store.immutableTransferView(workID: fixture.workID, scope: scopeA))
    #expect(transfer.expectedRemoteHead == fixture.graph.expectedRemoteHead)
    let publish = try publishCommand(workID: fixture.workID, checkpoint: checkpoint,
                                     expectedHead: fixture.graph.expectedRemoteHead)
    try await store.seal(publish, intentID: transfer.pendingIntent.intentID, scope: scopeA)
    let publishedHead = try V2RemoteHead(snapshotID: checkpoint.snapshotID, generation: 2)
    try await store.acknowledge(commandAcknowledgement(publish, head: publishedHead), scope: scopeA)
    #expect(try await store.backfillState(workID: fixture.workID)?.rootSnapshotID == fixture.head.snapshotId)
    try await store.applyBackfillPage(fixture.page(), workID: fixture.workID, binding: bindingA,
                                      root: fixture.head.snapshotId, expectedCursor: nil)
    #expect(try await store.open(workID: fixture.workID, scope: scopeA).document?.title == document.title)
    #expect(try await store.pendingIntents(scope: scopeA, workID: fixture.workID).isEmpty)
    await store.close()
}

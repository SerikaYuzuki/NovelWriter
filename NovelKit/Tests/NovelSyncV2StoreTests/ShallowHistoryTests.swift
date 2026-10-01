import Foundation
import NovelSyncV2
@testable import NovelSyncV2Store
import Testing

struct ShallowFixture {
    let workID = WorkID(UUID())
    let snapshots: [EncodedSnapshot]

    init(count: Int = 4) throws {
        var document = makeDocument(title: "history")
        var values: [EncodedSnapshot] = []
        for index in 0 ..< count {
            document.title = "version \(index)"
            try values.append(encodeSnapshot(workID: workID, document: document,
                                             parents: values.last.map { [$0.snapshotId] } ?? []))
        }
        snapshots = values
    }

    var head: EncodedSnapshot {
        snapshots.last!
    }

    var graph: V2RemoteSnapshotGraph {
        V2RemoteSnapshotGraph(workID: workID, headSnapshotID: head.snapshotId,
                              snapshots: [head], expectedCurrentSnapshotID: nil, expectedLocalGeneration: 0,
                              expectedRemoteHead: V2RemoteHead(validatedSnapshotID: head.snapshotId, generation: 1))
    }

    func page(_ values: [EncodedSnapshot]? = nil, cursor: String? = nil, terminal: Bool = true) -> V2BackfillPage {
        V2BackfillPage(snapshots: values ?? Array(snapshots.dropLast().reversed()), resumeCursor: cursor, terminal: terminal)
    }
}

@Test func shallowInstallOpensAndBackfillEqualsFullImport() async throws {
    let root = temporaryStoreRoot("shallow-equals-full")
    let fullRoot = temporaryStoreRoot("full-reference")
    defer { try? FileManager.default.removeItem(at: root); try? FileManager.default.removeItem(at: fullRoot) }
    let store = try LocalSyncV2Store(root: root, policy: .createNew)
    let full = try LocalSyncV2Store(root: fullRoot, policy: .createNew)
    let fixture = try ShallowFixture()
    try await store.installShallowHead(fixture.graph, scope: scopeA)
    let opened = try await store.open(workID: fixture.workID, scope: scopeA)
    #expect(opened.document?.title == "version 3")
    #expect(try await store.snapshotParents(workID: fixture.workID, snapshotID: fixture.head.snapshotId, scope: scopeA) == fixture.head.manifest.parentSnapshotIds)
    #expect(try await store.backfillState(workID: fixture.workID)?.status == .running)
    try await store.applyBackfillPage(fixture.page(), workID: fixture.workID, binding: bindingA,
                                      root: fixture.head.snapshotId, expectedCursor: nil)
    let graph = V2RemoteSnapshotGraph(workID: fixture.workID, headSnapshotID: fixture.head.snapshotId,
                                      snapshots: fixture.snapshots, expectedCurrentSnapshotID: nil, expectedLocalGeneration: 0,
                                      expectedRemoteHead: fixture.graph.expectedRemoteHead)
    try await full.installInitialGraph(graph, scope: scopeA)
    for table in ["snapshots", "snapshot_entries", "snapshot_parents", "objects"] {
        #expect(try await store.query("SELECT COUNT(*) FROM \(table)").first?[0].int64 == full.query("SELECT COUNT(*) FROM \(table)").first?[0].int64)
    }
    for snapshot in fixture.snapshots {
        let actual = try await store.committedSnapshot(workID: fixture.workID, snapshotID: snapshot.snapshotId, scope: scopeA)
        #expect(actual?.manifestBytes == snapshot.manifestBytes)
        #expect(actual?.objects == snapshot.objects)
    }
    #expect(try await store.backfillState(workID: fixture.workID)?.status == .complete)
    #expect(try await store.query("SELECT COUNT(*) FROM shallow_boundaries").first?[0].int64 == 0)
    await store.close(); await full.close()
}

@Test func backfillResumeAndFenceRestartPreserveNewEdits() async throws {
    let root = temporaryStoreRoot("shallow-resume")
    defer { try? FileManager.default.removeItem(at: root) }
    let fixture = try ShallowFixture()
    let store = try LocalSyncV2Store(root: root, policy: .createNew)
    try await store.installShallowHead(fixture.graph, scope: scopeA)
    try await store.applyBackfillPage(fixture.page([fixture.snapshots[2]], cursor: "closed", terminal: false),
                                      workID: fixture.workID, binding: bindingA, root: fixture.head.snapshotId, expectedCursor: nil)
    var opened = try await store.open(workID: fixture.workID, scope: scopeA)
    var document = try #require(opened.document)
    document.title = "unsent edit"
    let checkpoint = try await store.checkpoint(V2CheckpointRequest(workID: fixture.workID, document: document,
                                                                    documentCreatedAt: testDate, expectedGeneration: 1, reason: .explicit), scope: scopeA)
    await store.close()
    let reopened = try LocalSyncV2Store(root: root, policy: .openExisting)
    #expect(try await reopened.backfillState(workID: fixture.workID)?.resumeCursor == "closed")
    let rotated = V2AccountBinding(accountID: bindingA.accountID, accountFence: "rotated", serverInstanceID: bindingA.serverInstanceID)
    try await reopened.transitionAccountScopes(from: bindingA, to: rotated)
    let state = try await reopened.resumeBackfill(workID: fixture.workID, binding: rotated)
    #expect(state?.resumeCursor == nil)
    try await reopened.applyBackfillPage(fixture.page(), workID: fixture.workID, binding: rotated,
                                         root: fixture.head.snapshotId, expectedCursor: nil)
    opened = try await reopened.open(workID: fixture.workID, scope: .bound(rotated))
    #expect(opened.document?.title == "unsent edit")
    #expect(opened.summary.currentSnapshotID == checkpoint.snapshotID)
    #expect(try await reopened.backfillState(workID: fixture.workID)?.receivedSnapshots == 3)
    await reopened.close()
}

@Test(arguments: ["outside", "anchor", "digest", "cursor"])
func malformedBackfillIsAtomic(kind: String) async throws {
    let root = temporaryStoreRoot("shallow-invalid")
    defer { try? FileManager.default.removeItem(at: root) }
    let fixture = try ShallowFixture()
    let store = try LocalSyncV2Store(root: root, policy: .createNew)
    try await store.installShallowHead(fixture.graph, scope: scopeA)
    var snapshots = Array(fixture.snapshots.dropLast().reversed())
    if kind == "outside" || kind == "anchor" {
        try snapshots.append(encodeSnapshot(workID: fixture.workID, document: makeDocument(title: "unrelated")))
    } else if kind == "digest" {
        let original = snapshots[0]
        snapshots[0] = EncodedSnapshot(manifest: original.manifest, manifestBytes: Data("bad".utf8), objects: original.objects)
    }
    await #expect(throws: (any Error).self) {
        try await store.applyBackfillPage(fixture.page(snapshots), workID: fixture.workID, binding: bindingA,
                                          root: fixture.head.snapshotId, expectedCursor: kind == "cursor" ? "wrong" : nil)
    }
    #expect(try await store.query("SELECT COUNT(*) FROM snapshots").first?[0].int64 == 1)
    #expect(try await store.backfillState(workID: fixture.workID)?.resumeCursor == nil)
    await store.close()
}

@Test func shallowBoundaryTriggersAndOrdinaryAttestationRemainStrict() async throws {
    let root = temporaryStoreRoot("boundary-attestation")
    defer { try? FileManager.default.removeItem(at: root) }
    let fixture = try ShallowFixture(count: 2)
    let store = try LocalSyncV2Store(root: root, policy: .createNew)
    try await store.installShallowHead(fixture.graph, scope: scopeA)
    await #expect(throws: (any Error).self) { try await store.exec("DELETE FROM shallow_boundaries") }
    await #expect(throws: (any Error).self) { try await store.exec("UPDATE shallow_boundaries SET work_id=work_id") }
    try await store.applyBackfillPage(fixture.page(), workID: fixture.workID, binding: bindingA,
                                      root: fixture.head.snapshotId, expectedCursor: nil)
    try await store.exec("DROP TRIGGER snapshot_parents_immutable_delete")
    try await store.exec("DELETE FROM snapshot_parents")
    await #expect(throws: SyncV2StoreError.invalidSnapshot) {
        try await store.committedSnapshot(workID: fixture.workID, snapshotID: fixture.head.snapshotId, scope: scopeA)
    }
    await store.close()
}

@Test func incompleteLineageCannotProveDisjointness() async throws {
    let root = temporaryStoreRoot("incomplete-lineage")
    defer { try? FileManager.default.removeItem(at: root) }
    let fixture = try ShallowFixture()
    let store = try LocalSyncV2Store(root: root, policy: .createNew)
    try await store.installShallowHead(fixture.graph, scope: scopeA)
    await #expect(throws: SyncV2StoreError.historyIncomplete) {
        try await store.graphHead(fixture.graph, containsAncestor: fixture.snapshots[0].snapshotId)
    }
    #expect(try await store.graphHead(fixture.graph, containsAncestor: fixture.snapshots[2].snapshotId))
    await store.close()
}

@Test func backfillFailureRollsBackPageAndCursor() async throws {
    let root = temporaryStoreRoot("backfill-rollback")
    defer { try? FileManager.default.removeItem(at: root) }
    let fixture = try ShallowFixture()
    let store = try LocalSyncV2Store(root: root, policy: .createNew)
    try await store.installShallowHead(fixture.graph, scope: scopeA)
    try await store.exec("CREATE TEMP TRIGGER fail_page BEFORE UPDATE ON history_backfills BEGIN SELECT RAISE(ABORT,'injected'); END")
    await #expect(throws: (any Error).self) {
        try await store.applyBackfillPage(fixture.page(cursor: "end"), workID: fixture.workID, binding: bindingA,
                                          root: fixture.head.snapshotId, expectedCursor: nil)
    }
    #expect(try await store.query("SELECT COUNT(*) FROM snapshots").first?[0].int64 == 1)
    #expect(try await store.backfillState(workID: fixture.workID)?.resumeCursor == nil)
    await store.close()
}

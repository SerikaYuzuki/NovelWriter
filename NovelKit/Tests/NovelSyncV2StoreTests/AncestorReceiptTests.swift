import Foundation
import NovelCore
import NovelSyncV2
@testable import NovelSyncV2Store
import Testing

struct AncestorReceiptTests {
    @Test(arguments: [false, true])
    func ancestorReceiptPreservesContentMapping(previouslyApplied: Bool) async throws {
        let fixture = try await makeAncestorReceiptFixture(previouslyApplied: previouslyApplied)
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let store = fixture.store
        let rows = try await store.query("SELECT remote_snapshot_id,remote_generation FROM snapshot_remote_equivalents")
        if previouslyApplied {
            #expect(rows.first?[0].blob == fixture.local.snapshotID.bytes)
            #expect(rows.first?[1].int64 == 839)
        } else {
            #expect(rows.isEmpty)
        }
        let summary = try await store.workSummary(workID: fixture.workID, scope: scopeA)
        #expect(summary.currentSnapshotID == fixture.local.snapshotID)
        #expect(summary.acknowledgedHeadGeneration == 842)
        #expect(try await store.pendingIntents(scope: scopeA).isEmpty)
        await store.close()
    }

    @Test(arguments: [false, true])
    func upgradeRepairsOnlyProvenMappings(previouslyApplied: Bool) async throws {
        let fixture = try await makeAncestorReceiptFixture(previouslyApplied: previouslyApplied)
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        try await fixture.store.exec("""
        INSERT INTO snapshot_remote_equivalents VALUES(?,?,?,842)
        ON CONFLICT(work_id,local_snapshot_id) DO UPDATE SET remote_snapshot_id=excluded.remote_snapshot_id,remote_generation=842
        """, [
            .text(fixture.workID.description),
            .blob(fixture.local.snapshotID.bytes),
            .blob(fixture.head.snapshotID.bytes)
        ])
        try await fixture.store.preparePreEquivalenceRepairFixture()
        await fixture.store.close()
        for _ in 0 ..< 2 {
            let reopened = try LocalSyncV2Store(root: fixture.root, policy: .openExisting)
            let rows = try await reopened
                .query("SELECT remote_snapshot_id,remote_generation FROM snapshot_remote_equivalents")
            #expect(rows.count == (previouslyApplied ? 1 : 0))
            if previouslyApplied {
                #expect(rows.first?[0].blob == fixture.local.snapshotID.bytes)
                #expect(rows.first?[1].int64 == 839)
            }
            #expect(try await reopened.workSummary(workID: fixture.workID, scope: scopeA)
                .acknowledgedHeadGeneration == 842)
            #expect(try await reopened.query("SELECT COUNT(*) FROM sealed_commands WHERE status='completed'").first?[0]
                .int64 == (previouslyApplied ? 2 : 1))
            await reopened.close()
        }
    }

    @Test func acknowledgedCurrentDoesNotQueueAnotherIntent() async throws {
        let fixture = try await makeAncestorReceiptFixture(previouslyApplied: true)
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let before = try await fixture.store.query("SELECT COUNT(*) FROM sync_intents").first?[0].int64
        try await fixture.store.requestSynchronization(workID: fixture.workID, scope: scopeA)
        #expect(try await !fixture.store.requestAutomaticSynchronization(
            workID: fixture.workID, scope: scopeA, expectedLocalGeneration: fixture.local.generation
        ))
        try await fixture.store.promoteUnpromotedLeaves(scope: scopeA)
        #expect(try await fixture.store.query("SELECT COUNT(*) FROM sync_intents").first?[0].int64 == before)
        #expect(try await fixture.store.pendingIntents(scope: scopeA).isEmpty)
        await fixture.store.close()
    }
}

private struct AncestorReceiptFixture {
    let root: URL
    let store: LocalSyncV2Store
    let workID: WorkID
    let local: V2CheckpointResult
    let head: V2RemoteHead
}

private func makeAncestorReceiptFixture(previouslyApplied: Bool,
                                        descendant: Bool = true) async throws -> AncestorReceiptFixture {
    let root = temporaryStoreRoot("ancestor-receipt")
    let store = try LocalSyncV2Store(root: root, policy: .createNew)
    let workID = WorkID(UUID())
    let local = try await store.checkpoint(V2CheckpointRequest(
        workID: workID, document: makeDocument(title: "C"), documentCreatedAt: testDate,
        expectedGeneration: 0, reason: .explicit
    ), scope: scopeA)
    let appliedHead = try V2RemoteHead(snapshotID: local.snapshotID, generation: 839)
    var intentID = local.intentID
    if previouslyApplied {
        let applied = try publishCommand(workID: workID, checkpoint: local)
        try await store.seal(applied, intentID: intentID, scope: scopeA)
        try await store.acknowledge(commandAcknowledgement(applied, head: appliedHead), scope: scopeA)
        // Reproduce the old client's redundant checkpoint; production must no longer create this.
        intentID = UUID()
        try await store.insertIntent(intentID: #require(intentID), workID: workID, snapshotID: local.snapshotID,
                                     generation: local.generation, kind: "checkpoint", scope: scopeA)
    }
    let redundant = try publishCommand(
        workID: workID,
        checkpoint: local,
        expectedHead: previouslyApplied ? appliedHead : nil
    )
    try await store.seal(redundant, intentID: intentID, scope: scopeA)
    let encoded = try await store.loadEncoded(workID: workID, snapshotID: local.snapshotID)
    let model = try SnapshotCodec.decode(manifestBytes: encoded.manifestBytes, objects: encoded.objects)
    var document = model.document
    document.title = "H"
    let remote = try descendant ? SnapshotCodec.encode(
        SnapshotModel(workId: workID, document: document, documentCreatedAt: testDate),
        parents: [local.snapshotID]
    ) : encoded
    let head = try V2RemoteHead(snapshotID: remote.snapshotId, generation: 842)
    let graph = V2RemoteSnapshotGraph(
        workID: workID,
        headSnapshotID: remote.snapshotId,
        snapshots: descendant ? [encoded, remote] : [encoded],
        expectedCurrentSnapshotID: local.snapshotID,
        expectedLocalGeneration: local.generation,
        expectedRemoteHead: head
    )
    try await store.stageRemoteGraph(graph, scope: scopeA)
    try await store.verifyInbox(inboxID: graph.inboxID, scope: scopeA)
    try await store.acknowledge(commandAcknowledgement(redundant, result: .noChanges, head: head), scope: scopeA,
                                verifiedPublishInboxID: graph.inboxID)
    return AncestorReceiptFixture(root: root, store: store, workID: workID, local: local, head: head)
}

extension LocalSyncV2Store {
    func preparePreEquivalenceRepairFixture() throws {
        let sql = try String(decoding: SnapshotSyncV2SchemaContract.resourceSQL(), as: UTF8.self)
        let old = Data(sql.components(separatedBy: "\n-- Receipt equivalence repair (D-108).")[0].utf8)
        try exec(
            "UPDATE schema_meta SET checksum=? WHERE key='schema'",
            [.blob(SnapshotSyncV2SchemaContract.checksum(old))]
        )
    }
}

extension AncestorReceiptTests {
    @Test func differentExistingMappingRejectsReceiptAtomically() async throws {
        let fixture = try await makeAncestorReceiptFixture(previouslyApplied: true)
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let store = fixture.store
        let intentID = UUID()
        try await store.insertIntent(intentID: intentID, workID: fixture.workID, snapshotID: fixture.local.snapshotID,
                                     generation: fixture.local.generation, kind: "checkpoint", scope: scopeA)
        let command = try publishCommand(workID: fixture.workID, checkpoint: fixture.local,
                                         expectedHead: V2RemoteHead(
                                             snapshotID: fixture.local.snapshotID,
                                             generation: 839
                                         ))
        try await store.seal(command, intentID: intentID, scope: scopeA)
        try await store.exec("UPDATE snapshot_remote_equivalents SET remote_snapshot_id=?,remote_generation=842",
                             [.blob(fixture.head.snapshotID.bytes)])
        await #expect(throws: SyncV2StoreError.invalidAcknowledgement) {
            try await store.acknowledge(commandAcknowledgement(
                command,
                head: V2RemoteHead(snapshotID: fixture.local.snapshotID, generation: 843)
            ), scope: scopeA)
        }
        #expect(try await store.receiptReadback(commandID: command.commandId, scope: scopeA) == nil)
        #expect(try await store.workSummary(workID: fixture.workID, scope: scopeA).acknowledgedHeadGeneration == 842)
        #expect(try await store.pendingIntents(scope: scopeA).first?.status == "sealed")
        #expect(try await store.query("SELECT remote_snapshot_id FROM snapshot_remote_equivalents").first?[0]
            .blob == fixture.head.snapshotID.bytes)
        await store.close()
    }
}

extension AncestorReceiptTests {
    @Test func equalNoChangesRecordsContentEquivalence() async throws {
        let fixture = try await makeAncestorReceiptFixture(previouslyApplied: false, descendant: false)
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let rows = try await fixture.store
            .query("SELECT remote_snapshot_id,remote_generation FROM snapshot_remote_equivalents")
        #expect(rows.first?[0].blob == fixture.local.snapshotID.bytes)
        #expect(rows.first?[1].int64 == 842)
        await fixture.store.close()
    }
}

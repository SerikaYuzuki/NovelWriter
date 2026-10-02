import Foundation
import NovelCore
import NovelSyncV2
import NovelSyncV2Store
import Testing

@Test("legacy linear autosaves become the upgrade stable point without rewriting history")
func legacyAutosaveChainIsRetained() async throws {
    let root = temporaryStoreRoot("leaf-upgrade")
    defer { try? FileManager.default.removeItem(at: root) }
    let store = try LocalSyncV2Store(root: root, policy: .createNew)
    let workID = WorkID(UUID())
    var document = makeDocument(title: "legacy")
    var oldIDs: [SnapshotID] = []
    for generation in 0 ..< 256 {
        document.title = "legacy \(generation)"
        let checkpoint = try await store.checkpoint(V2CheckpointRequest(
            workID: workID, document: document, documentCreatedAt: testDate,
            expectedGeneration: Int64(generation), reason: .explicit
        ), scope: scopeA)
        oldIDs.append(checkpoint.snapshotID)
    }
    let url = await store.databaseURL
    let schema = try await store.schemaVersionAndChecksum()
    await store.close()
    // Reproduce the pre-D-103 representation in a disposable current-schema DB.
    #expect(try sqliteExecutionSucceeded(databaseURL: url, sql: "UPDATE history_occurrences SET reason='autosave',pinned=0"))
    let reopened = try LocalSyncV2Store(root: root, policy: .openExisting)
    document.title = "first dense leaf"
    let leaf = try await reopened.checkpoint(V2CheckpointRequest(
        workID: workID, document: document, documentCreatedAt: testDate,
        expectedGeneration: 256, reason: .autosave
    ), scope: scopeA)
    let stable = try #require(oldIDs.last)
    #expect(try await reopened.snapshotParents(workID: workID, snapshotID: leaf.snapshotID, scope: scopeA) == [stable])
    #expect(try sqliteScalarInt(databaseURL: url, sql: "SELECT COUNT(*) FROM snapshots") == 257)
    #expect(try sqliteScalarInt(databaseURL: url, sql: "SELECT COUNT(*) FROM history_occurrences WHERE reason='autosave'") == 256)
    for index in 1 ..< oldIDs.count {
        #expect(try await reopened.snapshotParents(workID: workID, snapshotID: oldIDs[index], scope: scopeA) == [oldIDs[index - 1]])
    }
    let afterSchema = try await reopened.schemaVersionAndChecksum()
    #expect(schema.0 == afterSchema.0)
    #expect(schema.1 == afterSchema.1)
    #expect(try await reopened.pendingIntents(scope: scopeA, workID: workID).first?.sourceSnapshotID == stable)
    await reopened.close()
}

@Test("parking a leaf never creates an unbound or other-account lane")
func parkedLeafRemainsPrivate() async throws {
    let root = temporaryStoreRoot("leaf-account")
    defer { try? FileManager.default.removeItem(at: root) }
    let store = try LocalSyncV2Store(root: root, policy: .createNew)
    let workID = WorkID(UUID())
    var document = makeDocument(title: "base")
    _ = try await seedLeafBaseline(store, workID: workID, document: document)
    document.title = "private local leaf"
    _ = try await store.checkpoint(V2CheckpointRequest(
        workID: workID, document: document, documentCreatedAt: testDate,
        expectedGeneration: 1, reason: .autosave
    ), scope: scopeA)
    try await store.parkWork(workID: workID, binding: bindingA)
    let otherScope = V2LocalWorkScope.bound(V2AccountBinding(
        accountID: "other", accountFence: "other", serverInstanceID: bindingA.serverInstanceID
    ))
    #expect(try await !store.promoteCurrentLeaf(workID: workID, scope: otherScope))
    #expect(try await !store.promoteCurrentLeaf(workID: workID, scope: .parked))
    #expect(try await store.pendingIntents(scope: otherScope).isEmpty)
    #expect(try await store.pendingIntents(scope: .unbound).isEmpty)
    #expect(try await store.open(workID: workID, scope: .parked).document == document)
    #expect(try await store.hasUnpromotedLeaf(workID: workID, scope: .parked))
    await store.close()
}

@Test("deleting a bound work retains its unpublished leaf and blocks promotion")
func deletedWorkRetainsLocalLeaf() async throws {
    let root = temporaryStoreRoot("leaf-deletion")
    defer { try? FileManager.default.removeItem(at: root) }
    let store = try LocalSyncV2Store(root: root, policy: .createNew)
    let workID = WorkID(UUID())
    var document = makeDocument(title: "base")
    _ = try await seedLeafBaseline(store, workID: workID, document: document)
    document.title = "unpublished local bytes"
    _ = try await store.checkpoint(V2CheckpointRequest(
        workID: workID, document: document, documentCreatedAt: testDate,
        expectedGeneration: 1, reason: .autosave
    ), scope: scopeA)
    let deletion = try await store.prepareWorkDeletion(workID: workID, activeBinding: bindingA)
    await #expect(throws: SyncV2StoreError.workDeletionPending) {
        try await store.promoteCurrentLeaf(workID: workID, scope: scopeA)
    }
    try await store.completeWorkDeletion(deletion)
    try await store.promoteUnpromotedLeaves(scope: scopeA)
    #expect(try await store.open(workID: workID, scope: scopeA).document == document)
    #expect(try await store.pendingIntents(scope: scopeA).isEmpty)
    #expect(try await store.historyCount(workID: workID, scope: scopeA) == 2)
    await store.close()
}

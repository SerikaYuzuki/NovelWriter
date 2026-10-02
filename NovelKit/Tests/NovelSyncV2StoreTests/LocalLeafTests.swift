import Foundation
import NovelCore
import NovelSyncV2
import NovelSyncV2Store
import Testing

@Test("autosaves retain dense local siblings and no remote intent")
func autosavesAreLocalLeaves() async throws {
    let root = temporaryStoreRoot("local-leaves")
    defer { try? FileManager.default.removeItem(at: root) }
    let store = try LocalSyncV2Store(root: root, policy: .createNew)
    let workID = WorkID(UUID())
    var document = makeDocument(title: "stable")
    let stable = try await seedLeafBaseline(store, workID: workID, document: document)
    var ids = Set<SnapshotID>()
    for index in 1 ... 12 {
        document.title = "leaf \(index)"
        let leaf = try await store.checkpoint(V2CheckpointRequest(
            workID: workID, document: document, documentCreatedAt: testDate,
            expectedGeneration: Int64(index), reason: .autosave
        ), scope: scopeA)
        ids.insert(leaf.snapshotID)
        #expect(leaf.intentID == nil)
        #expect(try await store.snapshotParents(workID: workID, snapshotID: leaf.snapshotID, scope: scopeA) == [stable])
    }
    #expect(ids.count == 12)
    #expect(try await store.historyCount(workID: workID, scope: scopeA) == 13)
    #expect(try await store.pendingIntents(scope: scopeA, workID: workID).isEmpty)
    #expect(try await store.allSealedCommands(scope: scopeA, workID: workID).isEmpty)
    await store.close()
    let reopened = try LocalSyncV2Store(root: root, policy: .openExisting)
    #expect(try await reopened.open(workID: workID, scope: scopeA).document == document)
    #expect(try await reopened.promoteCurrentLeaf(workID: workID, scope: scopeA))
    #expect(try await !reopened.promoteCurrentLeaf(workID: workID, scope: scopeA))
    let intents = try await reopened.pendingIntents(scope: scopeA, workID: workID)
    #expect(intents.count == 1)
    #expect(intents.first?.sourceGeneration == 13)
    await reopened.close()
}

@Test("protecting saves promote existing leaf bytes once", arguments: [
    V2CheckpointReason.explicit, .navigation, .close, .migration
])
func protectingReasonPromotesLeaf(reason: V2CheckpointReason) async throws {
    let root = temporaryStoreRoot("leaf-protect")
    defer { try? FileManager.default.removeItem(at: root) }
    let store = try LocalSyncV2Store(root: root, policy: .createNew)
    let workID = WorkID(UUID())
    var document = makeDocument(title: "stable")
    let stable = try await seedLeafBaseline(store, workID: workID, document: document)
    document.title = "latest leaf"
    let leaf = try await store.checkpoint(V2CheckpointRequest(
        workID: workID, document: document, documentCreatedAt: testDate,
        expectedGeneration: 1, reason: .autosave
    ), scope: scopeA)
    let promotion = try await store.checkpoint(V2CheckpointRequest(
        workID: workID, document: document, documentCreatedAt: testDate,
        expectedGeneration: 2, reason: reason
    ), scope: scopeA)
    #expect(promotion.noChanges)
    #expect(promotion.snapshotID == leaf.snapshotID)
    #expect(promotion.intentID != nil)
    #expect(try await store.snapshotParents(workID: workID, snapshotID: promotion.snapshotID, scope: scopeA) == [stable])
    #expect(try await store.pendingIntents(scope: scopeA, workID: workID).count == 1)
    document.title = "next leaf"
    let next = try await store.checkpoint(V2CheckpointRequest(
        workID: workID, document: document, documentCreatedAt: testDate,
        expectedGeneration: 2, reason: .autosave
    ), scope: scopeA)
    #expect(try await store.snapshotParents(workID: workID, snapshotID: next.snapshotID, scope: scopeA) == [leaf.snapshotID])
    #expect(try await store.pendingIntents(scope: scopeA, workID: workID).first?.sourceSnapshotID == leaf.snapshotID)
    await store.close()
}

@Test("an incoming branch cannot silently adopt over an unpromoted leaf")
func leafRejectsOrdinaryRemoteAdoption() async throws {
    let root = temporaryStoreRoot("leaf-adoption")
    defer { try? FileManager.default.removeItem(at: root) }
    let store = try LocalSyncV2Store(root: root, policy: .createNew)
    let workID = WorkID(UUID())
    var document = makeDocument(title: "base")
    let stable = try await seedLeafBaseline(store, workID: workID, document: document)
    document.title = "local"
    let leaf = try await store.checkpoint(V2CheckpointRequest(
        workID: workID, document: document, documentCreatedAt: testDate,
        expectedGeneration: 1, reason: .autosave
    ), scope: scopeA)
    document.title = "remote"
    let remote = try encodeSnapshot(workID: workID, document: document, parents: [stable])
    let inbox = try V2RemoteSnapshot(workID: workID, encoded: remote,
                                     expectedCurrentSnapshotID: leaf.snapshotID, expectedLocalGeneration: 2,
                                     expectedRemoteHead: V2RemoteHead(snapshotID: remote.snapshotId, generation: 2))
    try await store.stageRemote(inbox, scope: scopeA)
    try await store.verifyInbox(inboxID: inbox.inboxID, scope: scopeA)
    await #expect(throws: SyncV2StoreError.staleCAS) {
        try await store.adoptInbox(inboxID: inbox.inboxID, scope: scopeA)
    }
    #expect(try await store.open(workID: workID, scope: scopeA).document?.title == "local")
    #expect(try await store.requestAutomaticSynchronization(workID: workID, scope: scopeA, expectedLocalGeneration: 2))
    let transfer = try #require(try await store.immutableTransferView(workID: workID, scope: scopeA))
    #expect(transfer.snapshot.snapshotId == leaf.snapshotID)
    #expect(transfer.expectedRemoteHead?.snapshotID == stable)
    await store.close()
}

func seedLeafBaseline(_ store: LocalSyncV2Store, workID: WorkID, document: NovelDocument) async throws -> SnapshotID {
    let encoded = try encodeSnapshot(workID: workID, document: document)
    let inbox = try V2RemoteSnapshot(workID: workID, encoded: encoded, expectedCurrentSnapshotID: nil,
                                     expectedLocalGeneration: 0,
                                     expectedRemoteHead: V2RemoteHead(snapshotID: encoded.snapshotId, generation: 1))
    try await store.stageRemote(inbox, scope: scopeA)
    try await store.verifyInbox(inboxID: inbox.inboxID, scope: scopeA)
    try await store.adoptInbox(inboxID: inbox.inboxID, scope: scopeA)
    return encoded.snapshotId
}

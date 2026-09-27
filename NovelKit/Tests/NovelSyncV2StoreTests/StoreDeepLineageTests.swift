import Foundation
import NovelSyncV2
@testable import NovelSyncV2Store
import Testing

@Test
func deepLineageValidationDoesNotRecurseAndStillRejectsCycles() async throws {
    let root = temporaryStoreRoot("deep-lineage")
    defer { try? FileManager.default.removeItem(at: root) }
    let store = try LocalSyncV2Store(root: root, policy: .createNew)
    let ids = (0 ..< 10000).map { SnapshotID(data: Data("node-\($0)".utf8)) }
    var parents: [SnapshotID: [SnapshotID]] = [:]
    for (index, id) in ids.enumerated() {
        parents[id] = index == 0 ? [] : [ids[index - 1]]
    }
    try await store.validateAcyclic(parents)
    parents[ids[0]] = [ids[ids.count - 1]]
    await #expect(throws: SyncV2StoreError.invalidSnapshot) {
        try await store.validateAcyclic(parents)
    }
    await store.close()
}

@Test func deepInboxStagesReloadsAndAdoptsWithoutRecursiveSorting() async throws {
    let root = temporaryStoreRoot("deep-inbox")
    defer { try? FileManager.default.removeItem(at: root) }
    let store = try LocalSyncV2Store(root: root, policy: .createNew)
    let workID = WorkID(UUID())
    var snapshots: [EncodedSnapshot] = []
    var document = makeDocument(title: "root")
    for index in 0 ..< 2048 {
        document.title = "revision \(index)"
        try snapshots.append(encodeSnapshot(workID: workID, document: document,
                                            parents: snapshots.last.map { [$0.snapshotId] } ?? []))
    }
    let head = try #require(snapshots.last)
    let graph = try V2RemoteSnapshotGraph(workID: workID, headSnapshotID: head.snapshotId,
                                          snapshots: snapshots.reversed(), expectedCurrentSnapshotID: nil,
                                          expectedLocalGeneration: 0,
                                          expectedRemoteHead: V2RemoteHead(snapshotID: head.snapshotId, generation: 2048))
    try await store.stageRemoteGraph(graph, scope: scopeA)
    await store.close()
    let reopened = try LocalSyncV2Store(root: root, policy: .openExisting)
    try await reopened.verifyInbox(inboxID: graph.inboxID, scope: scopeA)
    try await reopened.adoptInbox(inboxID: graph.inboxID, scope: scopeA)
    #expect(try await reopened.open(workID: workID, scope: scopeA).document == document)
    await reopened.close()
}

@Test func inboxReusesAttachmentAllocationAcrossSnapshots() async throws {
    let root = temporaryStoreRoot("inbox-shared-allocation")
    defer { try? FileManager.default.removeItem(at: root) }
    let store = try LocalSyncV2Store(root: root, policy: .createNew)
    let workID = WorkID(UUID())
    let attachment = SyncAttachment(attachmentId: UUID(), fileName: "shared.bin", bytes: Data(repeating: 42, count: 512 * 1024))
    var document = makeDocument(title: "root")
    var snapshots: [EncodedSnapshot] = []
    for index in 0 ..< 32 {
        document.title = "revision \(index)"
        try snapshots.append(SnapshotCodec.encode(
            SnapshotModel(workId: workID, document: document, documentCreatedAt: testDate, attachments: [attachment]),
            parents: snapshots.last.map { [$0.snapshotId] } ?? []
        ))
    }
    let graph = try V2RemoteSnapshotGraph(workID: workID, headSnapshotID: #require(snapshots.last).snapshotId,
                                          snapshots: snapshots, expectedCurrentSnapshotID: nil, expectedLocalGeneration: 0,
                                          expectedRemoteHead: V2RemoteHead(snapshotID: #require(snapshots.last).snapshotId, generation: 32))
    try await store.stageRemoteGraph(graph, scope: scopeA)
    let loaded = try await store.loadInboxGraph(inboxID: graph.inboxID, binding: bindingA)
    let id = ObjectID(data: attachment.bytes)
    let first = try #require(loaded.snapshots.first?.objects[id])
    for snapshot in loaded.snapshots {
        let bytes = try #require(snapshot.objects[id])
        #expect(bytes == attachment.bytes)
        // Heap-sized Data must share its backing bytes, not multiply by history length.
        let shared = first.withUnsafeBytes { left in bytes.withUnsafeBytes { right in left.baseAddress == right.baseAddress } }
        #expect(shared)
    }
    await store.close()
}

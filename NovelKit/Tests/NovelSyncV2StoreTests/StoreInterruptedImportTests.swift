import Foundation
import NovelSyncV2
@testable import NovelSyncV2Store
import Testing

@Test("interrupted initial inbox can be restaged after reopening SQLite", arguments: ["verifyFailure", "adoptKilled", "accountRejected"])
func interruptedInitialInboxRecovers(phase: String) async throws {
    let root = temporaryStoreRoot("interrupted-import")
    defer { try? FileManager.default.removeItem(at: root) }
    let workID = WorkID(UUID())
    let snapshot = try encodeSnapshot(workID: workID, document: makeDocument(title: "復旧本文"))
    let graph = try V2RemoteSnapshotGraph(workID: workID, headSnapshotID: snapshot.snapshotId,
                                          snapshots: [snapshot], expectedCurrentSnapshotID: nil,
                                          expectedLocalGeneration: 0,
                                          expectedRemoteHead: V2RemoteHead(snapshotID: snapshot.snapshotId, generation: 1))
    let store = try LocalSyncV2Store(root: root, policy: .createNew)
    try await store.stageRemoteGraph(graph, scope: scopeA)
    if phase == "verifyFailure" {
        try await store.exec("UPDATE inbox_batches SET manifest_bytes=X'00' WHERE inbox_id=?",
                             [.text(graph.inboxID.uuidString.lowercased())])
        await #expect(throws: SyncV2StoreError.invalidSnapshot) {
            try await store.verifyInbox(inboxID: graph.inboxID, scope: scopeA)
        }
    } else {
        try await store.verifyInbox(inboxID: graph.inboxID, scope: scopeA)
        if phase == "accountRejected", case let .bound(binding) = scopeA {
            try await store.transitionAccountScopes(from: binding, to: nil)
            try await store.transitionAccountScopes(from: nil, to: binding)
            #expect(try await store.inboxState(inboxID: graph.inboxID, binding: binding) == "rejected")
        }
    }
    let before = try await store.open(workID: workID, scope: scopeA)
    #expect(before.document == nil)
    #expect(before.summary.localGeneration == 0)
    #expect(before.summary.currentSnapshotID == nil)
    await store.close()
    let reopened = try LocalSyncV2Store(root: root, policy: .openExisting)
    let replacement = V2RemoteSnapshotGraph(workID: workID, headSnapshotID: graph.headSnapshotID,
                                            snapshots: graph.snapshots, expectedCurrentSnapshotID: nil,
                                            expectedLocalGeneration: 0, expectedRemoteHead: graph.expectedRemoteHead)
    try await reopened.stageRemoteGraph(replacement, scope: scopeA)
    try await reopened.verifyInbox(inboxID: replacement.inboxID, scope: scopeA)
    try await reopened.adoptInbox(inboxID: replacement.inboxID, scope: scopeA)
    #expect(try await reopened.open(workID: workID, scope: scopeA).document?.title == "復旧本文")
    #expect(try await reopened.inboxExists(inboxID: graph.inboxID))
    #expect(try await reopened.inboxExists(inboxID: replacement.inboxID))
    await reopened.close()
}

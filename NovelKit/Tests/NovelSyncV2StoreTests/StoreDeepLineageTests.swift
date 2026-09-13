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

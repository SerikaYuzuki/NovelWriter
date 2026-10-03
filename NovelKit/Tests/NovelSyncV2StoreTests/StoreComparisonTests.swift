import Foundation
import NovelSyncV2
import NovelSyncV2Store
import Testing

struct StoreComparisonTests {
    @Test func comparisonReadsVerifiedConflictInboxWithoutInstallingIt() async throws {
        let root = temporaryStoreRoot("comparison-inbox")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try LocalSyncV2Store(root: root, policy: .createNew)
        let workID = WorkID(UUID())
        let fixture = try await createConflict(store: store, workID: workID)
        let before = try await store.open(workID: workID, scope: scopeA).summary
        let manifest = try #require(try await store.comparisonManifest(
            workID: workID, snapshotID: fixture.remote.encoded.snapshotId, scope: scopeA
        ))
        #expect(manifest == fixture.remote.encoded.manifest)
        let entry = try #require(manifest.entries.first { $0.entityKey == "work/title" })
        let bytes = try await store.comparisonObject(workID: workID, snapshotID: fixture.remote.encoded.snapshotId, entry: entry, scope: scopeA)
        #expect(try SnapshotCodec.valueString(bytes) == "remote")
        #expect(try await store.open(workID: workID, scope: scopeA).summary == before)
        await #expect(throws: SyncV2StoreError.accountMismatch) {
            _ = try await store.comparisonManifest(workID: workID, snapshotID: fixture.remote.encoded.snapshotId, scope: .unbound)
        }
        let another = WorkID(UUID())
        await #expect(throws: SyncV2StoreError.accountMismatch) {
            _ = try await store.comparisonObject(workID: another, snapshotID: fixture.remote.encoded.snapshotId, entry: entry, scope: scopeA)
        }
        await store.close()
    }

    @Test func stagedButUnverifiedSnapshotIsNotReadable() async throws {
        let root = temporaryStoreRoot("comparison-unverified")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try LocalSyncV2Store(root: root, policy: .createNew)
        let workID = WorkID(UUID())
        let doc = makeDocument(title: "local")
        let checkpoint = try await store.checkpoint(V2CheckpointRequest(
            workID: workID, document: doc, documentCreatedAt: testDate, expectedGeneration: 0, reason: .explicit
        ), scope: scopeA)
        var changed = doc
        changed.title = "unverified"
        let encoded = try encodeSnapshot(workID: workID, document: changed, parents: [checkpoint.snapshotID])
        let remote = try V2RemoteSnapshot(workID: workID, encoded: encoded,
                                          expectedCurrentSnapshotID: checkpoint.snapshotID,
                                          expectedLocalGeneration: checkpoint.generation,
                                          expectedRemoteHead: V2RemoteHead(snapshotID: encoded.snapshotId, generation: 1))
        try await store.stageRemote(remote, scope: scopeA)
        #expect(try await store.comparisonManifest(workID: workID, snapshotID: encoded.snapshotId, scope: scopeA) == nil)
        await store.close()
    }
}

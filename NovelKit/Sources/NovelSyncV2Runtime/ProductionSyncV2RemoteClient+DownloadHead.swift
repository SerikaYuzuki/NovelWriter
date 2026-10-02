import Foundation
import NovelAuth
import NovelSyncV2
import NovelSyncV2Application

extension ProductionSyncV2RemoteClient {
    func downloadHead(workID: WorkID, id: SnapshotID, session: FuminiwaSession) async throws -> EncodedSnapshot? {
        guard let batch = try await downloadSnapshotPages(workID: workID, id: id, session: session, mode: "head") else {
            return nil // D-105 negotiation: only an initial mode rejection falls back.
        }
        guard let head = batch.manifests[id], batch.manifests.count == 1 else {
            throw SyncV2Failure.quarantined(.invalidRemoteData)
        }
        let traversal = SnapshotFetchTraversal()
        traversal.objects = batch.objects
        try traversal.include(head.manifest)
        let objects = try await fetchObjects(entries: head.manifest.entries, session: session, traversal: traversal)
        return EncodedSnapshot(manifest: head.manifest, manifestBytes: head.bytes, objects: objects)
    }
}

import Foundation
import NovelSyncV2

extension LocalSyncV2Store {
    func loadInboxGraph(
        inboxID: UUID,
        binding: V2AccountBinding
    ) throws -> V2RemoteSnapshotGraph {
        let text = inboxID.uuidString.lowercased()
        guard let batch = try query(
            """
            SELECT work_id,snapshot_id,expected_current_snapshot_id,
                   expected_local_generation,expected_remote_head_snapshot_id,
                   expected_remote_head_generation,manifest_bytes
            FROM inbox_batches
            WHERE inbox_id=? AND server_instance_id=? AND protocol_epoch=?
              AND account_id=? AND account_fence=?
            """,
            [.text(text)] + binding.values
        ).first,
            let work = batch[0].text,
            let head = batch[1].blob,
            let generation = batch[3].int64 else {
            throw SyncV2StoreError.inboxNotFound
        }
        let workID = try WorkID(uuidString: work)
        var snapshots: [EncodedSnapshot] = []
        // Keep one verified allocation per object across the complete history.
        var objectBytes: [ObjectID: Data] = [:]
        for row in try query("SELECT object_id,byte_count,bytes,verified FROM inbox_objects WHERE inbox_id=? ORDER BY object_id", [.text(text)]) {
            guard let id = row[0].blob, let bytes = row[2].blob,
                  row[1].int64 == Int64(bytes.count), [0, 1].contains(row[3].int64),
                  ObjectID(data: bytes).bytes == id else { throw SyncV2StoreError.invalidSnapshot }
            try objectBytes[ObjectID(rawValue: id.hexString)] = bytes
        }

        for row in try query(
            """
            SELECT snapshot_id,manifest_bytes,work_id,is_head,verified FROM inbox_snapshots
            WHERE inbox_id=? ORDER BY snapshot_id
            """,
            [.text(text)]
        ) {
            guard let snapshotBytes = row[0].blob,
                  let manifestBytes = row[1].blob,
                  row[2].text == work,
                  row[3].int64 == (snapshotBytes == head ? 1 : 0),
                  [0, 1].contains(row[4].int64) else {
                throw SyncV2StoreError.invalidSnapshot
            }
            let manifest = try SnapshotValidator.validate(manifestBytes: manifestBytes)
            guard SnapshotID(data: manifestBytes).bytes == snapshotBytes else {
                throw SyncV2StoreError.invalidSnapshot
            }
            var objects: [ObjectID: Data] = [:]
            for entry in manifest.entries {
                guard let bytes = objectBytes[entry.objectId], bytes.count == entry.byteCount else {
                    throw SyncV2StoreError.invalidSnapshot
                }
                objects[entry.objectId] = objectBytes[entry.objectId]
            }
            snapshots.append(EncodedSnapshot(
                manifest: manifest,
                manifestBytes: manifestBytes,
                objects: objects
            ))
        }
        let remoteHead = try Self.head(
            snapshot: batch[4].blob,
            generation: batch[5].int64
        )
        guard let batchManifest = batch[6].blob,
              snapshots.first(where: {
                  $0.snapshotId.bytes == head
              })?.manifestBytes == batchManifest else {
            throw SyncV2StoreError.invalidSnapshot
        }
        let graph = try V2RemoteSnapshotGraph(
            inboxID: inboxID,
            workID: workID,
            headSnapshotID: SnapshotID(rawValue: head.hexString),
            snapshots: snapshots,
            expectedCurrentSnapshotID: batch[2].blob.map {
                try SnapshotID(rawValue: $0.hexString)
            },
            expectedLocalGeneration: generation,
            expectedRemoteHead: remoteHead
        )
        let objectCount = try query(
            "SELECT COUNT(*) FROM inbox_objects WHERE inbox_id=?",
            [.text(text)]
        ).first?[0].int64
        guard try objectCount == Int64(graphObjectUnion(graph).count) else {
            throw SyncV2StoreError.invalidSnapshot
        }
        try attestInboxClosure(graph)
        return graph
    }
}

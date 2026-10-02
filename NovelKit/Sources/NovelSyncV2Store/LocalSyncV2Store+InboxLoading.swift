import Foundation
import NovelSyncV2

extension LocalSyncV2Store {
    func loadInboxGraph(
        inboxID: UUID,
        binding: V2AccountBinding
    ) throws -> V2RemoteSnapshotGraph {
        let text = inboxID.uuidString.lowercased()
        guard let batch = try queryRows(
            InboxBatchRow.self,
            """
            SELECT \(InboxBatchRow.columns)
            FROM inbox_batches
            WHERE inbox_id=? AND server_instance_id=? AND protocol_epoch=?
              AND account_id=? AND account_fence=?
            """,
            [.text(text)] + binding.values
        ).first,
            let work = batch.workID,
            let head = batch.snapshotID,
            let generation = batch.expectedLocalGeneration else {
            throw SyncV2StoreError.inboxNotFound
        }
        let workID = try WorkID(uuidString: work)
        var snapshots: [EncodedSnapshot] = []
        // Keep one verified allocation per object across the complete history.
        var objectBytes: [ObjectID: Data] = [:]
        for row in try queryRows(
            InboxObjectRow.self,
            "SELECT \(InboxObjectRow.columns) FROM inbox_objects WHERE inbox_id=? ORDER BY object_id", [.text(text)]
        ) {
            guard let id = row.objectID, let bytes = row.bytes,
                  row.byteCount == Int64(bytes.count), [0, 1].contains(row.verified),
                  ObjectID(data: bytes).bytes == id else { throw SyncV2StoreError.invalidSnapshot }
            try objectBytes[ObjectID(rawValue: id.hexString)] = bytes
        }

        for row in try queryRows(
            InboxSnapshotRow.self,
            """
            SELECT \(InboxSnapshotRow.columns) FROM inbox_snapshots
            WHERE inbox_id=? ORDER BY snapshot_id
            """,
            [.text(text)]
        ) {
            guard let snapshotBytes = row.snapshotID,
                  let manifestBytes = row.manifestBytes,
                  row.workID == work,
                  row.isHead == (snapshotBytes == head ? 1 : 0),
                  [0, 1].contains(row.verified) else {
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
            snapshot: batch.expectedRemoteHeadSnapshotID,
            generation: batch.expectedRemoteHeadGeneration
        )
        guard let batchManifest = batch.manifestBytes,
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
            expectedCurrentSnapshotID: batch.expectedCurrentSnapshotID.map {
                try SnapshotID(rawValue: $0.hexString)
            },
            expectedLocalGeneration: generation,
            expectedRemoteHead: remoteHead
        )
        let objectCount = try query(
            "SELECT COUNT(*) FROM inbox_objects WHERE inbox_id=?",
            [.text(text)]
        ).first?.scalar.int64
        guard try objectCount == Int64(graphObjectUnion(graph).count) else {
            throw SyncV2StoreError.invalidSnapshot
        }
        try attestInboxClosure(graph)
        return graph
    }
}

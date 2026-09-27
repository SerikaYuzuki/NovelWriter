import Foundation
import NovelSyncV2

public extension LocalSyncV2Store {
    /// A verified Inbox can supply bytes while newer local edits postpone
    /// adoption. Its parents must still be traversed; it is not a committed anchor.
    func verifiedInboxSnapshot(
        workID: WorkID,
        snapshotID: SnapshotID,
        scope: V2LocalWorkScope
    ) throws -> EncodedSnapshot? {
        guard case let .bound(binding) = scope,
              try scopedWorkRow(workID: workID, scope: scope) != nil else { return nil }
        guard let row = try query("""
        SELECT s.inbox_id,s.manifest_bytes FROM inbox_snapshots s
        JOIN inbox_batches i ON i.inbox_id=s.inbox_id
        WHERE s.work_id=? AND s.snapshot_id=? AND s.verified=1
          AND i.work_id=s.work_id AND i.server_instance_id=? AND i.protocol_epoch=?
          AND i.account_id=? AND i.account_fence=? AND i.state IN ('verified','adopted')
        ORDER BY i.rowid DESC LIMIT 1
        """, [.text(workID.description), .blob(snapshotID.bytes)] + binding.values).first else { return nil }
        guard let inboxID = row[0].text, let bytes = row[1].blob,
              SnapshotID(data: bytes) == snapshotID else { throw SyncV2StoreError.invalidSnapshot }
        let manifest = try SnapshotValidator.validate(manifestBytes: bytes)
        guard manifest.workId == workID else { throw SyncV2StoreError.invalidSnapshot }
        var objects: [ObjectID: Data] = [:]
        for entry in manifest.entries {
            guard let object = try query("""
            SELECT bytes FROM inbox_objects
            WHERE inbox_id=? AND object_id=? AND byte_count=? AND verified=1
            """, [.text(inboxID), .blob(entry.objectId.bytes), .int(Int64(entry.byteCount))]).first?[0].blob else {
                throw SyncV2StoreError.invalidSnapshot
            }
            objects[entry.objectId] = object
        }
        let snapshot = EncodedSnapshot(manifest: manifest, manifestBytes: bytes, objects: objects)
        try SnapshotValidator.validateObjects(snapshot)
        return snapshot
    }

    /// Only committed snapshots in this exact work/account scope may anchor a
    /// remote graph. Staged inbox rows and other accounts are not cache hits.
    func committedSnapshot(
        workID: WorkID,
        snapshotID: SnapshotID,
        scope: V2LocalWorkScope
    ) throws -> EncodedSnapshot? {
        guard try scopedWorkRow(workID: workID, scope: scope) != nil else { return nil }
        guard try !query(
            "SELECT 1 FROM snapshots WHERE work_id=? AND snapshot_id=?",
            [.text(workID.description), .blob(snapshotID.bytes)]
        ).isEmpty else { return nil }
        let encoded = try loadEncoded(workID: workID, snapshotID: snapshotID)
        try validateParents(encoded, workID: workID)
        return encoded
    }
}

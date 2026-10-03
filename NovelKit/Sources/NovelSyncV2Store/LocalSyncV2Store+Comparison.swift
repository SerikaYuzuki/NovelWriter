import Foundation
import NovelSyncV2

/// Presentation reads immutable, scoped bytes without opening a document or downloading history.
public extension LocalSyncV2Store {
    func comparisonManifest(workID: WorkID, snapshotID: SnapshotID, scope: V2LocalWorkScope) throws -> SnapshotManifest? {
        guard try workRepository.scopedWorkRow(workID: workID, scope: scope) != nil else {
            throw SyncV2StoreError.accountMismatch
        }
        let localBytes = try workRepository.query(
            "SELECT manifest_bytes FROM snapshots WHERE work_id=? AND snapshot_id=?",
            [.text(workID.description), .blob(snapshotID.bytes)]
        ).first?.scalar.blob
        let stagedBytes = try comparisonInboxManifest(workID: workID, snapshotID: snapshotID, scope: scope)
        guard let bytes = localBytes ?? stagedBytes else { return nil }
        guard SnapshotID(data: bytes) == snapshotID else { throw SyncV2StoreError.invalidSnapshot }
        let manifest = try SnapshotValidator.validate(manifestBytes: bytes)
        guard manifest.workId == workID else { throw SyncV2StoreError.invalidSnapshot }
        return manifest
    }

    func comparisonObject(workID: WorkID, snapshotID: SnapshotID, entry: SnapshotEntry,
                          scope: V2LocalWorkScope) throws -> Data {
        guard try workRepository.scopedWorkRow(workID: workID, scope: scope) != nil else {
            throw SyncV2StoreError.accountMismatch
        }
        let rows = try workRepository.queryRows(ObjectContentRow.self, """
        SELECT \(ObjectContentRow.qualifiedColumns("o")) FROM objects o
        JOIN snapshot_entries e ON e.object_id=o.object_id
        JOIN snapshots s ON s.snapshot_id=e.snapshot_id
        WHERE s.work_id=? AND s.snapshot_id=? AND e.entity_key=? AND e.object_id=?
        """, [.text(workID.description), .blob(snapshotID.bytes), .text(entry.entityKey), .blob(entry.objectId.bytes)])
        let staged = try comparisonInboxObject(workID: workID, snapshotID: snapshotID, entry: entry, scope: scope)
        guard let row = rows.first ?? staged, let bytes = row.bytes,
              row.byteCount == Int64(entry.byteCount), bytes.count == entry.byteCount,
              ObjectID(data: bytes) == entry.objectId else { throw SyncV2StoreError.invalidSnapshot }
        return bytes
    }
}

private extension LocalSyncV2Store {
    func comparisonInboxManifest(workID: WorkID, snapshotID: SnapshotID, scope: V2LocalWorkScope) throws -> Data? {
        guard case let .bound(binding) = scope else { return nil }
        return try workRepository.query("""
        SELECT s.manifest_bytes FROM inbox_snapshots s JOIN inbox_batches b ON b.inbox_id=s.inbox_id
        WHERE s.work_id=? AND s.snapshot_id=? AND s.verified=1
          AND b.server_instance_id=? AND b.protocol_epoch=? AND b.account_id=? AND b.account_fence=?
        LIMIT 1
        """, [.text(workID.description), .blob(snapshotID.bytes)] + binding.values).first?.scalar.blob
    }

    func comparisonInboxObject(workID: WorkID, snapshotID: SnapshotID, entry: SnapshotEntry,
                               scope: V2LocalWorkScope) throws -> ObjectContentRow? {
        guard case let .bound(binding) = scope else { return nil }
        return try workRepository.queryRows(ObjectContentRow.self, """
        SELECT o.byte_count,o.bytes FROM inbox_objects o
        JOIN inbox_closure e ON e.inbox_id=o.inbox_id AND e.object_id=o.object_id
        JOIN inbox_snapshots s ON s.inbox_id=e.inbox_id AND s.snapshot_id=e.snapshot_id
        JOIN inbox_batches b ON b.inbox_id=s.inbox_id
        WHERE s.work_id=? AND s.snapshot_id=? AND e.entity_key=? AND e.object_id=?
          AND s.verified=1 AND o.verified=1
          AND b.server_instance_id=? AND b.protocol_epoch=? AND b.account_id=? AND b.account_fence=?
        LIMIT 1
        """, [.text(workID.description), .blob(snapshotID.bytes), .text(entry.entityKey), .blob(entry.objectId.bytes)] + binding.values).first
    }
}

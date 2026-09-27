import Foundation
import NovelSyncV2

public extension LocalSyncV2Store {
    /// Membership lookup only. Opening a document and loading immutable transfer
    /// bytes remain the validation boundaries for the manuscript itself.
    func workSummary(workID: WorkID, scope: V2LocalWorkScope) throws -> V2WorkSummary {
        guard let row = try scopedWorkRow(workID: workID, scope: scope) else {
            throw SyncV2StoreError.workNotFound
        }
        guard let anchor = row[5].text,
              ISO8601DateFormatter().date(from: anchor) != nil else {
            throw SyncV2StoreError.invalidSnapshot
        }
        return try Self.summary(row)
    }

    /// Only bootstrap and quarantined records affect the planner's guards.
    /// Historical completed object requests are read for their exact occurrence
    /// below, avoiding allocations for accumulated completed transfer history.
    func planningGuardCommands(
        scope: V2LocalWorkScope,
        workID: WorkID
    ) throws -> [V2SealedCommandRecord] {
        guard case let .bound(binding) = scope else { throw SyncV2StoreError.accountMismatch }
        return try query(
            Self.commandSelect + """
             WHERE work_id=? AND server_instance_id=? AND protocol_epoch=?
               AND account_id=? AND account_fence=?
               AND (command_kind='createWork' OR status='quarantined') ORDER BY rowid
            """,
            [.text(workID.description)] + binding.values
        ).map(Self.commandRecord)
    }

    /// Preserve row order and the complete binding/source identity. Upload
    /// capabilities from another generation must never satisfy this transfer.
    func completedTransferCommands(
        scope: V2LocalWorkScope,
        workID: WorkID,
        snapshotID: SnapshotID,
        generation: Int64
    ) throws -> [V2SealedCommandRecord] {
        guard case let .bound(binding) = scope else { throw SyncV2StoreError.accountMismatch }
        return try query(
            Self.commandSelect + """
             WHERE work_id=? AND server_instance_id=? AND protocol_epoch=?
               AND account_id=? AND account_fence=? AND status='completed'
               AND source_snapshot_id=? AND source_generation=? ORDER BY rowid
            """,
            [.text(workID.description)] + binding.values + [.blob(snapshotID.bytes), .int(generation)]
        ).map(Self.commandRecord)
    }
}

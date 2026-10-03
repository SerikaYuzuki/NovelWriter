import Foundation
import NovelSyncV2

extension ConflictRepository {
    /// Existing rows are the durable recovery marker: pending -> parked is
    /// consumed once, and the verified Inbox keeps the lane held until adoption.
    /// No migration, mutable snapshot, or new command is needed.
    private func multipleResolutionRows(status: String, workID: WorkID? = nil) throws -> [SQLiteRow] {
        let workPredicate = workID == nil ? "" : " AND c.work_id=?"
        let recoveryPredicate = status == "parked" ? """
        AND EXISTS (SELECT 1 FROM history_occurrences recovered WHERE recovered.work_id=i.work_id
          AND recovered.snapshot_id=i.source_snapshot_id AND recovered.local_generation=i.source_generation
          AND recovered.reason='multipleResolutionRecovery')
        """ : ""
        return try query("""
        SELECT i.intent_id,c.work_id,c.conflict_id,c.current_revision,b.inbox_id,
               i.source_snapshot_id,i.source_generation,k.local_snapshot_id,k.remote_snapshot_id
        FROM conflicts c
        JOIN conflict_candidates k ON k.conflict_id=c.conflict_id AND k.revision=c.current_revision
        JOIN pending_keep_both p ON p.source_work_id=c.work_id AND p.conflict_id=c.conflict_id
          AND p.conflict_revision=c.current_revision AND p.source_generation=c.source_generation
          AND p.local_candidate_snapshot_id=k.local_snapshot_id AND p.remote_snapshot_id=k.remote_snapshot_id
        JOIN sealed_commands cmd ON cmd.command_id=p.command_id AND cmd.work_id=c.work_id
          AND cmd.command_kind='cloneWork' AND cmd.status='completed' AND cmd.receipt_verified=1
          AND cmd.server_instance_id=c.server_instance_id AND cmd.protocol_epoch=c.protocol_epoch
          AND cmd.account_id=c.account_id AND cmd.account_fence=c.account_fence
        JOIN account_bindings a ON a.work_id=c.work_id AND a.state='bound'
          AND a.server_instance_id=c.server_instance_id AND a.protocol_epoch=c.protocol_epoch
          AND a.account_id=c.account_id AND a.account_fence=c.account_fence
        JOIN works w ON w.work_id=c.work_id
          AND w.acknowledged_head_snapshot_id=p.expected_original_head_snapshot_id
          AND w.acknowledged_head_generation=p.expected_original_head_generation
        JOIN sync_intents i ON i.work_id=c.work_id AND i.kind='conflictResolution' AND i.status=?
          AND i.scope_kind='bound' AND i.source_generation=c.source_generation+1
          AND i.server_instance_id=c.server_instance_id AND i.protocol_epoch=c.protocol_epoch
          AND i.account_id=c.account_id AND i.account_fence=c.account_fence
        JOIN inbox_batches b ON b.work_id=c.work_id AND b.state='verified'
          AND b.snapshot_id=k.remote_snapshot_id AND b.expected_remote_head_snapshot_id=k.remote_snapshot_id
          AND b.expected_remote_head_generation=p.expected_original_head_generation
          AND b.server_instance_id=c.server_instance_id AND b.protocol_epoch=c.protocol_epoch
          AND b.account_id=c.account_id AND b.account_fence=c.account_fence
        WHERE c.state='resolved' AND p.state='finalized' \(workPredicate) \(recoveryPredicate)
          AND NOT EXISTS (SELECT 1 FROM sealed_commands s WHERE s.intent_id=i.intent_id)
          AND EXISTS (SELECT 1 FROM history_occurrences h WHERE h.work_id=i.work_id
            AND h.snapshot_id=i.source_snapshot_id AND h.local_generation=i.source_generation AND h.reason='conflictResolution')
          AND (SELECT COUNT(*) FROM snapshot_parents s WHERE s.work_id=i.work_id AND s.snapshot_id=i.source_snapshot_id)=2
          AND EXISTS (SELECT 1 FROM snapshot_parents s WHERE s.work_id=i.work_id AND s.snapshot_id=i.source_snapshot_id AND s.parent_snapshot_id=k.local_snapshot_id)
          AND EXISTS (SELECT 1 FROM snapshot_parents s WHERE s.work_id=i.work_id AND s.snapshot_id=i.source_snapshot_id AND s.parent_snapshot_id=k.remote_snapshot_id)
        ORDER BY b.inbox_id
        """, [.text(status)] + (workID.map { [.text($0.description)] } ?? []))
    }

    /// Caller owns BEGIN IMMEDIATE. Only the unsealed extra decision is parked;
    /// the finalized clone and every immutable byte remain untouched.
    func repairMultipleResolutionsTransaction() throws {
        for row in try multipleResolutionRows(status: "pending") {
            guard let id = try row.text("intent_id"),
                  let work = try row.text("work_id"),
                  let generation = try row.int64("source_generation") else {
                throw SyncV2StoreError.invalidSnapshot
            }
            try exec("UPDATE sync_intents SET status='parked' WHERE intent_id=? AND status='pending'", [.text(id)])
            guard try changes() == 1 else { continue }
            for (column, reason) in [("source_snapshot_id", "multipleResolutionRecovery"),
                                     ("local_snapshot_id", "preRemoteAdoption"),
                                     ("remote_snapshot_id", "remoteBaseline")] {
                guard let bytes = try row.blob(column) else { throw SyncV2StoreError.invalidSnapshot }
                try workRepository.insertHistory(workID: WorkID(uuidString: work),
                                                 snapshotID: SnapshotID(rawValue: bytes.hexString),
                                                 reason: reason, pinned: true, generation: generation)
            }
        }
    }

    func recoveredMultipleResolution(workID: WorkID, scope: V2LocalWorkScope) throws -> V2PendingServerAdoption? {
        guard case .bound = scope,
              let current = try workRepository.scopedWorkRow(workID: workID, scope: scope),
              let snapshot = current.currentSnapshotID, let generation = current.localGeneration else { return nil }
        guard let row = try multipleResolutionRows(status: "parked", workID: workID).first,
              let conflict = try row.text("conflict_id").flatMap(UUID.init(uuidString:)),
              let revision = try row.int64("current_revision"),
              let inbox = try row.text("inbox_id").flatMap(UUID.init(uuidString:)) else { return nil }
        return try V2PendingServerAdoption(workID: workID, inboxID: inbox,
                                           expectedCurrentSnapshotID: SnapshotID(rawValue: snapshot.hexString),
                                           expectedLocalGeneration: generation, conflictID: conflict,
                                           conflictRevision: revision, requiresExplicitConfirmation: true)
    }

    /// An explicit history restore creates a new chosen generation. Retire the
    /// unused recovery Inbox in the same commit so it cannot hold that restore
    /// indefinitely or later replace the restored content.
    func finishMultipleResolutionByRestore(workID: WorkID, scope: V2LocalWorkScope) throws {
        guard case let .bound(binding) = scope,
              let pending = try recoveredMultipleResolution(workID: workID, scope: scope) else { return }
        try exec("""
        UPDATE inbox_batches SET state='rejected',rejection_code='explicitRestoreReplacedRecovery'
        WHERE work_id=? AND state='verified'
          AND snapshot_id=(SELECT snapshot_id FROM inbox_batches WHERE inbox_id=?)
          AND server_instance_id=? AND protocol_epoch=? AND account_id=? AND account_fence=?
        """, [.text(workID.description), .text(pending.inboxID.uuidString.lowercased())] + binding.values)
    }
}

public extension LocalSyncV2Store {
    func hasRecoveredMultipleResolution(workID: WorkID, scope: V2LocalWorkScope) throws -> Bool {
        try conflictRepository.recoveredMultipleResolution(workID: workID, scope: scope) != nil
    }
}

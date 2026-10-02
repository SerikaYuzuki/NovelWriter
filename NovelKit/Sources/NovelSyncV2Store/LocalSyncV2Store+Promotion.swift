import Foundation
import NovelSyncV2

public extension LocalSyncV2Store {
    func hasUnpromotedLeaf(workID: WorkID, scope: V2LocalWorkScope) throws -> Bool {
        guard let row = try scopedWorkRow(workID: workID, scope: scope),
              let bytes = row[3].blob else { return false }
        return try isUnpromotedLeaf(workID: workID, snapshotID: SnapshotID(rawValue: bytes.hexString))
    }

    /// Launch/foreground recovery is scoped to the attested account only.
    func promoteUnpromotedLeaves(scope: V2LocalWorkScope) throws {
        for work in try listWorks(scope: scope) where try workDeletion(workID: work.workID) == nil {
            try promoteCurrentLeaf(workID: work.workID, scope: scope)
        }
    }

    /// Promote durable bytes only. This never captures or installs editor text.
    @discardableResult
    func promoteCurrentLeaf(workID: WorkID, scope: V2LocalWorkScope) throws -> Bool {
        try inTransaction {
            try promoteCurrentLeafTransaction(workID: workID, scope: scope)
        }
    }
}

extension LocalSyncV2Store {
    /// The distinct local reason also provides an upgrade boundary: every old
    /// occurrence (including legacy autosaves) remains a stable checkpoint.
    func isUnpromotedLeaf(workID: WorkID, snapshotID: SnapshotID) throws -> Bool {
        let rows = try query(
            """
            SELECT reason,pinned FROM history_occurrences
            WHERE work_id=? AND snapshot_id=?
            """, [.text(workID.description), .blob(snapshotID.bytes)]
        )
        return !rows.isEmpty && rows.allSatisfy {
            $0[0].text == "autosaveLeaf" && $0[1].int64 == 0
        }
    }

    func checkpointParents(workID: WorkID, current: SnapshotID) throws -> [SnapshotID] {
        guard try isUnpromotedLeaf(workID: workID, snapshotID: current) else { return [current] }
        return try query(
            "SELECT parent_snapshot_id FROM snapshot_parents WHERE work_id=? AND snapshot_id=?",
            [.text(workID.description), .blob(current.bytes)]
        ).map { row in
            guard let bytes = row[0].blob else { throw SyncV2StoreError.invalidSnapshot }
            return try SnapshotID(rawValue: bytes.hexString)
        }
    }

    @discardableResult
    func promoteCurrentLeafTransaction(
        workID: WorkID, scope: V2LocalWorkScope, reason: String = "promotion"
    ) throws -> Bool {
        try requireNotDeleting(workID)
        guard let row = try scopedWorkRow(workID: workID, scope: scope),
              let bytes = row[3].blob, let generation = row[2].int64,
              row[6].text == V2SyncLane.normal.rawValue else { return false }
        let current = try SnapshotID(rawValue: bytes.hexString)
        guard try isUnpromotedLeaf(workID: workID, snapshotID: current),
              try !isAcknowledgedContent(workID: workID, snapshotID: current, scope: scope) else { return false }
        // A parked work remains local. A later same-account resume/open can
        // promote it, without creating an unbound lane for another account.
        if case .parked = scope {
            return false
        }
        try insertHistory(workID: workID, snapshotID: current, reason: reason,
                          pinned: true, generation: generation)
        _ = try upsertCheckpointIntent(workID: workID, snapshotID: current,
                                       generation: generation, scope: scope)
        return true
    }
}

extension LocalSyncV2Store {
    /// A newly saved leaf must not invalidate the in-flight stable checkpoint.
    /// The intent still has to match exactly in validatePublish; arbitrary old
    /// snapshots and a newer protected checkpoint are not accepted here.
    func publishSourceIsCurrentOrStableParent(
        command: SealedCommand, workID: WorkID, work: [SQLiteValue]
    ) throws -> Bool {
        guard let bytes = work[3].blob, let generation = work[2].int64 else { return false }
        let current = try SnapshotID(rawValue: bytes.hexString)
        if generation == command.sourceGeneration, current == command.sourceSnapshotId {
            return true
        }
        guard generation > command.sourceGeneration,
              try isUnpromotedLeaf(workID: workID, snapshotID: current) else { return false }
        return try checkpointParents(workID: workID, current: current) == [command.sourceSnapshotId]
    }
}

public extension LocalSyncV2Store {
    /// Content identity is separate from the latest observed (possibly newer) head.
    func isAcknowledgedContent(workID: WorkID, snapshotID: SnapshotID, scope: V2LocalWorkScope) throws -> Bool {
        guard case let .bound(binding) = scope,
              let row = try scopedWorkRow(workID: workID, scope: scope),
              let headGeneration = row[4].int64 else { return false }
        return try !query("""
            SELECT 1 FROM snapshot_remote_equivalents e
            WHERE e.work_id=? AND e.local_snapshot_id=? AND e.remote_snapshot_id=e.local_snapshot_id
              AND e.remote_generation<=?
              AND EXISTS (SELECT 1 FROM sealed_commands c JOIN sync_intents i ON i.intent_id=c.intent_id
                WHERE c.work_id=e.work_id AND i.source_snapshot_id=e.local_snapshot_id
                  AND c.status='completed' AND c.receipt_verified=1
                  AND c.server_instance_id=? AND c.protocol_epoch=? AND c.account_id=? AND c.account_fence=?)
            UNION SELECT 1 FROM works w
            WHERE w.work_id=? AND w.current_snapshot_id=? AND w.acknowledged_head_snapshot_id=w.current_snapshot_id
              AND EXISTS (SELECT 1 FROM inbox_batches b WHERE b.work_id=w.work_id AND b.snapshot_id=w.current_snapshot_id
                AND b.state='adopted' AND b.server_instance_id=? AND b.protocol_epoch=? AND b.account_id=? AND b.account_fence=?)
            """, [.text(workID.description), .blob(snapshotID.bytes), .int(headGeneration)] + binding.values +
                [.text(workID.description), .blob(snapshotID.bytes)] + binding.values).isEmpty
    }
}

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
        guard try isUnpromotedLeaf(workID: workID, snapshotID: current) else { return false }
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

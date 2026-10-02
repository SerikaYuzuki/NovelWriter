import Foundation
import NovelCore
import NovelSyncV2

extension LocalSyncV2Store {
    func validateConflictBase(
        _ baseSnapshotID: SnapshotID?,
        localSnapshotID: SnapshotID,
        remoteSnapshotID: SnapshotID,
        workID: WorkID,
        graph: V2RemoteSnapshotGraph
    ) throws {
        // A materialized base is a proven common cut: ancestors below it
        // cannot contain either descendant without forming a cycle. This keeps
        // ordinary L/R conflicts above H available during history backfill.
        let stopAt: SnapshotID? = if let baseSnapshotID,
                                     try hasSnapshot(workID: workID, snapshotID: baseSnapshotID) ||
                                     graph.snapshots.contains(where: { $0.snapshotId == baseSnapshotID }) {
            baseSnapshotID
        } else {
            nil
        }
        let localAncestors = try conflictAncestors(
            from: localSnapshotID,
            workID: workID,
            graph: graph, stopAt: stopAt
        )
        let remoteAncestors = try conflictAncestors(
            from: remoteSnapshotID,
            workID: workID,
            graph: graph, stopAt: stopAt
        )
        guard localSnapshotID != remoteSnapshotID,
              !remoteAncestors.ids.contains(localSnapshotID),
              !localAncestors.ids.contains(remoteSnapshotID) else {
            throw SyncV2StoreError.invalidSnapshot
        }
        guard !localAncestors.incomplete, !remoteAncestors.incomplete else {
            throw SyncV2StoreError.historyIncomplete
        }
        if let baseSnapshotID {
            guard localAncestors.ids.contains(baseSnapshotID),
                  remoteAncestors.ids.contains(baseSnapshotID) else {
                throw SyncV2StoreError.invalidSnapshot
            }
        } else {
            guard localAncestors.ids.isDisjoint(with: remoteAncestors.ids) else {
                throw SyncV2StoreError.invalidSnapshot
            }
        }
    }

    func graphHead(
        _ graph: V2RemoteSnapshotGraph,
        containsAncestor snapshotID: SnapshotID
    ) throws -> Bool {
        let ancestors = try conflictAncestors(
            from: graph.headSnapshotID,
            workID: graph.workID,
            graph: graph
        )
        if ancestors.ids.contains(snapshotID) {
            return true
        }
        guard !ancestors.incomplete else { throw SyncV2StoreError.historyIncomplete }
        return false
    }

    private func conflictAncestors(
        from snapshotID: SnapshotID,
        workID: WorkID,
        graph: V2RemoteSnapshotGraph,
        stopAt: SnapshotID? = nil
    ) throws -> (ids: Set<SnapshotID>, incomplete: Bool) {
        let graphSnapshots = Dictionary(
            uniqueKeysWithValues: graph.snapshots.map { ($0.snapshotId, $0) }
        )
        var result = Set<SnapshotID>()
        var incomplete = false
        var stack = [snapshotID]
        while let current = stack.popLast() {
            guard result.insert(current).inserted else { continue }
            if current == stopAt {
                continue
            }
            if let snapshot = graphSnapshots[current] {
                stack.append(contentsOf: snapshot.manifest.parentSnapshotIds)
            } else {
                if try isBoundary(workID: workID, snapshotID: current) {
                    incomplete = true
                    continue
                }
                let parents = try query(
                    """
                    SELECT parent_snapshot_id FROM snapshot_parents
                    WHERE work_id=? AND snapshot_id=?
                    UNION ALL SELECT parent_snapshot_id FROM shallow_boundaries
                    WHERE work_id=? AND snapshot_id=?
                    """,
                    [.text(workID.description), .blob(current.bytes),
                     .text(workID.description), .blob(current.bytes)]
                )
                guard try !parents.isEmpty || !query(
                    "SELECT 1 FROM snapshots WHERE work_id=? AND snapshot_id=?",
                    [.text(workID.description), .blob(current.bytes)]
                ).isEmpty else {
                    throw SyncV2StoreError.invalidSnapshot
                }
                for row in parents {
                    guard let bytes = try row.scalar.blob else {
                        throw SyncV2StoreError.invalidSnapshot
                    }
                    try stack.append(SnapshotID(rawValue: bytes.hexString))
                }
            }
        }
        return (result, incomplete)
    }
}

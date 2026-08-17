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
        let localAncestors = try conflictAncestors(
            from: localSnapshotID,
            workID: workID,
            graph: graph
        )
        let remoteAncestors = try conflictAncestors(
            from: remoteSnapshotID,
            workID: workID,
            graph: graph
        )
        guard localSnapshotID != remoteSnapshotID,
              !remoteAncestors.contains(localSnapshotID),
              !localAncestors.contains(remoteSnapshotID) else {
            throw SyncV2StoreError.invalidSnapshot
        }
        if let baseSnapshotID {
            guard localAncestors.contains(baseSnapshotID),
                  remoteAncestors.contains(baseSnapshotID) else {
                throw SyncV2StoreError.invalidSnapshot
            }
        } else {
            guard localAncestors.isDisjoint(with: remoteAncestors) else {
                throw SyncV2StoreError.invalidSnapshot
            }
        }
    }

    func graphHead(
        _ graph: V2RemoteSnapshotGraph,
        containsAncestor snapshotID: SnapshotID
    ) throws -> Bool {
        try conflictAncestors(
            from: graph.headSnapshotID,
            workID: graph.workID,
            graph: graph
        ).contains(snapshotID)
    }

    private func conflictAncestors(
        from snapshotID: SnapshotID,
        workID: WorkID,
        graph: V2RemoteSnapshotGraph
    ) throws -> Set<SnapshotID> {
        let graphSnapshots = Dictionary(
            uniqueKeysWithValues: graph.snapshots.map { ($0.snapshotId, $0) }
        )
        var result = Set<SnapshotID>()
        var stack = [snapshotID]
        while let current = stack.popLast() {
            guard result.insert(current).inserted else { continue }
            if let snapshot = graphSnapshots[current] {
                stack.append(contentsOf: snapshot.manifest.parentSnapshotIds)
            } else {
                let parents = try query(
                    """
                    SELECT parent_snapshot_id FROM snapshot_parents
                    WHERE work_id=? AND snapshot_id=?
                    """,
                    [.text(workID.description), .blob(current.bytes)]
                )
                guard try !parents.isEmpty || !query(
                    "SELECT 1 FROM snapshots WHERE work_id=? AND snapshot_id=?",
                    [.text(workID.description), .blob(current.bytes)]
                ).isEmpty else {
                    throw SyncV2StoreError.invalidSnapshot
                }
                for row in parents {
                    guard let bytes = row[0].blob else {
                        throw SyncV2StoreError.invalidSnapshot
                    }
                    try stack.append(SnapshotID(rawValue: bytes.hexString))
                }
            }
        }
        return result
    }
}

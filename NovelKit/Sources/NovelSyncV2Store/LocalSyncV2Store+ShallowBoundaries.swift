import Foundation
import NovelSyncV2

public extension LocalSyncV2Store {
    func isBoundary(workID: WorkID, snapshotID: SnapshotID, scope: V2LocalWorkScope) throws -> Bool {
        guard try scopedWorkRow(workID: workID, scope: scope) != nil else { return false }
        return try isBoundary(workID: workID, snapshotID: snapshotID)
    }
}

extension LocalSyncV2Store {
    func hasSnapshot(workID: WorkID, snapshotID: SnapshotID) throws -> Bool {
        try !query("SELECT 1 FROM snapshots WHERE work_id=? AND snapshot_id=?",
                   [.text(workID.description), .blob(snapshotID.bytes)]).isEmpty
    }

    func isBoundary(workID: WorkID, snapshotID: SnapshotID) throws -> Bool {
        try !query("SELECT 1 FROM shallow_boundaries WHERE work_id=? AND parent_snapshot_id=? LIMIT 1",
                   [.text(workID.description), .blob(snapshotID.bytes)]).isEmpty
    }

    func hasBoundaries(workID: WorkID) throws -> Bool {
        try !query("SELECT 1 FROM shallow_boundaries WHERE work_id=? LIMIT 1",
                   [.text(workID.description)]).isEmpty
    }

    /// B2: all insertion paths close incoming edges in the insertion transaction.
    func resolveBoundaries(workID: WorkID, parent: SnapshotID) throws {
        let values: [SQLiteValue] = [.text(workID.description), .blob(parent.bytes)]
        try exec("""
        INSERT INTO snapshot_parents(work_id,snapshot_id,parent_snapshot_id)
        SELECT work_id,snapshot_id,parent_snapshot_id FROM shallow_boundaries
        WHERE work_id=? AND parent_snapshot_id=?
        """, values)
        try exec("DELETE FROM shallow_boundaries WHERE work_id=? AND parent_snapshot_id=?", values)
        registeredAncestorCache = nil
    }
}

public extension LocalSyncV2Store {
    func historyIsIncomplete(workID: WorkID, scope: V2LocalWorkScope) throws -> Bool {
        guard try scopedWorkRow(workID: workID, scope: scope) != nil else { return false }
        return try hasBoundaries(workID: workID)
    }
}

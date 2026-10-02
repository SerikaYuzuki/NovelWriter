import Foundation
import NovelSyncV2

public struct V2RestoreCommandSource: Sendable {
    public let previousSnapshotID: SnapshotID
    public let selectedSnapshotID: SnapshotID
    public let restoredSnapshotID: SnapshotID
    public let previousGeneration: Int64
    public let expectedRemoteHead: V2RemoteHead?
}

public extension LocalSyncV2Store {
    /// Replay source comes from the prepared restore, never the newer editor head.
    func restoreCommandSource(workID: WorkID, intentID: UUID, scope: V2LocalWorkScope) throws -> V2RestoreCommandSource {
        guard try scopedWorkRow(workID: workID, scope: scope) != nil,
              let intent = try pendingIntents(scope: scope, workID: workID).first(where: { $0.intentID == intentID }),
              intent.kind == "restore", intent.sourceGeneration > 1,
              let row = try query(
                  """
                  SELECT pre_restore_snapshot_id,selected_snapshot_id,result_snapshot_id,
                         expected_remote_head_snapshot_id,expected_remote_head_generation
                  FROM restore_records WHERE work_id=? AND intent_id=? AND state='prepared'
                  """, [.text(workID.description), .text(intentID.uuidString.lowercased())]
              ).first,
              let previous = row[0].blob, let selected = row[1].blob,
              row[2].blob == intent.sourceSnapshotID.bytes else { throw SyncV2StoreError.invalidCommand }
        return try V2RestoreCommandSource(
            previousSnapshotID: SnapshotID(rawValue: previous.hexString),
            selectedSnapshotID: SnapshotID(rawValue: selected.hexString),
            restoredSnapshotID: intent.sourceSnapshotID,
            previousGeneration: intent.sourceGeneration - 1,
            expectedRemoteHead: Self.head(snapshot: row[3].blob, generation: row[4].int64)
        )
    }
}

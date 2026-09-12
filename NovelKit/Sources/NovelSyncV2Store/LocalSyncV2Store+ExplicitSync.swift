import Foundation
import NovelSyncV2

public extension LocalSyncV2Store {
    /// Reconcile the current snapshot with the server even without new edits.
    /// A fresh publish goes through the normal verified receipt/Inbox path.
    /// Existing durable commands keep their identity and retry ordering.
    func requestSynchronization(workID: WorkID, scope: V2LocalWorkScope) throws {
        guard case .bound = scope else { throw SyncV2StoreError.accountMismatch }
        try inTransaction {
            guard let row = try scopedWorkRow(workID: workID, scope: scope),
                  let generation = row[2].int64,
                  let snapshot = row[3].blob,
                  row[6].text == V2SyncLane.normal.rawValue else {
                throw SyncV2StoreError.accountMismatch
            }
            guard try pendingIntents(scope: scope, workID: workID).isEmpty else { return }
            _ = try upsertCheckpointIntent(
                workID: workID,
                snapshotID: SnapshotID(rawValue: snapshot.hexString),
                generation: generation,
                scope: scope
            )
        }
    }
}

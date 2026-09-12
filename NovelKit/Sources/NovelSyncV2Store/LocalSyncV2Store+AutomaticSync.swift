import Foundation
import NovelSyncV2

public extension LocalSyncV2Store {
    /// Metadata-only read: periodic checks never decode every work on the shelf.
    func automaticSyncCandidate(
        workID: WorkID, scope: V2LocalWorkScope
    ) throws -> (generation: Int64, head: V2RemoteHead)? {
        guard case .bound = scope,
              let row = try scopedWorkRow(workID: workID, scope: scope),
              let generation = row[2].int64,
              row[6].text == V2SyncLane.normal.rawValue,
              try activeConflict(workID: workID, scope: scope) == nil,
              try pendingIntents(scope: scope, workID: workID).isEmpty,
              let head = try acknowledgedHead(workID: workID) else { return nil }
        return (generation, head)
    }

    /// A head check may race a local checkpoint. Queue only the exact clean
    /// generation inspected by that check; never retry a quarantined command.
    func requestAutomaticSynchronization(
        workID: WorkID, scope: V2LocalWorkScope, expectedLocalGeneration: Int64
    ) throws -> Bool {
        guard case .bound = scope else { return false }
        return try inTransaction {
            guard let row = try scopedWorkRow(workID: workID, scope: scope),
                  row[2].int64 == expectedLocalGeneration,
                  let snapshot = row[3].blob,
                  row[6].text == V2SyncLane.normal.rawValue,
                  try activeConflict(workID: workID, scope: scope) == nil,
                  try pendingIntents(scope: scope, workID: workID).isEmpty,
                  try allSealedCommands(scope: scope, workID: workID).allSatisfy({
                      $0.lifecycle == .completed || $0.sourceGeneration < expectedLocalGeneration
                  }) else { return false }
            _ = try upsertCheckpointIntent(
                workID: workID, snapshotID: SnapshotID(rawValue: snapshot.hexString),
                generation: expectedLocalGeneration, scope: scope
            )
            return true
        }
    }
}

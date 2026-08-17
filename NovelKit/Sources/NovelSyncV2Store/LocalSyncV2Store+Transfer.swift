import Foundation
import NovelSyncV2

public extension LocalSyncV2Store {
    /// Returns the exact current manifest/object bytes and the intent that the
    /// worker is allowed to replicate.  No JSON decode/re-encode happens here.
    func immutableTransferView(
        workID: WorkID,
        scope: V2LocalWorkScope
    ) throws -> V2ImmutableTransferView? {
        guard case let .bound(binding) = scope,
              let row = try scopedWorkRow(workID: workID, scope: scope),
              let snapshotID = row[3].blob else {
            return nil
        }
        let summary = try Self.summary(row)
        guard let intent = try pendingIntents(scope: scope, workID: workID).first else {
            return nil
        }
        let snapshot = try loadEncoded(
            workID: workID,
            snapshotID: SnapshotID(rawValue: snapshotID.hexString)
        )
        return try V2ImmutableTransferView(
            workID: workID,
            binding: binding,
            summary: summary,
            snapshot: snapshot,
            pendingIntent: intent,
            expectedRemoteHead: acknowledgedHead(workID: workID)
        )
    }

    func pendingWorkIDs(scope: V2LocalWorkScope) throws -> [WorkID] {
        let summaries = try listWorks(scope: scope)
        return try summaries.compactMap { summary in
            let pending = try pendingIntents(scope: scope, workID: summary.workID)
            let commands = try pendingSealedCommands(scope: scope, workID: summary.workID)
            return pending.isEmpty && commands.isEmpty ? nil : summary.workID
        }
    }
}

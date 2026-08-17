import Foundation
import NovelSyncV2

public extension LocalSyncV2Store {
    func remoteHeadForConflict(
        _ conflict: V2ConflictCandidate,
        scope: V2LocalWorkScope
    ) throws -> V2RemoteHead {
        guard case let .bound(binding) = scope else { throw SyncV2StoreError.accountMismatch }
        let inboxID = try conflictInbox(conflict)
        let graph = try loadInboxGraph(inboxID: inboxID, binding: binding)
        guard let head = graph.expectedRemoteHead,
              head.snapshotID == conflict.remoteSnapshotID else {
            throw SyncV2StoreError.invalidRemoteHead
        }
        return head
    }

    func conflictInboxID(_ conflict: V2ConflictCandidate) throws -> UUID {
        try conflictInbox(conflict)
    }

    func pendingServerAdoption(
        workID: WorkID,
        scope: V2LocalWorkScope
    ) throws -> V2PendingServerAdoption? {
        guard case let .bound(binding) = scope,
              let active = try activeConflict(workID: workID, scope: scope),
              let row = try query(
                  """
                  SELECT command_id FROM sealed_commands
                  WHERE work_id=? AND command_kind='resolveServer'
                    AND status='completed' AND server_instance_id=?
                    AND protocol_epoch=? AND account_id=? AND account_fence=?
                  ORDER BY rowid DESC LIMIT 1
                  """,
                  [.text(workID.description)] + binding.values
              ).first,
              row[0].text != nil else {
            return nil
        }
        let inboxID = try conflictInbox(active)
        guard try inboxState(inboxID: inboxID, binding: binding) == "verified",
              let current = try scopedWorkRow(workID: workID, scope: scope),
              let generation = current[2].int64,
              let snapshot = current[3].blob else {
            return nil
        }
        let expected = try SnapshotID(rawValue: snapshot.hexString)
        guard generation == active.sourceGeneration,
              expected == active.localSnapshotID else { return nil }
        return V2PendingServerAdoption(
            workID: workID,
            inboxID: inboxID,
            expectedCurrentSnapshotID: expected,
            expectedLocalGeneration: generation,
            conflictID: active.conflictID,
            conflictRevision: active.revision
        )
    }

    func adoptPendingServerResolution(
        workID: WorkID,
        inboxID: UUID,
        scope: V2LocalWorkScope
    ) throws -> V2OpenResult {
        guard case let .bound(binding) = scope,
              let pending = try pendingServerAdoption(workID: workID, scope: scope),
              pending.inboxID == inboxID else {
            throw SyncV2StoreError.staleCAS
        }
        let graph = try loadInboxGraph(inboxID: inboxID, binding: binding)
        guard let remoteHead = graph.expectedRemoteHead else {
            throw SyncV2StoreError.invalidRemoteHead
        }
        let request = V2ServerResolutionRequest(
            workID: workID,
            conflictID: pending.conflictID,
            revision: pending.conflictRevision,
            sourceGeneration: pending.expectedLocalGeneration,
            localSnapshotID: pending.expectedCurrentSnapshotID,
            remoteSnapshotID: graph.headSnapshotID,
            inboxID: inboxID,
            expectedRemoteHead: remoteHead
        )
        try inTransaction {
            try adoptGraphTransaction(graph, expectedConflict: request, binding: binding)
        }
        return try open(workID: workID, scope: scope)
    }
}

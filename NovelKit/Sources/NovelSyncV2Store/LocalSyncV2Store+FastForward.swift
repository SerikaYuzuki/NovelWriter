import Foundation
import NovelSyncV2

public struct V2PendingFastForward: Hashable, Sendable {
    public let inboxID: UUID
    public let snapshotID: SnapshotID
    public let generation: Int64
}

public extension LocalSyncV2Store {
    /// Only a verified publish receipt can authorize the corresponding Inbox.
    /// Selection is durable across restart; no editor mutation happens here.
    func pendingFastForward(workID: WorkID, scope: V2LocalWorkScope) throws -> V2PendingFastForward? {
        guard case let .bound(binding) = scope,
              let current = try scopedWorkRow(workID: workID, scope: scope),
              let bytes = current[3].blob, let generation = current[2].int64,
              try activeConflict(workID: workID, scope: scope) == nil,
              try pendingIntents(scope: scope, workID: workID).isEmpty else { return nil }
        let candidates = try query(
            """
            SELECT i.inbox_id FROM inbox_batches i
            JOIN sealed_commands c ON c.work_id=i.work_id
              AND c.source_snapshot_id=i.expected_current_snapshot_id
              AND c.source_generation=i.expected_local_generation
              AND c.server_instance_id=i.server_instance_id AND c.protocol_epoch=i.protocol_epoch
              AND c.account_id=i.account_id AND c.account_fence=i.account_fence
            JOIN remote_receipts r ON r.account_id=c.account_id AND r.command_id=c.command_id
              AND r.remote_head_snapshot_id=i.snapshot_id
              AND r.remote_head_generation=i.expected_remote_head_generation
            WHERE i.work_id=? AND i.server_instance_id=? AND i.protocol_epoch=?
              AND i.account_id=? AND i.account_fence=? AND i.state='verified'
              AND c.command_kind='publish' AND c.status='completed' AND c.receipt_verified=1
              AND r.terminal_result='noChanges'
              AND i.expected_current_snapshot_id=? AND i.expected_local_generation=?
              AND i.snapshot_id<>i.expected_current_snapshot_id
            ORDER BY i.expected_remote_head_generation DESC
            """,
            [.text(workID.description)] + binding.values + [.blob(bytes), .int(generation)]
        )
        guard let id = candidates.first?[0].text.flatMap(UUID.init(uuidString:)) else { return nil }
        let snapshot = try SnapshotID(rawValue: bytes.hexString)
        let graph = try loadInboxGraph(inboxID: id, binding: binding)
        guard try graphHead(graph, containsAncestor: snapshot) else { throw SyncV2StoreError.invalidSnapshot }
        return V2PendingFastForward(inboxID: id, snapshotID: snapshot, generation: generation)
    }

    /// Called only through the application's consumed document gate. The DB
    /// transaction repeats the generation/pending-intent checks before install.
    func adoptPendingFastForward(workID: WorkID, inboxID: UUID, scope: V2LocalWorkScope) throws -> V2OpenResult {
        try inTransaction {
            guard let pending = try pendingFastForward(workID: workID, scope: scope),
                  pending.inboxID == inboxID,
                  case let .bound(binding) = scope else { throw SyncV2StoreError.staleCAS }
            let graph = try loadInboxGraph(inboxID: inboxID, binding: binding)
            try adoptGraphTransaction(graph, expectedConflict: nil, binding: binding)
        }
        return try open(workID: workID, scope: scope)
    }
}

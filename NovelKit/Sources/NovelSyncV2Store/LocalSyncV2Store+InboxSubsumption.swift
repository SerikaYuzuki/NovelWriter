import Foundation
import NovelSyncV2

public extension LocalSyncV2Store {
    /// Adopts a verified remote descendant after proving that it already
    /// contains the exact still-pending local checkpoint.
    func adoptInboxSubsumingPendingIntent(
        inboxID: UUID,
        intentID: UUID,
        scope: V2LocalWorkScope
    ) throws {
        guard case let .bound(binding) = scope else {
            throw SyncV2StoreError.accountMismatch
        }
        try inTransaction {
            if try subsumptionWasApplied(
                inboxID: inboxID,
                intentID: intentID,
                binding: binding
            ) {
                return
            }
            let graph = try loadInboxGraph(inboxID: inboxID, binding: binding)
            guard try inboxState(inboxID: inboxID, binding: binding) == "verified" else {
                throw SyncV2StoreError.inboxNotFound
            }
            _ = try validateGraph(graph)
            try validateGraphParents(graph)
            let intent = try pendingSubsumptionIntent(
                intentID: intentID,
                graph: graph,
                binding: binding
            )
            guard intent.snapshotID != graph.headSnapshotID,
                  try graphHead(graph, containsAncestor: intent.snapshotID) else {
                throw SyncV2StoreError.staleCAS
            }
            try acknowledgeSubsumedIntent(intent, binding: binding)
            try adoptGraphTransaction(graph, expectedConflict: nil, binding: binding)
            try recordSubsumption(
                intent,
                inboxID: inboxID,
                remoteHead: requiredRemoteHead(graph),
                binding: binding
            )
        }
    }
}

extension LocalSyncV2Store {
    struct PendingSubsumptionIntent {
        let intentID: UUID
        let workID: WorkID
        let snapshotID: SnapshotID
        let generation: Int64
    }

    private func pendingSubsumptionIntent(
        intentID: UUID,
        graph: V2RemoteSnapshotGraph,
        binding: V2AccountBinding
    ) throws -> PendingSubsumptionIntent {
        guard let row = try query(
            """
            SELECT work_id,source_snapshot_id,source_generation,kind,status
            FROM sync_intents
            WHERE intent_id=? AND scope_kind='bound'
              AND server_instance_id=? AND protocol_epoch=?
              AND account_id=? AND account_fence=?
            """,
            [.text(intentID.uuidString.lowercased())] + binding.values
        ).first,
            row[0].text == graph.workID.description,
            let snapshotBytes = row[1].blob,
            let generation = row[2].int64,
            ["checkpoint", "latest"].contains(row[3].text ?? ""),
            row[4].text == "pending",
            graph.expectedCurrentSnapshotID?.bytes == snapshotBytes,
            graph.expectedLocalGeneration == generation,
            try query(
                "SELECT 1 FROM sealed_commands WHERE intent_id=? LIMIT 1",
                [.text(intentID.uuidString.lowercased())]
            ).isEmpty else {
            throw SyncV2StoreError.staleCAS
        }
        return try PendingSubsumptionIntent(
            intentID: intentID,
            workID: graph.workID,
            snapshotID: SnapshotID(rawValue: snapshotBytes.hexString),
            generation: generation
        )
    }

    private func acknowledgeSubsumedIntent(
        _ intent: PendingSubsumptionIntent,
        binding: V2AccountBinding
    ) throws {
        try exec(
            """
            UPDATE sync_intents SET status='acknowledged'
            WHERE intent_id=? AND work_id=? AND source_snapshot_id=?
              AND source_generation=? AND kind IN ('checkpoint','latest')
              AND status='pending' AND scope_kind='bound'
              AND server_instance_id=? AND protocol_epoch=?
              AND account_id=? AND account_fence=?
            """,
            [
                .text(intent.intentID.uuidString.lowercased()),
                .text(intent.workID.description), .blob(intent.snapshotID.bytes),
                .int(intent.generation)
            ] + binding.values
        )
        guard try changes() == 1 else { throw SyncV2StoreError.staleCAS }
    }

    private func recordSubsumption(
        _ intent: PendingSubsumptionIntent,
        inboxID: UUID,
        remoteHead: V2RemoteHead,
        binding: V2AccountBinding
    ) throws {
        try exec(
            """
            INSERT INTO intent_subsumptions(
              intent_id,inbox_id,work_id,source_snapshot_id,source_generation,
              remote_head_snapshot_id,remote_head_generation,
              server_instance_id,protocol_epoch,account_id,account_fence,created_at
            ) VALUES(?,?,?,?,?,?,?,?,?,?,?,?)
            """,
            [
                .text(intent.intentID.uuidString.lowercased()),
                .text(inboxID.uuidString.lowercased()),
                .text(intent.workID.description), .blob(intent.snapshotID.bytes),
                .int(intent.generation), .blob(remoteHead.snapshotID.bytes),
                .int(remoteHead.generation)
            ] + binding.values + [.text(Self.now())]
        )
    }

    private func subsumptionWasApplied(
        inboxID: UUID,
        intentID: UUID,
        binding: V2AccountBinding
    ) throws -> Bool {
        try !query(
            """
            SELECT 1 FROM intent_subsumptions s
            JOIN sync_intents i ON i.intent_id=s.intent_id
            JOIN inbox_batches b ON b.inbox_id=s.inbox_id
            JOIN account_bindings a
              ON a.work_id=s.work_id
             AND a.server_instance_id=s.server_instance_id
             AND a.protocol_epoch=s.protocol_epoch
             AND a.account_id=s.account_id
             AND a.account_fence=s.account_fence
            WHERE s.intent_id=? AND s.inbox_id=?
              AND s.server_instance_id=? AND s.protocol_epoch=?
              AND s.account_id=? AND s.account_fence=?
              AND i.work_id=s.work_id
              AND i.source_snapshot_id=s.source_snapshot_id
              AND i.source_generation=s.source_generation
              AND i.status='acknowledged' AND b.work_id=s.work_id
              AND b.snapshot_id=s.remote_head_snapshot_id
              AND b.expected_remote_head_snapshot_id=s.remote_head_snapshot_id
              AND b.expected_remote_head_generation=s.remote_head_generation
              AND b.state='adopted' AND a.state='bound'
            LIMIT 1
            """,
            [
                .text(intentID.uuidString.lowercased()),
                .text(inboxID.uuidString.lowercased())
            ] + binding.values
        ).isEmpty
    }

    private func requiredRemoteHead(_ graph: V2RemoteSnapshotGraph) throws -> V2RemoteHead {
        guard let head = graph.expectedRemoteHead,
              head.snapshotID == graph.headSnapshotID else {
            throw SyncV2StoreError.invalidSnapshot
        }
        return head
    }
}

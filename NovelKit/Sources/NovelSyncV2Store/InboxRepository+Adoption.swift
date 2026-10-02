import Foundation
import NovelCore
import NovelSyncV2

extension InboxRepository {
    func remoteHeadForConflict(
        _ conflict: V2ConflictCandidate,
        scope: V2LocalWorkScope
    ) throws -> V2RemoteHead {
        guard case let .bound(binding) = scope else { throw SyncV2StoreError.accountMismatch }
        let inboxID = try conflictRepository.conflictInbox(conflict)
        let graph = try loadInboxGraph(inboxID: inboxID, binding: binding)
        guard let head = graph.expectedRemoteHead,
              head.snapshotID == conflict.remoteSnapshotID else {
            throw SyncV2StoreError.invalidRemoteHead
        }
        return head
    }

    func conflictInboxID(_ conflict: V2ConflictCandidate) throws -> UUID {
        try conflictRepository.conflictInbox(conflict)
    }

    func pendingServerAdoption(
        workID: WorkID,
        scope: V2LocalWorkScope
    ) throws -> V2PendingServerAdoption? {
        guard case let .bound(binding) = scope,
              let active = try conflictRepository.activeConflict(workID: workID, scope: scope),
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
              try row.scalar.text != nil else {
            return nil
        }
        let inboxID = try conflictRepository.conflictInbox(active)
        guard try inboxState(inboxID: inboxID, binding: binding) == "verified",
              let current = try workRepository.scopedWorkRow(workID: workID, scope: scope),
              let generation = current.localGeneration,
              let snapshot = current.currentSnapshotID else {
            return nil
        }
        let expected = try SnapshotID(rawValue: snapshot.hexString)
        guard generation >= active.sourceGeneration else { return nil }
        return V2PendingServerAdoption(
            workID: workID,
            inboxID: inboxID,
            expectedCurrentSnapshotID: expected,
            expectedLocalGeneration: generation,
            conflictID: active.conflictID,
            conflictRevision: active.revision
        )
    }
}

extension InboxRepository {
    func pendingFastForward(workID: WorkID, scope: V2LocalWorkScope) throws -> V2PendingFastForward? {
        guard case let .bound(binding) = scope,
              let current = try workRepository.scopedWorkRow(workID: workID, scope: scope),
              let bytes = current.currentSnapshotID, let generation = current.localGeneration,
              try conflictRepository.activeConflict(workID: workID, scope: scope) == nil,
              try outboxRepository.pendingIntents(scope: scope, workID: workID).isEmpty else { return nil }
        var candidates = try query(
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
        // Clean read reconciliation has no redundant publish receipt. Its
        // authenticated verified graph must descend from received local bytes.
        if candidates.isEmpty,
           try workRepository.isAcknowledgedContent(
               workID: workID,
               snapshotID: SnapshotID(rawValue: bytes.hexString),
               scope: scope
           ) {
            candidates = try query("""
            SELECT inbox_id FROM inbox_batches
            WHERE work_id=? AND server_instance_id=? AND protocol_epoch=? AND account_id=? AND account_fence=?
              AND state='verified' AND expected_current_snapshot_id=? AND expected_local_generation=?
              AND snapshot_id<>expected_current_snapshot_id
              AND expected_remote_head_generation>=?
            ORDER BY expected_remote_head_generation DESC
            """, [.text(workID.description)] + binding.values + [
                .blob(bytes), .int(generation), .int(current.acknowledgedHeadGeneration ?? 0)
            ])
        }
        guard let id = try candidates.first?.scalar.text.flatMap(UUID.init(uuidString:)) else { return nil }
        let snapshot = try SnapshotID(rawValue: bytes.hexString)
        let graph = try loadInboxGraph(inboxID: id, binding: binding)
        guard try conflictRepository.graphHead(graph, containsAncestor: snapshot) else {
            throw SyncV2StoreError.invalidSnapshot
        }
        return V2PendingFastForward(inboxID: id, snapshotID: snapshot, generation: generation)
    }
}

extension InboxRepository {
    func pendingSubsumptionIntent(
        intentID: UUID,
        graph: V2RemoteSnapshotGraph,
        binding: V2AccountBinding
    ) throws -> InboxRepository.PendingSubsumptionIntent {
        guard let row = try queryRows(
            IntentValidationRow.self,
            """
            SELECT \(IntentValidationRow.columns)
            FROM sync_intents
            WHERE intent_id=? AND scope_kind='bound'
              AND server_instance_id=? AND protocol_epoch=?
              AND account_id=? AND account_fence=?
            """,
            [.text(intentID.uuidString.lowercased())] + binding.values
        ).first,
            row.workID == graph.workID.description,
            let snapshotBytes = row.sourceSnapshotID,
            let generation = row.sourceGeneration,
            ["checkpoint", "latest"].contains(row.kind ?? ""),
            row.status == "pending",
            graph.expectedCurrentSnapshotID?.bytes == snapshotBytes,
            graph.expectedLocalGeneration == generation,
            try query(
                "SELECT 1 FROM sealed_commands WHERE intent_id=? LIMIT 1",
                [.text(intentID.uuidString.lowercased())]
            ).isEmpty else {
            throw SyncV2StoreError.staleCAS
        }
        return try InboxRepository.PendingSubsumptionIntent(
            intentID: intentID,
            workID: graph.workID,
            snapshotID: SnapshotID(rawValue: snapshotBytes.hexString),
            generation: generation
        )
    }

    func acknowledgeSubsumedIntent(
        _ intent: InboxRepository.PendingSubsumptionIntent,
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

    func recordSubsumption(
        _ intent: InboxRepository.PendingSubsumptionIntent,
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
            ] + binding.values + [.text(StoreValueCoding.now())]
        )
    }

    func subsumptionWasApplied(
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

    func requiredRemoteHead(_ graph: V2RemoteSnapshotGraph) throws -> V2RemoteHead {
        guard let head = graph.expectedRemoteHead,
              head.snapshotID == graph.headSnapshotID else {
            throw SyncV2StoreError.invalidSnapshot
        }
        return head
    }
}

extension InboxRepository {
    struct PendingSubsumptionIntent {
        let intentID: UUID
        let workID: WorkID
        let snapshotID: SnapshotID
        let generation: Int64
    }
}

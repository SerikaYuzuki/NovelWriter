import Foundation
import NovelCore
import NovelSyncV2

extension LocalSyncV2Store {
    func reopenNewerCheckpointIntents(
        workID: WorkID,
        afterGeneration: Int64,
        binding: V2AccountBinding
    ) throws {
        try exec(
            """
            UPDATE sync_intents SET status='pending'
            WHERE work_id=? AND kind='checkpoint' AND status='sealed'
              AND source_generation>? AND server_instance_id=?
              AND protocol_epoch=? AND account_id=? AND account_fence=?
              AND NOT EXISTS (
                SELECT 1 FROM sealed_commands c
                WHERE c.intent_id=sync_intents.intent_id
                  AND c.status IN ('sealed','sending','completed','conflictPending')
              )
            """,
            [.text(workID.description), .int(afterGeneration)] + binding.values
        )
    }

    /// A conflict-producing publish remains immutable receipt evidence, but
    /// its original checkpoint intent must never re-enter the outbox after the
    /// conflict has been resolved. Resolution intents are separate rows and
    /// are intentionally not touched here.
    func parkBlockedPublishIntent(
        workID: WorkID,
        binding: V2AccountBinding
    ) throws {
        try exec(
            """
            UPDATE sync_intents SET status='parked'
            WHERE work_id=? AND status IN ('pending','sealed')
              AND intent_id IN (
                SELECT intent_id FROM sealed_commands
                WHERE work_id=? AND intent_id IS NOT NULL
                  AND command_kind='publish' AND status='conflictPending'
                  AND server_instance_id=? AND protocol_epoch=?
                  AND account_id=? AND account_fence=?
              )
              AND server_instance_id=? AND protocol_epoch=?
              AND account_id=? AND account_fence=?
            """,
            [
                .text(workID.description), .text(workID.description)
            ] + binding.values + binding.values
        )
    }

    func activeConflictRow(
        workID: WorkID,
        binding: V2AccountBinding
    ) throws -> [SQLiteValue]? {
        guard try bindingIsActive(workID: workID, binding: binding) else {
            throw SyncV2StoreError.workNotFound
        }
        return try query(
            """
            SELECT c.conflict_id,c.current_revision,k.base_snapshot_id,
                   k.local_snapshot_id,k.remote_snapshot_id,k.source_generation,
                   k.remote_inbox_id
            FROM conflicts c JOIN conflict_candidates k
              ON k.conflict_id=c.conflict_id AND k.revision=c.current_revision
            WHERE c.work_id=? AND c.server_instance_id=?
              AND c.protocol_epoch=? AND c.account_id=? AND c.account_fence=?
              AND c.state='active'
            """,
            [.text(workID.description)] + binding.values
        ).first
    }

    func requireConflict(
        workID: WorkID,
        conflictID: UUID,
        revision: Int64,
        generation: Int64,
        local: SnapshotID,
        remote: SnapshotID,
        scope: V2LocalWorkScope
    ) throws -> V2ConflictCandidate {
        guard let active = try activeConflict(workID: workID, scope: scope),
              active.conflictID == conflictID,
              active.revision == revision,
              active.sourceGeneration == generation,
              active.localSnapshotID == local,
              active.remoteSnapshotID == remote else {
            throw SyncV2StoreError.staleConflictAction
        }
        return active
    }

    func conflictInbox(_ conflict: V2ConflictCandidate) throws -> UUID {
        guard let text = try query(
            """
            SELECT remote_inbox_id FROM conflict_candidates
            WHERE conflict_id=? AND revision=?
            """,
            [
                .text(conflict.conflictID.uuidString.lowercased()),
                .int(conflict.revision)
            ]
        ).first?[0].text,
            let inboxID = UUID(uuidString: text) else {
            throw SyncV2StoreError.inboxNotFound
        }
        return inboxID
    }

    func validateDeviceRequest(
        _ request: V2DeviceResolutionRequest,
        binding: V2AccountBinding
    ) throws {
        _ = try requireConflict(
            workID: request.workID,
            conflictID: request.conflictID,
            revision: request.revision,
            generation: request.sourceGeneration,
            local: request.localSnapshotID,
            remote: request.remoteSnapshotID,
            scope: .bound(binding)
        )
        guard let current = try scopedWorkRow(
            workID: request.workID,
            scope: .bound(binding)
        ),
            (current[2].int64.map { $0 >= request.sourceGeneration } == true) else {
            throw SyncV2StoreError.staleConflictAction
        }
    }

    func validateExactConflict(
        _ request: V2ServerResolutionRequest,
        binding: V2AccountBinding
    ) throws {
        let active = try requireConflict(
            workID: request.workID,
            conflictID: request.conflictID,
            revision: request.revision,
            generation: request.sourceGeneration,
            local: request.localSnapshotID,
            remote: request.remoteSnapshotID,
            scope: .bound(binding)
        )
        guard try conflictInbox(active) == request.inboxID,
              let current = try scopedWorkRow(
                  workID: request.workID,
                  scope: .bound(binding)
              ),
              (current[2].int64.map { $0 >= request.sourceGeneration } == true) else {
            throw SyncV2StoreError.staleConflictAction
        }
    }

    func finalizeUseServerAcknowledgement(
        record: V2SealedCommandRecord,
        remoteHead: V2RemoteHead
    ) throws {
        let command = try SealedCommand.decodeCanonical(record.canonicalRequest)
        let payload = try command.payloadDictionary()
        guard let conflictID = try UUID(uuidString: payload.uuid("conflictId")),
              let revision = (payload["conflictRevision"] as? NSNumber)?.int64Value,
              let generation = (payload["expectedLocalGeneration"] as? NSNumber)?.int64Value else {
            throw SyncV2StoreError.invalidCommand
        }
        let local = try payload.snapshot("preAdoptionSnapshotId")
        let remote = try payload.snapshot("remoteSnapshotId")
        guard let active = try activeConflict(
            workID: record.workID,
            scope: .bound(record.binding)
        ) else { throw SyncV2StoreError.staleConflictAction }
        let inboxID = try conflictInbox(active)
        let graph = try loadInboxGraph(inboxID: inboxID, binding: record.binding)
        guard graph.expectedRemoteHead == remoteHead,
              remoteHead.snapshotID == remote else {
            throw SyncV2StoreError.staleConflictAction
        }
        let request = V2ServerResolutionRequest(
            workID: record.workID,
            conflictID: conflictID,
            revision: revision,
            sourceGeneration: generation,
            localSnapshotID: local,
            remoteSnapshotID: remote,
            inboxID: inboxID,
            expectedRemoteHead: remoteHead
        )
        if record.intentID == nil {
            // Legacy/direct Store callers have no platform gate boundary. Keep
            // the original atomic behavior for that closed command shape;
            // production Application commands always carry the prepared
            // resolution Intent and remain pending for safe adoption.
            try finalizeConflictRemoteGraphTransaction(
                graph,
                request: request,
                binding: record.binding
            )
            try parkBlockedPublishIntent(workID: record.workID, binding: record.binding)
            try reopenNewerCheckpointIntents(
                workID: record.workID,
                afterGeneration: generation,
                binding: record.binding
            )
        }
    }

    func finalizeUseDeviceAcknowledgement(
        record: V2SealedCommandRecord,
        remoteHead: V2RemoteHead
    ) throws {
        let command = try SealedCommand.decodeCanonical(record.canonicalRequest)
        let payload = try command.payloadDictionary()
        let localCandidate = try payload.snapshot("localCandidateSnapshotId")
        let decision = try payload.snapshot("decisionSnapshotId")
        guard let conflictID = try UUID(uuidString: payload.uuid("conflictId")),
              let revision = (payload["conflictRevision"] as? NSNumber)?.int64Value,
              localCandidate == record.sourceSnapshotID,
              let row = try activeConflictRow(
                  workID: record.workID,
                  binding: record.binding
              ),
              row[0].text == conflictID.uuidString.lowercased(),
              row[1].int64 == revision,
              row[3].blob == localCandidate.bytes,
              let active = try activeConflict(
                  workID: record.workID,
                  scope: .bound(record.binding)
              ) else {
            throw SyncV2StoreError.staleConflictAction
        }
        let inboxID = try conflictInbox(active)
        let graph = try loadInboxGraph(inboxID: inboxID, binding: record.binding)
        _ = try validateGraph(graph)
        try validateGraphParents(graph)
        guard let expected = graph.expectedRemoteHead,
              remoteHead.snapshotID == decision,
              remoteHead.generation > expected.generation else {
            throw SyncV2StoreError.staleConflictAction
        }
        try exec(
            """
            UPDATE conflicts SET state='resolved'
            WHERE work_id=? AND conflict_id=? AND current_revision=?
              AND state='active' AND server_instance_id=? AND protocol_epoch=?
              AND account_id=? AND account_fence=?
            """,
            [
                .text(record.workID.description),
                .text(conflictID.uuidString.lowercased()), .int(revision)
            ] + record.binding.values
        )
        guard try changes() == 1 else {
            throw SyncV2StoreError.staleConflictAction
        }
        try parkBlockedPublishIntent(workID: record.workID, binding: record.binding)
        try reopenNewerCheckpointIntents(
            workID: record.workID,
            afterGeneration: active.sourceGeneration,
            binding: record.binding
        )
    }

    func finalizeKeepBothAcknowledgement(
        record: V2SealedCommandRecord,
        originalHead: V2RemoteHead,
        cloneHead: V2RemoteHead
    ) throws {
        guard let row = try query(
            """
            SELECT conflict_id,conflict_revision,source_generation,
                   remote_snapshot_id,new_work_id,new_root_snapshot_id,
                   expected_original_head_snapshot_id,
                   expected_original_head_generation,state
            FROM pending_keep_both
            WHERE source_work_id=? AND command_id=?
            """,
            [
                .text(record.workID.description),
                .text(record.commandID.uuidString.lowercased())
            ]
        ).first,
            let conflict = row[0].text,
            let revision = row[1].int64,
            let generation = row[2].int64,
            let remoteBytes = row[3].blob,
            let newWork = row[4].text,
            let root = row[5].blob,
            row[6].blob == originalHead.snapshotID.bytes,
            row[7].int64 == originalHead.generation,
            cloneHead.snapshotID.bytes == root,
            cloneHead.generation == 1,
            row[8].text == "sealed" else {
            throw SyncV2StoreError.staleConflictAction
        }
        guard let active = try activeConflict(
            workID: record.workID,
            scope: .bound(record.binding)
        ),
            active.conflictID.uuidString.lowercased() == conflict,
            active.revision == revision,
            active.sourceGeneration == generation,
            active.remoteSnapshotID.bytes == remoteBytes else {
            throw SyncV2StoreError.staleConflictAction
        }
        let inboxID = try conflictInbox(active)
        let graph = try loadInboxGraph(inboxID: inboxID, binding: record.binding)
        let request = V2ServerResolutionRequest(
            workID: record.workID,
            conflictID: active.conflictID,
            revision: active.revision,
            sourceGeneration: active.sourceGeneration,
            localSnapshotID: active.localSnapshotID,
            remoteSnapshotID: active.remoteSnapshotID,
            inboxID: inboxID,
            expectedRemoteHead: originalHead
        )
        try finalizeConflictRemoteGraphTransaction(
            graph,
            request: request,
            binding: record.binding
        )
        try reopenNewerCheckpointIntents(
            workID: record.workID,
            afterGeneration: active.sourceGeneration,
            binding: record.binding
        )
        try exec(
            """
            UPDATE works SET acknowledged_head_snapshot_id=?,
                             acknowledged_head_generation=?,sync_lane='normal'
            WHERE work_id=? AND sync_lane='keepBothReserved'
            """,
            [.blob(root), .int(1), .text(newWork)]
        )
        guard try changes() == 1 else { throw SyncV2StoreError.staleConflictAction }
        try exec(
            """
            UPDATE pending_keep_both SET state='finalized'
            WHERE source_work_id=? AND command_id=? AND state='sealed'
            """,
            [
                .text(record.workID.description),
                .text(record.commandID.uuidString.lowercased())
            ]
        )
        guard try changes() == 1 else { throw SyncV2StoreError.staleConflictAction }
        guard let clone = try query(
            "SELECT current_snapshot_id,local_generation FROM works WHERE work_id=?",
            [.text(newWork)]
        ).first,
            let current = clone[0].blob,
            let cloneGeneration = clone[1].int64 else {
            throw SyncV2StoreError.staleConflictAction
        }
        if current != root || cloneGeneration != 1 {
            try insertIntent(
                intentID: UUID(),
                workID: WorkID(uuidString: newWork),
                snapshotID: SnapshotID(rawValue: current.hexString),
                generation: cloneGeneration,
                kind: "checkpoint",
                scope: .bound(record.binding)
            )
        }
    }
}

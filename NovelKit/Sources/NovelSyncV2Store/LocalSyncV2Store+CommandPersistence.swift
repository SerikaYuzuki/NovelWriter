import Foundation
import NovelSyncV2

extension LocalSyncV2Store {
    func persistSealedCommand(
        _ command: SealedCommand,
        payload: [String: Any],
        workID: WorkID,
        scope: V2LocalWorkScope,
        binding: V2AccountBinding,
        intentID: UUID?
    ) throws {
        try inTransaction {
            try validateCommandSource(
                command,
                payload: payload,
                workID: workID,
                scope: scope,
                intentID: intentID
            )
            try insertSealedCommand(
                command,
                workID: workID,
                binding: binding,
                intentID: intentID
            )
            if let intentID {
                try sealIntent(intentID)
            }
            try linkPreparedAction(
                command,
                payload: payload,
                workID: workID,
                intentID: intentID
            )
        }
    }

    private func insertSealedCommand(
        _ command: SealedCommand,
        workID: WorkID,
        binding: V2AccountBinding,
        intentID: UUID?
    ) throws {
        try exec(
            """
            INSERT INTO sealed_commands(
              command_id,work_id,intent_id,account_id,account_fence,
              server_instance_id,protocol_epoch,command_kind,
              canonical_request,request_digest,source_snapshot_id,
              source_generation,status
            ) VALUES(?,?,?,?,?,?,?,?,?,?,?,?, 'sealed')
            """,
            [
                .text(command.commandId.uuidString.lowercased()),
                .text(workID.description),
                intentID.map { .text($0.uuidString.lowercased()) } ?? .null,
                .text(binding.accountID), .text(binding.accountFence),
                .text(binding.serverInstanceID), .int(binding.protocolEpoch),
                .text(command.commandKind), .blob(command.canonicalBytes),
                .blob(command.requestDigest.bytes),
                .blob(command.sourceSnapshotId.bytes),
                .int(command.sourceGeneration)
            ]
        )
    }

    private func sealIntent(_ intentID: UUID) throws {
        try exec(
            """
            UPDATE sync_intents SET status='sealed'
            WHERE intent_id=? AND status='pending'
            """,
            [.text(intentID.uuidString.lowercased())]
        )
        guard try changes() == 1 else { throw SyncV2StoreError.invalidCommand }
    }

    private func linkPreparedAction(
        _ command: SealedCommand,
        payload: [String: Any],
        workID: WorkID,
        intentID: UUID?
    ) throws {
        switch command.commandKind {
        case "restore":
            guard let intentID else { throw SyncV2StoreError.invalidCommand }
            try exec(
                """
                UPDATE restore_records SET command_id=?,state='sealed'
                WHERE intent_id=? AND state='prepared'
                """,
                [
                    .text(command.commandId.uuidString.lowercased()),
                    .text(intentID.uuidString.lowercased())
                ]
            )
        case "cloneWork":
            try exec(
                """
                UPDATE pending_keep_both SET command_id=?,state='sealed'
                WHERE source_work_id=? AND state='prepared'
                  AND local_candidate_snapshot_id=?
                  AND new_work_id=? AND new_root_snapshot_id=?
                """,
                [
                    .text(command.commandId.uuidString.lowercased()),
                    .text(workID.description),
                    .blob(payload.snapshot("localCandidateSnapshotId").bytes),
                    .text(payload.uuid("newWorkId")),
                    .blob(payload.snapshot("newRootSnapshotId").bytes)
                ]
            )
        default:
            return
        }
        guard try changes() == 1 else { throw SyncV2StoreError.invalidCommand }
    }

    func validateDuplicateReceipt(
        _ existing: V2ReceiptReadback,
        acknowledgement: DecodedCommandAcknowledgement
    ) throws {
        guard existing.result == acknowledgement.result,
              existing.responseStatus == acknowledgement.responseStatus,
              existing.canonicalResponse == acknowledgement.canonicalResponse,
              existing.predicates == acknowledgement.predicates,
              existing.remoteHead == acknowledgement.remoteHead,
              existing.cloneRemoteHead == acknowledgement.cloneRemoteHead else {
            throw SyncV2StoreError.invalidAcknowledgement
        }
    }

    func persistTerminalAcknowledgement(
        _ acknowledgement: DecodedCommandAcknowledgement,
        record: V2SealedCommandRecord,
        binding: V2AccountBinding
    ) throws {
        try validateAcknowledgementShape(acknowledgement, record: record)
        try validateMonotonicHead(
            workID: record.workID,
            newHead: acknowledgement.remoteHead
        )
        let successful = acknowledgement.result == .applied ||
            acknowledgement.result == .noChanges
        try applyResolutionReceipt(
            acknowledgement,
            record: record,
            successful: successful
        )
        try applyRemoteReceiptHead(
            acknowledgement,
            record: record,
            successful: successful
        )
        try persistCommandTerminalState(
            acknowledgement,
            record: record,
            binding: binding
        )
        try insertReceipt(acknowledgement, record: record, binding: binding)
        if successful {
            try acknowledgeLinkedIntent(record)
            if ["resolveDevice", "cloneWork"].contains(record.commandKind) {
                try reopenNewerCheckpointIntents(
                    workID: record.workID,
                    afterGeneration: record.sourceGeneration,
                    binding: binding
                )
            }
        }
    }

    private func validateAcknowledgementShape(
        _ acknowledgement: DecodedCommandAcknowledgement,
        record: V2SealedCommandRecord
    ) throws {
        guard record.commandKind == "cloneWork" || acknowledgement.cloneRemoteHead == nil else {
            throw SyncV2StoreError.invalidAcknowledgement
        }
        switch acknowledgement.result {
        case .retryable:
            throw SyncV2StoreError.invalidAcknowledgement
        case .parked:
            guard acknowledgement.remoteHead == nil,
                  acknowledgement.cloneRemoteHead == nil else {
                throw SyncV2StoreError.invalidAcknowledgement
            }
        case .conflictPending:
            guard record.commandKind == "publish",
                  acknowledgement.remoteHead != nil,
                  acknowledgement.cloneRemoteHead == nil else {
                throw SyncV2StoreError.invalidAcknowledgement
            }
        case .applied, .noChanges:
            if record.commandKind == "publish", acknowledgement.result == .noChanges {
                guard acknowledgement.remoteHead != nil else {
                    throw SyncV2StoreError.invalidAcknowledgement
                }
            } else if ["publish", "restore"].contains(record.commandKind) {
                let localSnapshot = try receiptLocalSnapshot(record)
                guard let remoteHead = acknowledgement.remoteHead,
                      remoteHead.snapshotID == localSnapshot else {
                    throw SyncV2StoreError.invalidAcknowledgement
                }
            }
            if record.commandKind == "cloneWork" {
                guard acknowledgement.remoteHead != nil,
                      acknowledgement.cloneRemoteHead != nil else {
                    throw SyncV2StoreError.invalidAcknowledgement
                }
            }
        }
    }

    private func applyResolutionReceipt(
        _ acknowledgement: DecodedCommandAcknowledgement,
        record: V2SealedCommandRecord,
        successful: Bool
    ) throws {
        guard successful else { return }
        switch record.commandKind {
        case "resolveServer":
            guard let remoteHead = acknowledgement.remoteHead else {
                throw SyncV2StoreError.invalidAcknowledgement
            }
            try finalizeUseServerAcknowledgement(record: record, remoteHead: remoteHead)
        case "resolveDevice":
            guard let remoteHead = acknowledgement.remoteHead else {
                throw SyncV2StoreError.invalidAcknowledgement
            }
            try finalizeUseDeviceAcknowledgement(record: record, remoteHead: remoteHead)
        case "cloneWork":
            guard let originalHead = acknowledgement.remoteHead,
                  let cloneHead = acknowledgement.cloneRemoteHead else {
                throw SyncV2StoreError.invalidAcknowledgement
            }
            try finalizeKeepBothAcknowledgement(
                record: record,
                originalHead: originalHead,
                cloneHead: cloneHead
            )
        default:
            return
        }
    }

    private func applyRemoteReceiptHead(
        _ acknowledgement: DecodedCommandAcknowledgement,
        record: V2SealedCommandRecord,
        successful: Bool
    ) throws {
        guard let head = acknowledgement.remoteHead else { return }
        try applyRemoteHead(head, workID: record.workID)
        guard successful,
              ["publish", "resolveDevice", "restore"].contains(record.commandKind) else {
            return
        }
        let localSnapshot = try receiptLocalSnapshot(record)
        try exec(
            """
            INSERT INTO snapshot_remote_equivalents(
              work_id,local_snapshot_id,remote_snapshot_id,remote_generation
            ) VALUES(?,?,?,?)
            ON CONFLICT(work_id,local_snapshot_id) DO UPDATE SET
              remote_snapshot_id=excluded.remote_snapshot_id,
              remote_generation=excluded.remote_generation
            """,
            [
                .text(record.workID.description), .blob(localSnapshot.bytes),
                .blob(head.snapshotID.bytes), .int(head.generation)
            ]
        )
    }

    private func persistCommandTerminalState(
        _ acknowledgement: DecodedCommandAcknowledgement,
        record _: V2SealedCommandRecord,
        binding: V2AccountBinding
    ) throws {
        let lifecycle: String = switch acknowledgement.result {
        case .applied, .noChanges: "completed"
        case .conflictPending: "conflictPending"
        case .parked: "parked"
        case .retryable: throw SyncV2StoreError.invalidAcknowledgement
        }
        try exec(
            """
            UPDATE sealed_commands
            SET status=?,response_status=?,canonical_response=?,receipt_verified=1
            WHERE command_id=? AND server_instance_id=? AND protocol_epoch=?
              AND account_id=? AND account_fence=?
              AND status IN ('sealed','sending','conflictPending')
            """,
            [
                .text(lifecycle), .int(Int64(acknowledgement.responseStatus)),
                .blob(acknowledgement.canonicalResponse),
                .text(acknowledgement.commandID.uuidString.lowercased())
            ] + binding.values
        )
        guard try changes() == 1 else { throw SyncV2StoreError.invalidLifecycle }
    }

    private func acknowledgeLinkedIntent(_ record: V2SealedCommandRecord) throws {
        guard ["publish", "resolveDevice", "resolveServer", "cloneWork", "restore"].contains(record.commandKind),
              let intentID = record.intentID else { return }
        guard let intent = try query(
            """
            SELECT source_snapshot_id,source_generation,status
            FROM sync_intents
            WHERE intent_id=? AND work_id=? AND server_instance_id=?
              AND protocol_epoch=? AND account_id=? AND account_fence=?
            """,
            [
                .text(intentID.uuidString.lowercased()),
                .text(record.workID.description)
            ] + record.binding.values
        ).first,
            let intentSnapshot = intent[0].blob,
            let intentGeneration = intent[1].int64,
            intent[2].text == "sealed" else {
            throw SyncV2StoreError.invalidAcknowledgement
        }
        try exec(
            """
            UPDATE sync_intents SET status='acknowledged'
            WHERE intent_id=? AND work_id=? AND source_snapshot_id=?
              AND source_generation=? AND status='sealed'
              AND server_instance_id=? AND protocol_epoch=?
              AND account_id=? AND account_fence=?
            """,
            [
                .text(intentID.uuidString.lowercased()),
                .text(record.workID.description),
                .blob(intentSnapshot), .int(intentGeneration)
            ] + record.binding.values
        )
        guard try changes() == 1 else {
            throw SyncV2StoreError.invalidAcknowledgement
        }
        if record.commandKind == "restore" {
            try finalizeRestoreRecord(record: record, intentID: intentID)
        }
    }

    private func finalizeRestoreRecord(
        record: V2SealedCommandRecord,
        intentID: UUID
    ) throws {
        try exec(
            """
            UPDATE restore_records SET state='finalized'
            WHERE command_id=? AND intent_id=? AND state='sealed'
            """,
            [
                .text(record.commandID.uuidString.lowercased()),
                .text(intentID.uuidString.lowercased())
            ]
        )
        guard try changes() == 1 else {
            throw SyncV2StoreError.invalidAcknowledgement
        }
    }
}

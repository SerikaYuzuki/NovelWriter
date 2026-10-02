import Foundation
import NovelCore
import NovelSyncV2

/// Mutations participate in the caller-owned Store transaction; no transaction is opened here.
extension OutboxRepository {
    func insertSealedCommand(
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

    func sealIntent(_ intentID: UUID) throws {
        try exec(
            """
            UPDATE sync_intents SET status='sealed'
            WHERE intent_id=? AND status='pending'
            """,
            [.text(intentID.uuidString.lowercased())]
        )
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

    func validateAcknowledgementShape(
        _ acknowledgement: DecodedCommandAcknowledgement,
        record: V2SealedCommandRecord
    ) throws {
        guard record.kind == .cloneWork || acknowledgement.cloneRemoteHead == nil else {
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
            guard record.kind == .publish,
                  acknowledgement.remoteHead != nil,
                  acknowledgement.cloneRemoteHead == nil else {
                throw SyncV2StoreError.invalidAcknowledgement
            }
        case .applied, .noChanges:
            if record.kind == .publish, acknowledgement.result == .noChanges {
                guard acknowledgement.remoteHead != nil else {
                    throw SyncV2StoreError.invalidAcknowledgement
                }
            } else if [.publish, .resolveDevice, .restore].contains(record.kind) {
                let localSnapshot = try receiptLocalSnapshot(record)
                guard let remoteHead = acknowledgement.remoteHead,
                      remoteHead.snapshotID == localSnapshot else {
                    throw SyncV2StoreError.invalidAcknowledgement
                }
            }
            if record.kind == .cloneWork {
                guard acknowledgement.remoteHead != nil,
                      acknowledgement.cloneRemoteHead != nil else {
                    throw SyncV2StoreError.invalidAcknowledgement
                }
            }
        }
    }

    func applyRemoteReceiptHead(
        _ acknowledgement: DecodedCommandAcknowledgement,
        record: V2SealedCommandRecord,
        successful: Bool
    ) throws {
        guard let head = acknowledgement.remoteHead else { return }
        try applyRemoteHead(head, workID: record.workID)
        guard successful,
              [.publish, .resolveDevice, .restore].contains(record.kind) else {
            return
        }
        let localSnapshot = try receiptLocalSnapshot(record)
        // A noChanges publish may merely prove that candidate is an ancestor.
        // The acknowledged head advances, but those bytes are not equivalent.
        guard head.snapshotID == localSnapshot else { return }
        if let existing = try query(
            "SELECT remote_snapshot_id FROM snapshot_remote_equivalents WHERE work_id=? AND local_snapshot_id=?",
            [.text(record.workID.description), .blob(localSnapshot.bytes)]
        ).first, try existing.scalar.blob != head.snapshotID.bytes {
            throw SyncV2StoreError.invalidAcknowledgement
        }
        try exec(
            """
            INSERT INTO snapshot_remote_equivalents(
              work_id,local_snapshot_id,remote_snapshot_id,remote_generation
            ) VALUES(?,?,?,?)
            ON CONFLICT(work_id,local_snapshot_id) DO UPDATE SET
              remote_generation=MAX(remote_generation,excluded.remote_generation)
            WHERE remote_snapshot_id=excluded.remote_snapshot_id
            """,
            [
                .text(record.workID.description), .blob(localSnapshot.bytes),
                .blob(head.snapshotID.bytes), .int(head.generation)
            ]
        )
    }

    func persistCommandTerminalState(
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

    func acknowledgeLinkedIntent(_ record: V2SealedCommandRecord) throws {
        guard [.publish, .resolveDevice, .resolveServer, .cloneWork, .restore].contains(record.kind),
              let intentID = record.intentID else { return }
        guard let intent = try queryRows(
            IntentSourceRow.self,
            """
            SELECT \(IntentSourceRow.columns)
            FROM sync_intents
            WHERE intent_id=? AND work_id=? AND server_instance_id=?
              AND protocol_epoch=? AND account_id=? AND account_fence=?
            """,
            [
                .text(intentID.uuidString.lowercased()),
                .text(record.workID.description)
            ] + record.binding.values
        ).first,
            let intentSnapshot = intent.sourceSnapshotID,
            let intentGeneration = intent.sourceGeneration,
            intent.status == "sealed" else {
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
        if record.kind == .restore {
            try conflictRepository.finalizeRestoreRecord(record: record, intentID: intentID)
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
            if [.resolveDevice, .cloneWork].contains(record.kind) {
                try conflictRepository.reopenNewerCheckpointIntents(
                    workID: record.workID,
                    afterGeneration: record.sourceGeneration,
                    binding: binding
                )
            }
        }
    }

    func applyResolutionReceipt(
        _ acknowledgement: DecodedCommandAcknowledgement,
        record: V2SealedCommandRecord,
        successful: Bool
    ) throws {
        guard successful else { return }
        switch record.kind {
        case .resolveServer:
            guard let remoteHead = acknowledgement.remoteHead else {
                throw SyncV2StoreError.invalidAcknowledgement
            }
            try conflictRepository.finalizeUseServerAcknowledgement(record: record, remoteHead: remoteHead)
        case .resolveDevice:
            guard let remoteHead = acknowledgement.remoteHead else {
                throw SyncV2StoreError.invalidAcknowledgement
            }
            try conflictRepository.finalizeUseDeviceAcknowledgement(record: record, remoteHead: remoteHead)
        case .cloneWork:
            guard let originalHead = acknowledgement.remoteHead,
                  let cloneHead = acknowledgement.cloneRemoteHead else {
                throw SyncV2StoreError.invalidAcknowledgement
            }
            try conflictRepository.finalizeKeepBothAcknowledgement(
                record: record,
                originalHead: originalHead,
                cloneHead: cloneHead
            )
        default:
            return
        }
    }
}

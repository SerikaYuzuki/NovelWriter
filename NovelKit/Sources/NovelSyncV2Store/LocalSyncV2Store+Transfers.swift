import Foundation
import NovelSyncV2

public extension LocalSyncV2Store {
    func persistUploadTransfer(
        _ transfer: V2UploadTransferRecord,
        scope: V2LocalWorkScope
    ) throws {
        guard case let .bound(binding) = scope,
              Self.validUploadTransferLifecycles.contains(transfer.lifecycle),
              transfer.objectID == ObjectID(data: transfer.exactBytes),
              transfer.bytesDigest == ObjectID(data: transfer.exactBytes),
              transfer.sourceGeneration > 0,
              transfer.acknowledgedOffset >= 0,
              transfer.acknowledgedOffset <= transfer.exactBytes.count,
              transfer.objectID.bytes.count == 32,
              transfer.sourceSnapshotID.bytes.count == 32,
              transfer.bytesDigest.bytes.count == 32 else {
            throw SyncV2StoreError.invalidCommand
        }
        try inTransaction {
            guard let command = try queryRows(
                CommandSourceRow.self,
                """
                SELECT \(CommandSourceRow.qualifiedColumns("c"))
                FROM sealed_commands c
                JOIN account_bindings b ON b.work_id=c.work_id
                  AND b.server_instance_id=c.server_instance_id
                  AND b.protocol_epoch=c.protocol_epoch
                  AND b.account_id=c.account_id
                  AND b.account_fence=c.account_fence
                WHERE c.command_id=? AND c.server_instance_id=?
                  AND c.protocol_epoch=? AND c.account_id=?
                  AND c.account_fence=? AND b.state='bound'
                """,
                [.text(transfer.commandID.uuidString.lowercased())] + binding.values
            ).first,
                command.workID == transfer.workID.description,
                command.sourceSnapshotID == transfer.sourceSnapshotID.bytes,
                command.sourceGeneration == transfer.sourceGeneration else {
                throw SyncV2StoreError.invalidCommand
            }
            try exec(
                """
                INSERT INTO upload_transfers(
                  transfer_id,command_id,work_id,object_id,source_snapshot_id,
                  source_generation,upload_id,capability,exact_bytes,bytes_digest,
                  acknowledged_offset,expires_at,lifecycle,server_instance_id,
                  protocol_epoch,account_id,account_fence
                ) VALUES(?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)
                ON CONFLICT(command_id) DO UPDATE SET
                  transfer_id=excluded.transfer_id,
                  work_id=excluded.work_id,
                  object_id=excluded.object_id,
                  source_snapshot_id=excluded.source_snapshot_id,
                  source_generation=excluded.source_generation,
                  upload_id=excluded.upload_id,
                  capability=excluded.capability,
                  exact_bytes=excluded.exact_bytes,
                  bytes_digest=excluded.bytes_digest,
                  expires_at=excluded.expires_at,
                  lifecycle=CASE
                    WHEN upload_transfers.lifecycle IN ('acknowledged','quarantined','parked') THEN upload_transfers.lifecycle
                    ELSE excluded.lifecycle END
                WHERE upload_transfers.transfer_id=excluded.transfer_id
                  AND upload_transfers.work_id=excluded.work_id
                  AND upload_transfers.object_id=excluded.object_id
                  AND upload_transfers.source_snapshot_id=excluded.source_snapshot_id
                  AND upload_transfers.source_generation=excluded.source_generation
                  AND upload_transfers.upload_id=excluded.upload_id
                  AND upload_transfers.capability=excluded.capability
                  AND upload_transfers.exact_bytes=excluded.exact_bytes
                  AND upload_transfers.bytes_digest=excluded.bytes_digest
                """,
                [
                    .text(transfer.transferID.uuidString.lowercased()),
                    .text(transfer.commandID.uuidString.lowercased()),
                    .text(transfer.workID.description),
                    .blob(transfer.objectID.bytes),
                    .blob(transfer.sourceSnapshotID.bytes),
                    .int(transfer.sourceGeneration),
                    .text(transfer.uploadID.uuidString.lowercased()),
                    .text(transfer.capability),
                    .blob(transfer.exactBytes),
                    .blob(transfer.bytesDigest.bytes),
                    .int(Int64(transfer.acknowledgedOffset)),
                    .text(Self.iso8601(transfer.expiresAt)),
                    .text(transfer.lifecycle),
                    .text(binding.serverInstanceID),
                    .int(binding.protocolEpoch),
                    .text(binding.accountID),
                    .text(binding.accountFence)
                ]
            )
            guard try changes() == 1 else { throw SyncV2StoreError.invalidCommand }
        }
    }

    func uploadTransfer(
        commandID: UUID,
        scope: V2LocalWorkScope
    ) throws -> V2UploadTransferRecord? {
        guard case let .bound(binding) = scope else { throw SyncV2StoreError.accountMismatch }
        guard try commandBindingIsActive(commandID: commandID, binding: binding) else {
            throw SyncV2StoreError.accountMismatch
        }
        let row = try queryRows(
            UploadTransferRow.self,
            """
            SELECT \(UploadTransferRow.columns)
            FROM upload_transfers
            WHERE command_id=? AND server_instance_id=? AND protocol_epoch=?
              AND account_id=? AND account_fence=?
            """,
            [.text(commandID.uuidString.lowercased())] + binding.values
        ).first
        guard let row else { return nil }
        let work: WorkID
        do {
            guard let rawWork = row.workID else { throw SyncV2StoreError.invalidCommand }
            work = try WorkID(uuidString: rawWork)
        } catch {
            throw SyncV2StoreError.invalidCommand
        }
        guard let transfer = row.transferID.flatMap(UUID.init(uuidString:)),
              let command = row.commandID.flatMap(UUID.init(uuidString:)),
              let objectBytes = row.objectID,
              let snapshotBytes = row.sourceSnapshotID,
              let generation = row.sourceGeneration,
              let upload = row.uploadID.flatMap(UUID.init(uuidString:)),
              let capability = row.capability,
              let exactBytes = row.exactBytes,
              let digestBytes = row.bytesDigest,
              let offset = row.acknowledgedOffset,
              let expiresRaw = row.expiresAt,
              let expiresAt = SyncV2Timestamp.parse(expiresRaw),
              let lifecycle = row.lifecycle else { throw SyncV2StoreError.invalidCommand }
        guard Self.validUploadTransferLifecycles.contains(lifecycle),
              objectBytes.count == 32,
              snapshotBytes.count == 32,
              digestBytes.count == 32,
              generation > 0,
              offset >= 0,
              offset <= Int64(exactBytes.count),
              ObjectID(data: exactBytes).bytes == digestBytes,
              ObjectID(data: exactBytes).bytes == objectBytes else {
            throw SyncV2StoreError.invalidCommand
        }
        guard let commandRow = try queryRows(
            CommandSourceRow.self,
            """
            SELECT \(CommandSourceRow.columns)
            FROM sealed_commands WHERE command_id=?
            """,
            [.text(command.uuidString.lowercased())]
        ).first,
            commandRow.workID == work.description,
            commandRow.sourceSnapshotID == snapshotBytes,
            commandRow.sourceGeneration == generation else {
            throw SyncV2StoreError.invalidCommand
        }
        let sourceSnapshotID: SnapshotID
        let objectID: ObjectID
        let bytesDigest: ObjectID
        do { sourceSnapshotID = try SnapshotID(rawValue: snapshotBytes.hexString) }
        catch { throw SyncV2StoreError.invalidCommand }
        do {
            objectID = try ObjectID(rawValue: objectBytes.hexString)
            bytesDigest = try ObjectID(rawValue: digestBytes.hexString)
        } catch { throw SyncV2StoreError.invalidCommand }
        return V2UploadTransferRecord(
            transferID: transfer,
            commandID: command,
            workID: work,
            objectID: objectID,
            sourceSnapshotID: sourceSnapshotID,
            sourceGeneration: generation,
            uploadID: upload,
            capability: capability,
            exactBytes: exactBytes,
            bytesDigest: bytesDigest,
            acknowledgedOffset: Int(offset),
            expiresAt: expiresAt,
            lifecycle: lifecycle
        )
    }

    func acknowledgeUploadTransfer(
        transferID: UUID,
        byteCount: Int,
        scope: V2LocalWorkScope
    ) throws {
        guard case let .bound(binding) = scope else { throw SyncV2StoreError.accountMismatch }
        guard try query(
            """
            SELECT 1 FROM upload_transfers u
            JOIN sealed_commands c ON c.command_id=u.command_id
              AND c.work_id=u.work_id
              AND c.source_snapshot_id=u.source_snapshot_id
              AND c.source_generation=u.source_generation
            JOIN account_bindings b ON b.work_id=c.work_id
              AND b.server_instance_id=c.server_instance_id
              AND b.protocol_epoch=c.protocol_epoch
              AND b.account_id=c.account_id
              AND b.account_fence=c.account_fence
            WHERE u.transfer_id=? AND u.server_instance_id=?
              AND u.protocol_epoch=? AND u.account_id=? AND u.account_fence=?
              AND b.state='bound'
            """,
            [.text(transferID.uuidString.lowercased())] + binding.values
        ).isEmpty == false else {
            throw SyncV2StoreError.accountMismatch
        }
        guard let row = try queryRows(
            UploadProgressRow.self,
            """
            SELECT \(UploadProgressRow.columns)
            FROM upload_transfers
            WHERE transfer_id=? AND server_instance_id=? AND protocol_epoch=?
              AND account_id=? AND account_fence=?
            """,
            [.text(transferID.uuidString.lowercased())] + binding.values
        ).first,
            let exactBytes = row.exactBytes,
            let currentOffset = row.acknowledgedOffset,
            let lifecycle = row.lifecycle,
            Self.validUploadTransferLifecycles.contains(lifecycle),
            lifecycle == "prepared" || lifecycle == "acknowledged",
            byteCount >= 0,
            byteCount <= exactBytes.count,
            currentOffset >= 0,
            currentOffset <= Int64(exactBytes.count),
            byteCount >= currentOffset else { throw SyncV2StoreError.invalidCommand }
        try exec(
            """
            UPDATE upload_transfers
            SET acknowledged_offset=?, lifecycle='acknowledged'
            WHERE transfer_id=? AND server_instance_id=? AND protocol_epoch=?
              AND account_id=? AND account_fence=?
              AND acknowledged_offset<=? AND lifecycle IN ('prepared','acknowledged')
            """,
            [
                .int(Int64(byteCount)),
                .text(transferID.uuidString.lowercased())
            ] + binding.values + [.int(Int64(byteCount))]
        )
        guard try changes() == 1 else { throw SyncV2StoreError.invalidAcknowledgement }
    }
}

private extension LocalSyncV2Store {
    static let validUploadTransferLifecycles: Set<String> = [
        "prepared", "sending", "acknowledged", "quarantined", "parked"
    ]
}

public extension LocalSyncV2Store {
    func quarantineUpload(transferID: UUID, workID: WorkID, reason: String, scope: V2LocalWorkScope) throws {
        guard case let .bound(binding) = scope else { throw SyncV2StoreError.accountMismatch }
        try inTransaction {
            guard try scopedWorkRow(workID: workID, scope: scope) != nil else { throw SyncV2StoreError.accountMismatch }
            let id = transferID.uuidString.lowercased()
            try exec("""
            UPDATE upload_transfers SET lifecycle='quarantined'
            WHERE transfer_id=? AND work_id=? AND server_instance_id=? AND protocol_epoch=?
              AND account_id=? AND account_fence=? AND lifecycle IN ('prepared','sending','quarantined')
            """, [.text(id), .text(workID.description)] + binding.values)
            guard try changes() == 1 else { throw SyncV2StoreError.invalidLifecycle }
            try exec("""
            INSERT INTO quarantine_records(quarantine_id,work_id,account_id,reason,evidence_bytes,created_at)
            VALUES(?,?,?,?,?,?) ON CONFLICT(quarantine_id) DO UPDATE SET reason=excluded.reason
            """, [.text(id), .text(workID.description), .text(binding.accountID), .text("upload:" + reason),
                  .blob(Data()), .text(Self.iso8601(Date()))])
        }
    }

    func quarantinedUploadReason(workID: WorkID, scope: V2LocalWorkScope) throws -> String? {
        guard case let .bound(binding) = scope,
              try scopedWorkRow(workID: workID, scope: scope) != nil else { throw SyncV2StoreError.accountMismatch }
        let reason = try query("""
        SELECT q.reason FROM upload_transfers u JOIN quarantine_records q ON q.quarantine_id=u.transfer_id
        WHERE u.work_id=? AND u.server_instance_id=? AND u.protocol_epoch=?
          AND u.account_id=? AND u.account_fence=? AND u.lifecycle='quarantined'
          AND q.reason LIKE 'upload:%' ORDER BY q.created_at LIMIT 1
        """, [.text(workID.description)] + binding.values).first?.scalar.text
        return reason.map { String($0.dropFirst("upload:".count)) }
    }
}

extension LocalSyncV2Store {
    func retryQuarantinedUploads(workID: WorkID, scope: V2LocalWorkScope) throws {
        guard case let .bound(binding) = scope else { throw SyncV2StoreError.accountMismatch }
        let rows = try query("""
        SELECT u.transfer_id FROM upload_transfers u JOIN quarantine_records q ON q.quarantine_id=u.transfer_id
        WHERE u.work_id=? AND u.server_instance_id=? AND u.protocol_epoch=? AND u.account_id=? AND u.account_fence=?
          AND u.lifecycle='quarantined' AND q.reason LIKE 'upload:%'
        """, [.text(workID.description)] + binding.values)
        for row in rows {
            guard let id = try row.scalar.text else { throw SyncV2StoreError.invalidLifecycle }
            try exec("UPDATE upload_transfers SET lifecycle='prepared' WHERE transfer_id=?", [.text(id)])
            try exec("DELETE FROM quarantine_records WHERE quarantine_id=?", [.text(id)])
        }
    }
}

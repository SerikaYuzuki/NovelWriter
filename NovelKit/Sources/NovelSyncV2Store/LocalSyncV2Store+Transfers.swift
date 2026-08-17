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
            guard let command = try query(
                """
                SELECT c.work_id,c.source_snapshot_id,c.source_generation
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
                command[0].text == transfer.workID.description,
                command[1].blob == transfer.sourceSnapshotID.bytes,
                command[2].int64 == transfer.sourceGeneration else {
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
                    WHEN upload_transfers.lifecycle='acknowledged' THEN upload_transfers.lifecycle
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
        let row = try query(
            """
            SELECT transfer_id,command_id,work_id,object_id,source_snapshot_id,
                   source_generation,upload_id,capability,exact_bytes,bytes_digest,
                   acknowledged_offset,expires_at,lifecycle
            FROM upload_transfers
            WHERE command_id=? AND server_instance_id=? AND protocol_epoch=?
              AND account_id=? AND account_fence=?
            """,
            [.text(commandID.uuidString.lowercased())] + binding.values
        ).first
        guard let row else { return nil }
        let work: WorkID
        do {
            guard let rawWork = row[2].text else { throw SyncV2StoreError.invalidCommand }
            work = try WorkID(uuidString: rawWork)
        } catch {
            throw SyncV2StoreError.invalidCommand
        }
        guard let transfer = row[0].text.flatMap(UUID.init(uuidString:)),
              let command = row[1].text.flatMap(UUID.init(uuidString:)),
              let objectBytes = row[3].blob,
              let snapshotBytes = row[4].blob,
              let generation = row[5].int64,
              let upload = row[6].text.flatMap(UUID.init(uuidString:)),
              let capability = row[7].text,
              let exactBytes = row[8].blob,
              let digestBytes = row[9].blob,
              let offset = row[10].int64,
              let expiresRaw = row[11].text,
              let expiresAt = ISO8601DateFormatter().date(from: expiresRaw),
              let lifecycle = row[12].text else { throw SyncV2StoreError.invalidCommand }
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
        guard let commandRow = try query(
            """
            SELECT work_id,source_snapshot_id,source_generation
            FROM sealed_commands WHERE command_id=?
            """,
            [.text(command.uuidString.lowercased())]
        ).first,
            commandRow[0].text == work.description,
            commandRow[1].blob == snapshotBytes,
            commandRow[2].int64 == generation else {
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
        guard let row = try query(
            """
            SELECT exact_bytes,acknowledged_offset,lifecycle
            FROM upload_transfers
            WHERE transfer_id=? AND server_instance_id=? AND protocol_epoch=?
              AND account_id=? AND account_fence=?
            """,
            [.text(transferID.uuidString.lowercased())] + binding.values
        ).first,
            let exactBytes = row[0].blob,
            let currentOffset = row[1].int64,
            let lifecycle = row[2].text,
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

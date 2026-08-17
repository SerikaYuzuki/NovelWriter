import Foundation
import NovelSyncV2

public extension LocalSyncV2Store {
    func persistUploadTransfer(
        _ transfer: V2UploadTransferRecord,
        scope: V2LocalWorkScope
    ) throws {
        guard case let .bound(binding) = scope,
              transfer.bytesDigest == ObjectID(data: transfer.exactBytes) else {
            throw SyncV2StoreError.invalidCommand
        }
        try inTransaction {
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
        }
    }

    func uploadTransfer(
        commandID: UUID,
        scope: V2LocalWorkScope
    ) throws -> V2UploadTransferRecord? {
        guard case let .bound(binding) = scope else { throw SyncV2StoreError.accountMismatch }
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
        guard ObjectID(data: exactBytes) == ObjectID(data: digestBytes) else {
            throw SyncV2StoreError.invalidCommand
        }
        let sourceSnapshotID: SnapshotID
        do { sourceSnapshotID = try SnapshotID(rawValue: snapshotBytes.hexString) }
        catch { throw SyncV2StoreError.invalidCommand }
        return V2UploadTransferRecord(
            transferID: transfer,
            commandID: command,
            workID: work,
            objectID: ObjectID(data: objectBytes),
            sourceSnapshotID: sourceSnapshotID,
            sourceGeneration: generation,
            uploadID: upload,
            capability: capability,
            exactBytes: exactBytes,
            bytesDigest: ObjectID(data: digestBytes),
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
        guard byteCount >= 0 else { throw SyncV2StoreError.invalidCommand }
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

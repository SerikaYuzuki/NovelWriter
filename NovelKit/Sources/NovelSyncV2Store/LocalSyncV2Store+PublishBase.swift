import Foundation
import NovelSyncV2

extension LocalSyncV2Store {
    /// A downloaded descendant is not the base of edits made before adoption.
    /// Use a verified head on this candidate's actual ancestry, without moving
    /// the monotonically acknowledged server head backwards.
    func publishBaseHead(workID: WorkID, snapshotID: SnapshotID) throws -> V2RemoteHead? {
        let acknowledged = try acknowledgedHead(workID: workID)
        let ancestry = """
        WITH RECURSIVE ancestry(snapshot_id) AS (
          SELECT ? UNION
          SELECT p.parent_snapshot_id FROM snapshot_parents p
          JOIN ancestry a ON a.snapshot_id=p.snapshot_id WHERE p.work_id=?
        )
        """
        let prefix: [SQLiteValue] = [.blob(snapshotID.bytes), .text(workID.description)]
        if let acknowledged,
           try !query(ancestry + "SELECT 1 FROM ancestry WHERE snapshot_id=?",
                      prefix + [.blob(acknowledged.snapshotID.bytes)]).isEmpty {
            return acknowledged
        }
        let binding = try activeBinding(workID: workID)
        let rows = try query(ancestry + """
            SELECT r.remote_head_snapshot_id,r.remote_head_generation
            FROM remote_receipts r
            JOIN sealed_commands c ON c.account_id=r.account_id AND c.command_id=r.command_id
            JOIN ancestry a ON a.snapshot_id=r.remote_head_snapshot_id
            WHERE r.work_id=? AND c.server_instance_id=? AND c.protocol_epoch=?
              AND c.account_id=? AND c.account_fence=? AND c.receipt_verified=1
            UNION
            SELECT i.snapshot_id,i.expected_remote_head_generation
            FROM inbox_batches i JOIN ancestry a ON a.snapshot_id=i.snapshot_id
            WHERE i.work_id=? AND i.server_instance_id=? AND i.protocol_epoch=?
              AND i.account_id=? AND i.account_fence=? AND i.state IN ('verified','adopted')
            ORDER BY 2 DESC LIMIT 1
            """, prefix + [.text(workID.description)] + binding.values +
                [.text(workID.description)] + binding.values)
        guard let row = rows.first,
              let head = try Self.head(snapshot: row[0].blob, generation: row[1].int64) else {
            if acknowledged == nil {
                return nil
            }
            throw SyncV2StoreError.invalidSnapshot
        }
        return head
    }
}

public extension LocalSyncV2Store {
    /// Called only for the server's exact pre-commit lineage rejection. Keep
    /// old command bytes and its intent as evidence; checkpoint data is retained.
    func replanRejectedPublish(commandID: UUID, scope: V2LocalWorkScope) throws {
        guard case let .bound(binding) = scope else { throw SyncV2StoreError.accountMismatch }
        try inTransaction {
            guard let record = try sealedRecord(commandID: commandID, binding: binding),
                  record.commandKind == "publish", record.lifecycle == .sending,
                  let intentID = record.intentID,
                  try receiptReadback(commandID: commandID, scope: scope) == nil,
                  let row = try scopedWorkRow(workID: record.workID, scope: scope),
                  let current = row[3].blob, let generation = row[2].int64 else {
                throw SyncV2StoreError.invalidCommand
            }
            let command = try SealedCommand.decodeCanonical(record.canonicalRequest)
            let payload = try command.payloadDictionary()
            guard try payload.remoteHead("expectedRemoteHead") !=
                publishBaseHead(workID: record.workID, snapshotID: record.sourceSnapshotID) else {
                throw SyncV2StoreError.invalidCommand
            }
            try transitionCommand(commandID: commandID, scope: scope, from: ["sending"], to: "quarantined")
            try exec("UPDATE sync_intents SET status='quarantined' WHERE intent_id=? AND status='sealed'",
                     [.text(intentID.uuidString.lowercased())])
            guard try changes() == 1 else { throw SyncV2StoreError.invalidCommand }
            _ = try upsertCheckpointIntent(workID: record.workID,
                                           snapshotID: SnapshotID(rawValue: current.hexString),
                                           generation: generation, scope: scope)
        }
    }
}

import Foundation
import NovelSyncV2

extension LocalSyncV2Store {
    func recordCommandFailureReason(commandID: UUID, reason: String) throws {
        let id = commandID.uuidString.lowercased()
        try exec("""
        INSERT INTO quarantine_records(quarantine_id,work_id,account_id,reason,evidence_bytes,created_at)
        SELECT command_id,work_id,account_id,?,X'',? FROM sealed_commands WHERE command_id=?
        ON CONFLICT(quarantine_id) DO UPDATE SET reason=excluded.reason
        """, [.text("command:" + reason), .text(Self.iso8601(Date())), .text(id)])
    }
}

public extension LocalSyncV2Store {
    func quarantinedCommandReason(workID: WorkID, scope: V2LocalWorkScope) throws -> String? {
        guard case let .bound(binding) = scope,
              try scopedWorkRow(workID: workID, scope: scope) != nil else { throw SyncV2StoreError.accountMismatch }
        let reason = try query("""
        SELECT q.reason FROM sealed_commands c JOIN quarantine_records q ON q.quarantine_id=c.command_id
        WHERE c.work_id=? AND c.server_instance_id=? AND c.protocol_epoch=?
          AND c.account_id=? AND c.account_fence=? AND c.status='quarantined'
          AND q.reason LIKE 'command:%' ORDER BY q.created_at LIMIT 1
        """, [.text(workID.description)] + binding.values).first?[0].text
        return reason.map { String($0.dropFirst("command:".count)) }
    }
}

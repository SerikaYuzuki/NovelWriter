import Foundation
import NovelSyncV2

public extension LocalSyncV2Store {
    /// Upgrade recovery runs before the normal wake scans its pending lanes.
    /// No intent, source generation, command ID, digest or request is replaced.
    func retryUnacknowledgedCommands(scope: V2LocalWorkScope) throws {
        guard case .bound = scope else { throw SyncV2StoreError.accountMismatch }
        try inTransaction {
            for work in try listWorks(scope: scope) {
                try retryUnacknowledgedCommandsTransaction(workID: work.workID, scope: scope, legacyOnly: true)
            }
        }
    }

    func retryUnacknowledgedCommands(workID: WorkID, scope: V2LocalWorkScope) throws {
        try inTransaction { try retryUnacknowledgedCommandsTransaction(workID: workID, scope: scope, legacyOnly: true) }
    }
}

extension LocalSyncV2Store {
    func retryUnacknowledgedCommandsTransaction(workID: WorkID, scope: V2LocalWorkScope, legacyOnly: Bool = false) throws {
        guard case let .bound(binding) = scope,
              let work = try scopedWorkRow(workID: workID, scope: scope) else {
            throw SyncV2StoreError.accountMismatch
        }
        guard work.syncLane == V2SyncLane.normal.rawValue,
              try workDeletion(workID: workID) == nil else { return }
        // Automatic recovery also requires an unconsumed upgrade candidate.
        // Manual sync may retry a new response-less unexpected failure.
        // A response/receipt, existing prepare transfer or any other reason
        // keeps automatic recovery blocked. Explicit sync has separate manual retries.
        let rows = try query("""
        SELECT c.command_id FROM sealed_commands c
        JOIN quarantine_records q ON q.quarantine_id=c.command_id
        WHERE c.work_id=? AND c.server_instance_id=? AND c.protocol_epoch=?
          AND c.account_id=? AND c.account_fence=? AND c.status='quarantined'
          AND c.command_kind IN ('createWork','prepareObject','finalizeObject','registerSnapshot',
                                'publish','resolveDevice','resolveServer','cloneWork','restore')
          AND (?=0 OR EXISTS (SELECT 1 FROM legacy_command_recovery l
                              WHERE l.command_id=c.command_id AND l.consumed=0))
          AND q.reason='command:unexpected' AND length(q.evidence_bytes)=0
          AND c.canonical_response IS NULL AND c.response_status IS NULL AND c.receipt_verified=0
          AND NOT EXISTS (SELECT 1 FROM remote_receipts r WHERE r.command_id=c.command_id)
          AND NOT EXISTS (SELECT 1 FROM upload_transfers u WHERE u.command_id=c.command_id)
        """, [.text(workID.description)] + binding.values + [.int(legacyOnly ? 1 : 0)])
        for row in rows {
            guard let raw = try row.scalar.text, let id = UUID(uuidString: raw) else {
                throw SyncV2StoreError.invalidCommand
            }
            try transitionCommand(commandID: id, scope: scope, from: ["quarantined"], to: "sealed")
        }
    }
}

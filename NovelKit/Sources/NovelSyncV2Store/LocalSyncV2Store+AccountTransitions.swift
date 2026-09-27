import Foundation
import NovelCore
import NovelSyncV2

public extension LocalSyncV2Store {
    func rebindWork(
        workID: WorkID,
        from old: V2AccountBinding,
        to new: V2AccountBinding
    ) throws {
        guard old != new else { return }
        try inTransaction {
            try retireBinding(workID: workID, from: old, to: new)
        }
    }

    /// Atomically transitions every active Work in the supplied source scope.
    /// A nil source is the cold-launch reconciliation case: all active lanes
    /// are classified against the attested destination. A non-nil source is
    /// exact; if the database has active rows but none match it, the operation
    /// fails rather than guessing another binding to park.
    func transitionAccountScopes(
        from old: V2AccountBinding?,
        to new: V2AccountBinding?
    ) throws {
        try inTransaction {
            let activeRows = try activeBindingRows()
            let selectedRows = try selectedTransitionRows(
                activeRows: activeRows,
                from: old,
                to: new
            )
            for row in selectedRows {
                let source = try binding(from: row)
                guard let workText = row[0].text,
                      let workUUID = UUID(uuidString: workText) else {
                    throw SyncV2StoreError.invalidLifecycle
                }
                let destination = new.flatMap {
                    $0.accountID == source.accountID &&
                        $0.serverInstanceID == source.serverInstanceID &&
                        $0.protocolEpoch == source.protocolEpoch ? $0 : nil
                }
                if destination != source {
                    try retireBinding(
                        workID: WorkID(workUUID),
                        from: source,
                        to: destination
                    )
                }
            }
            if let new {
                try reactivateMatchingParkedBindings(to: new)
            }
        }
    }

    private func activeBindingRows() throws -> [[SQLiteValue]] {
        try query(
            """
            SELECT work_id,server_instance_id,protocol_epoch,account_id,account_fence
            FROM account_bindings WHERE state='bound' ORDER BY work_id
            """
        )
    }

    private func selectedTransitionRows(
        activeRows: [[SQLiteValue]],
        from old: V2AccountBinding?,
        to new: V2AccountBinding?
    ) throws -> [[SQLiteValue]] {
        guard let old else { return activeRows }
        let selected = activeRows.filter {
            $0[1].text == old.serverInstanceID &&
                $0[2].int64 == old.protocolEpoch &&
                $0[3].text == old.accountID &&
                $0[4].text == old.accountFence
        }
        guard selected.isEmpty else {
            guard selected.count == activeRows.count else {
                throw SyncV2StoreError.accountMismatch
            }
            return selected
        }
        // A retried transition may observe the destination binding after the
        // first transaction committed. Treat that exact durable end state as
        // idempotent; a mixed scope remains a hard mismatch.
        if let new,
           activeRows.allSatisfy({
               $0[1].text == new.serverInstanceID &&
                   $0[2].int64 == new.protocolEpoch &&
                   $0[3].text == new.accountID &&
                   $0[4].text == new.accountFence
           }) {
            return []
        }
        guard activeRows.isEmpty else { throw SyncV2StoreError.accountMismatch }
        return []
    }

    private func binding(from row: [SQLiteValue]) throws -> V2AccountBinding {
        guard let server = row[1].text,
              let epoch = row[2].int64,
              let account = row[3].text,
              let fence = row[4].text else {
            throw SyncV2StoreError.invalidLifecycle
        }
        return V2AccountBinding(
            accountID: account,
            accountFence: fence,
            serverInstanceID: server,
            protocolEpoch: epoch
        )
    }

    private func reactivateMatchingParkedBindings(
        to new: V2AccountBinding
    ) throws {
        let parkedRows = try query(
            """
            SELECT p.work_id,p.server_instance_id,p.protocol_epoch,
                   p.account_id,p.account_fence
            FROM account_bindings p
            WHERE p.state='parked' AND p.account_id=?
              AND NOT EXISTS (
                SELECT 1 FROM account_bindings active
                WHERE active.work_id=p.work_id AND active.state='bound'
              )
            ORDER BY p.work_id
            """,
            [.text(new.accountID)]
        )
        for row in parkedRows {
            let source = try binding(from: row)
            guard source.serverInstanceID == new.serverInstanceID,
                  source.protocolEpoch == new.protocolEpoch,
                  let workText = row[0].text,
                  let workUUID = UUID(uuidString: workText) else {
                // AccountID is namespaced by server and protocol epoch. A
                // collision in another namespace remains explicitly parked.
                continue
            }
            try reactivateParkedBinding(
                workID: WorkID(workUUID),
                from: source,
                to: new
            )
        }
    }

    /// Retires an account binding without creating a destination binding.
    /// The Work remains editable through the local parked scope, while all
    /// old-account remote lanes are parked atomically.
    func parkWork(
        workID: WorkID,
        binding: V2AccountBinding
    ) throws {
        try inTransaction {
            try retireBinding(workID: workID, from: binding, to: nil)
        }
    }

    private func retireBinding(
        workID: WorkID,
        from old: V2AccountBinding,
        to new: V2AccountBinding?
    ) throws {
        guard try bindingIsActive(workID: workID, binding: old) else {
            throw SyncV2StoreError.accountMismatch
        }
        let disposition = if let new, new.accountID == old.accountID,
                             new.serverInstanceID == old.serverInstanceID,
                             new.protocolEpoch == old.protocolEpoch {
            "quarantined"
        } else {
            "parked"
        }
        try retireRestoreRecords(
            workID: workID,
            binding: old,
            disposition: disposition
        )
        try exec(
            """
            UPDATE account_bindings SET state=?
            WHERE work_id=? AND server_instance_id=? AND protocol_epoch=?
              AND account_id=? AND account_fence=? AND state='bound'
            """,
            [.text(disposition), .text(workID.description)] + old.values
        )
        guard try changes() == 1 else { throw SyncV2StoreError.accountMismatch }
        try retireRemoteLanes(
            workID: workID,
            binding: old,
            disposition: disposition
        )
        if let new, disposition == "quarantined" {
            try installQuarantinedBinding(workID: workID, from: old, to: new)
        }
    }

    private func retireRemoteLanes(
        workID: WorkID,
        binding old: V2AccountBinding,
        disposition: String
    ) throws {
        try exec(
            """
            UPDATE sealed_commands SET status=?
            WHERE work_id=? AND server_instance_id=? AND protocol_epoch=?
              AND account_id=? AND account_fence=?
              AND status IN ('sealed','sending','conflictPending')
            """,
            [.text(disposition), .text(workID.description)] + old.values
        )
        try exec(
            """
            UPDATE sync_intents SET status=?
            WHERE work_id=? AND scope_kind='bound'
              AND server_instance_id=? AND protocol_epoch=?
              AND account_id=? AND account_fence=?
              AND status IN ('pending','sealed')
            """,
            [.text(disposition), .text(workID.description)] + old.values
        )
        try exec(
            """
            UPDATE inbox_batches SET state='rejected',rejection_code=?
            WHERE work_id=? AND server_instance_id=? AND protocol_epoch=?
              AND account_id=? AND account_fence=?
              AND state IN ('staged','verified')
            """,
            [.text(disposition), .text(workID.description)] + old.values
        )
        try exec(
            """
            UPDATE conflicts SET state=?
            WHERE work_id=? AND server_instance_id=? AND protocol_epoch=?
              AND account_id=? AND account_fence=? AND state='active'
            """,
            [.text(disposition), .text(workID.description)] + old.values
        )
        try exec(
            """
            UPDATE pending_keep_both SET state=?
            WHERE source_work_id=? AND conflict_id IN (
              SELECT conflict_id FROM conflicts
              WHERE work_id=? AND server_instance_id=? AND protocol_epoch=?
                AND account_id=? AND account_fence=? AND state=?
            ) AND state IN ('prepared','sealed')
            """,
            [
                .text(disposition), .text(workID.description),
                .text(workID.description)
            ] + old.values + [.text(disposition)]
        )
        try retireScopeCaches(workID: workID)
        try exec(
            """
            UPDATE upload_transfers SET lifecycle=?
            WHERE work_id=? AND server_instance_id=? AND protocol_epoch=?
              AND account_id=? AND account_fence=?
              AND lifecycle IN ('prepared','sending','acknowledged')
            """,
            [.text(disposition), .text(workID.description)] + old.values
        )
    }

    private func installQuarantinedBinding(
        workID: WorkID,
        from old: V2AccountBinding,
        to new: V2AccountBinding
    ) throws {
        try insertBinding(workID: workID, binding: new)
        if let row = try query(
            "SELECT current_snapshot_id,local_generation FROM works WHERE work_id=?",
            [.text(workID.description)]
        ).first,
            let snapshotBytes = row[0].blob,
            let generation = row[1].int64,
            generation > 0 {
            try _ = upsertCheckpointIntent(
                workID: workID,
                snapshotID: SnapshotID(rawValue: snapshotBytes.hexString),
                generation: generation,
                scope: .bound(new)
            )
        }
        try exec(
            """
            INSERT INTO binding_transitions(
              transition_id,work_id,old_server_instance_id,old_protocol_epoch,
              old_account_id,old_account_fence,disposition,
              new_server_instance_id,new_protocol_epoch,new_account_id,
              new_account_fence,created_at
            ) VALUES(?,?,?,?,?,?,?,?,?,?,?,?)
            """,
            [.text(UUID().uuidString.lowercased()), .text(workID.description)] +
                old.values + [.text("quarantined")] + new.values + [.text(Self.now())]
        )
    }

    private func reactivateParkedBinding(
        workID: WorkID,
        from old: V2AccountBinding,
        to new: V2AccountBinding
    ) throws {
        guard old.serverInstanceID == new.serverInstanceID,
              old.protocolEpoch == new.protocolEpoch else {
            throw SyncV2StoreError.accountMismatch
        }
        guard try query(
            """
            SELECT 1 FROM account_bindings
            WHERE work_id=? AND server_instance_id=? AND protocol_epoch=?
              AND account_id=? AND account_fence=? AND state='parked'
            """,
            [.text(workID.description)] + old.values
        ).isEmpty == false else {
            throw SyncV2StoreError.accountMismatch
        }
        let exact = old == new
        try exec(
            """
            UPDATE account_bindings SET state=?
            WHERE work_id=? AND server_instance_id=? AND protocol_epoch=?
              AND account_id=? AND account_fence=? AND state='parked'
            """,
            [.text(exact ? "bound" : "quarantined"), .text(workID.description)] + old.values
        )
        guard try changes() == 1 else { throw SyncV2StoreError.accountMismatch }
        if !exact {
            try insertBinding(workID: workID, binding: new)
        }
        try parkPendingUnboundIntents(workID: workID)
        try retireScopeCaches(workID: workID)
        if let row = try query(
            "SELECT current_snapshot_id,local_generation FROM works WHERE work_id=?",
            [.text(workID.description)]
        ).first,
            let snapshotBytes = row[0].blob,
            let generation = row[1].int64,
            generation > 0 {
            try _ = upsertCheckpointIntent(
                workID: workID,
                snapshotID: SnapshotID(rawValue: snapshotBytes.hexString),
                generation: generation,
                scope: .bound(new)
            )
        }
        try exec(
            """
            INSERT INTO binding_transitions(
              transition_id,work_id,old_server_instance_id,old_protocol_epoch,
              old_account_id,old_account_fence,disposition,
              new_server_instance_id,new_protocol_epoch,new_account_id,
              new_account_fence,created_at
            ) VALUES(?,?,?,?,?,?,?,?,?,?,?,?)
            """,
            [.text(UUID().uuidString.lowercased()), .text(workID.description)] +
                old.values + [.text("quarantined")] + new.values + [.text(Self.now())]
        )
    }

    /// A prepared/sealed restore is closed as `retired` while its linked
    /// intent/command and immutable audit bytes remain available for
    /// diagnostics. Clearing only the nullable active account pointer keeps
    /// the old receipt bound to its original command and prevents any later
    /// scope from selecting it.
    private func retireRestoreRecords(
        workID: WorkID,
        binding: V2AccountBinding,
        disposition: String
    ) throws {
        let rows = try query(
            """
            SELECT r.restore_id,r.intent_id,r.command_id
            FROM restore_records r
            JOIN sync_intents i
              ON i.intent_id=r.intent_id AND i.work_id=r.work_id
            WHERE r.work_id=? AND r.account_id=?
              AND r.state IN ('prepared','sealed')
              AND i.scope_kind='bound'
              AND i.server_instance_id=? AND i.protocol_epoch=?
              AND i.account_id=? AND i.account_fence=?
            ORDER BY r.rowid
            """,
            [.text(workID.description), .text(binding.accountID)] + binding.values
        )
        for row in rows {
            guard let restoreID = row[0].text,
                  let intentID = row[1].text else {
                throw SyncV2StoreError.invalidLifecycle
            }
            try exec(
                """
                UPDATE sync_intents SET status=?
                WHERE intent_id=? AND work_id=? AND scope_kind='bound'
                  AND server_instance_id=? AND protocol_epoch=?
                  AND account_id=? AND account_fence=?
                  AND status IN ('pending','sealed')
                """,
                [
                    .text(disposition), .text(intentID), .text(workID.description)
                ] + binding.values
            )
            guard try changes() == 1 else { throw SyncV2StoreError.invalidLifecycle }
            if let commandID = row[2].text {
                try exec(
                    """
                    UPDATE sealed_commands SET status=?
                    WHERE command_id=? AND work_id=? AND server_instance_id=?
                      AND protocol_epoch=? AND account_id=? AND account_fence=?
                      AND status IN ('sealed','sending','conflictPending')
                    """,
                    [
                        .text(disposition), .text(commandID), .text(workID.description)
                    ] + binding.values
                )
                guard try changes() == 1 else { throw SyncV2StoreError.invalidLifecycle }
            }
            try exec(
                """
                UPDATE restore_records
                SET account_id=NULL,
                    state='retired',
                    command_id=CASE WHEN state='sealed' THEN command_id ELSE NULL END
                WHERE restore_id=? AND work_id=? AND account_id=?
                  AND state IN ('prepared','sealed')
                """,
                [
                    .text(restoreID), .text(workID.description), .text(binding.accountID)
                ]
            )
            guard try changes() == 1 else { throw SyncV2StoreError.invalidLifecycle }
        }
    }

    /// Parked local checkpoints must never leave an actionable unbound intent
    /// behind. This also coalesces legacy parked saves before a same-namespace
    /// reactivation creates its fresh bound checkpoint intent.
    func parkPendingUnboundIntents(workID: WorkID) throws {
        try exec(
            """
            UPDATE sync_intents SET status='parked'
            WHERE work_id=? AND scope_kind='unbound'
              AND status IN ('pending','sealed')
            """,
            [.text(workID.description)]
        )
    }

    /// Scope-free remote head/equivalence values belong to the retired fence.
    /// Clearing them forces the next fence through bootstrap and replan.
    private func retireScopeCaches(workID: WorkID) throws {
        try exec(
            """
            UPDATE works SET acknowledged_head_snapshot_id=NULL,
                             acknowledged_head_generation=NULL,
                             remote_equivalent_local_snapshot_id=NULL
            WHERE work_id=?
            """,
            [.text(workID.description)]
        )
        try exec(
            "DELETE FROM snapshot_remote_equivalents WHERE work_id=?",
            [.text(workID.description)]
        )
    }
}

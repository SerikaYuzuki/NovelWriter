import Foundation
import NovelCore
import NovelSyncV2

/// Borrows the store executor; transaction ownership stays with LocalSyncV2Store.
struct AccountRepository: SQLiteRepository {
    let executor: SQLiteExecutor
}

extension AccountRepository {
    func bindingIsActive(workID: WorkID, binding: V2AccountBinding) throws -> Bool {
        try !query(
            """
            SELECT 1 FROM account_bindings
            WHERE work_id=? AND server_instance_id=? AND protocol_epoch=?
              AND account_id=? AND account_fence=? AND state='bound'
            """,
            [.text(workID.description)] + binding.values
        ).isEmpty
    }

    func insertBinding(workID: WorkID, binding: V2AccountBinding) throws {
        try exec(
            """
            INSERT INTO account_bindings(
              work_id,server_instance_id,protocol_epoch,account_id,
              account_fence,state
            ) VALUES(?,?,?,?,?,'bound')
            """,
            [.text(workID.description)] + binding.values
        )
    }
}

extension AccountRepository {
    func activeBinding(workID: WorkID) throws -> V2AccountBinding {
        guard let row = try queryRows(
            ActiveAccountBindingRow.self,
            """
            SELECT \(ActiveAccountBindingRow.columns)
            FROM account_bindings WHERE work_id=? AND state='bound'
            """,
            [.text(workID.description)]
        ).first,
            let account = row.accountID,
            let fence = row.accountFence,
            let server = row.serverInstanceID,
            let epoch = row.protocolEpoch else {
            throw SyncV2StoreError.accountMismatch
        }
        return V2AccountBinding(
            accountID: account,
            accountFence: fence,
            serverInstanceID: server,
            protocolEpoch: epoch
        )
    }
}

extension AccountRepository {
    func activeBindingRows() throws -> [AccountBindingRow] {
        try queryRows(
            AccountBindingRow.self,
            """
            SELECT \(AccountBindingRow.columns)
            FROM account_bindings WHERE state='bound' ORDER BY work_id
            """
        )
    }

    func selectedTransitionRows(
        activeRows: [AccountBindingRow],
        from old: V2AccountBinding?,
        to new: V2AccountBinding?
    ) throws -> [AccountBindingRow] {
        guard let old else { return activeRows }
        let selected = activeRows.filter {
            $0.serverInstanceID == old.serverInstanceID &&
                $0.protocolEpoch == old.protocolEpoch &&
                $0.accountID == old.accountID &&
                $0.accountFence == old.accountFence
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
               $0.serverInstanceID == new.serverInstanceID &&
                   $0.protocolEpoch == new.protocolEpoch &&
                   $0.accountID == new.accountID &&
                   $0.accountFence == new.accountFence
           }) {
            return []
        }
        guard activeRows.isEmpty else { throw SyncV2StoreError.accountMismatch }
        return []
    }

    func binding(from row: AccountBindingRow) throws -> V2AccountBinding {
        guard let server = row.serverInstanceID,
              let epoch = row.protocolEpoch,
              let account = row.accountID,
              let fence = row.accountFence else {
            throw SyncV2StoreError.invalidLifecycle
        }
        return V2AccountBinding(
            accountID: account,
            accountFence: fence,
            serverInstanceID: server,
            protocolEpoch: epoch
        )
    }

    func retireRemoteLanes(
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

    func retireRestoreRecords(
        workID: WorkID,
        binding: V2AccountBinding,
        disposition: String
    ) throws {
        let rows = try queryRows(
            RestoreIdentityRow.self,
            """
            SELECT \(RestoreIdentityRow.qualifiedColumns("r"))
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
            guard let restoreID = row.restoreID,
                  let intentID = row.intentID else {
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
            if let commandID = row.commandID {
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

    func retireScopeCaches(workID: WorkID) throws {
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

    func reactivateMatchingParkedBindings(
        to new: V2AccountBinding
    ) throws {
        let parkedRows = try queryRows(
            AccountBindingRow.self,
            """
            SELECT \(AccountBindingRow.qualifiedColumns("p"))
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
                  let workText = row.workID,
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

    func retireBinding(
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

    func installQuarantinedBinding(
        workID: WorkID,
        from old: V2AccountBinding,
        to new: V2AccountBinding
    ) throws {
        try insertBinding(workID: workID, binding: new)
        if let row = try queryRows(
            WorkCurrentRow.self,
            "SELECT \(WorkCurrentRow.columns) FROM works WHERE work_id=?",
            [.text(workID.description)]
        ).first,
            let snapshotBytes = row.currentSnapshotID,
            let generation = row.localGeneration,
            generation > 0 {
            try _ = outboxRepository.upsertCheckpointIntent(
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
                old.values + [.text("quarantined")] + new.values + [.text(StoreValueCoding.now())]
        )
    }

    func reactivateParkedBinding(
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
        if let row = try queryRows(
            WorkCurrentRow.self,
            "SELECT \(WorkCurrentRow.columns) FROM works WHERE work_id=?",
            [.text(workID.description)]
        ).first,
            let snapshotBytes = row.currentSnapshotID,
            let generation = row.localGeneration,
            generation > 0 {
            try _ = outboxRepository.upsertCheckpointIntent(
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
                old.values + [.text("quarantined")] + new.values + [.text(StoreValueCoding.now())]
        )
    }
}

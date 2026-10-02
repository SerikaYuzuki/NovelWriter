import Foundation
import NovelCore
import NovelSyncV2

/// Borrows the store executor; transaction ownership stays with LocalSyncV2Store.
struct DeletionRepository: SQLiteRepository {
    let executor: SQLiteExecutor
}

extension DeletionRepository {
    func workDeletion(workID: WorkID) throws -> V2WorkDeletion? {
        guard let row = try queryRows(
            WorkDeletionRow.self,
            "SELECT \(WorkDeletionRow.columns) FROM work_deletions WHERE work_id=?",
            [.text(workID.description)]
        ).first else { return nil }
        let binding: V2AccountBinding? = if let instance = row.serverInstanceID, let epoch = row.protocolEpoch,
                                            let account = row.accountID, let fence = row.accountFence {
            V2AccountBinding(accountID: account, accountFence: fence, serverInstanceID: instance, protocolEpoch: epoch)
        } else {
            nil
        }
        return V2WorkDeletion(workID: workID, binding: binding, completed: row.phase == "completed")
    }

    func workDeletionIDs(completedOnly: Bool = false) throws -> Set<WorkID> {
        let rows = try query("SELECT work_id FROM work_deletions" + (completedOnly ? " WHERE phase='completed'" : ""))
        return try Set(rows.map { row in
            guard let raw = try row.scalar.text else { throw SyncV2StoreError.invalidLifecycle }
            return try WorkID(uuidString: raw)
        })
    }

    func purgeMigrationStaging(workID: WorkID) throws {
        let migrations = try query(
            "SELECT migration_id FROM migration_staging_batches WHERE proposed_work_id=?",
            [.text(workID.description)]
        )
        for row in migrations {
            guard let migrationID = try row.scalar.text else { throw SyncV2StoreError.invalidLifecycle }
            let args: [SQLiteValue] = [.text(migrationID)]
            try exec("DELETE FROM migration_staging_objects WHERE migration_id=?", args)
            try exec("DELETE FROM migration_staging_batches WHERE migration_id=?", args)
            try exec("DELETE FROM migration_ledger WHERE migration_id=?", args)
        }
    }

    func requireNotDeleting(_ workID: WorkID) throws {
        guard try workDeletion(workID: workID) == nil else { throw SyncV2StoreError.workDeletionPending }
    }
}

/// Uses the caller-owned transaction; never begins or commits one.
extension DeletionRepository {
    func prepareWorkDeletionInTransaction(workID: WorkID, activeBinding: V2AccountBinding?) throws -> V2WorkDeletion {
        if let existing = try workDeletion(workID: workID) {
            guard let previous = existing.binding, previous != activeBinding else { return existing }
            guard let activeBinding,
                  previous.serverInstanceID == activeBinding.serverInstanceID,
                  previous.protocolEpoch == activeBinding.protocolEpoch,
                  previous.accountID == activeBinding.accountID else {
                throw SyncV2StoreError.accountMismatch
            }
            if existing.completed {
                return existing
            }
            guard try !workRepository.workExists(workID: workID)
                || workRepository.scopedWorkRow(workID: workID, scope: .bound(activeBinding)) != nil else {
                throw SyncV2StoreError.accountMismatch
            }
            // A new credential generation may retry the same account's intent,
            // but cannot complete an in-flight deletion from the old generation.
            try exec("UPDATE work_deletions SET account_fence=? WHERE work_id=? AND phase='pending'",
                     [.text(activeBinding.accountFence), .text(workID.description)])
            return V2WorkDeletion(workID: workID, binding: activeBinding, completed: false)
        }
        let binding: V2AccountBinding?
        if try workRepository.scopedWorkRow(workID: workID, scope: .unbound) != nil {
            binding = nil
        } else if let activeBinding {
            guard try !workRepository.workExists(workID: workID) || workRepository.scopedWorkRow(
                workID: workID,
                scope: .bound(activeBinding)
            ) !=
                nil else {
                throw SyncV2StoreError.accountMismatch
            }
            binding = activeBinding
        } else {
            throw SyncV2StoreError.accountMismatch
        }
        try exec("""
        INSERT INTO work_deletions(work_id,server_instance_id,protocol_epoch,account_id,account_fence,phase,created_at)
        VALUES(?,?,?,?,?,'pending',?)
        """, [
            .text(workID.description), binding.map { .text($0.serverInstanceID) } ?? .null,
            binding.map { .int($0.protocolEpoch) } ?? .null,
            binding.map { .text($0.accountID) } ?? .null,
            binding.map { .text($0.accountFence) } ?? .null,
            .text(StoreValueCoding.iso8601(Date()))
        ])
        return V2WorkDeletion(workID: workID, binding: binding, completed: false)
    }
}

/// Uses the caller-owned transaction; never begins or commits one.
extension DeletionRepository {
    func completeWorkDeletionInTransaction(_ deletion: V2WorkDeletion) throws {
        guard try workDeletion(workID: deletion.workID) == deletion else {
            throw SyncV2StoreError.invalidLifecycle
        }
        if deletion.completed {
            return
        }
        try exec("PRAGMA defer_foreign_keys=ON")
        // A synchronized work may contain the last unsent checkpoint. Keep its
        // local graph available for explicit rescue; the marker hides it and
        // blocks all ordinary writers and remote planning.
        if deletion.binding != nil {
            try exec("UPDATE work_deletions SET phase='completed' WHERE work_id=?",
                     [.text(deletion.workID.description)])
            return
        }
        // Only this atomic purge may remove immutable graph rows. Restore
        // every trigger before commit; rollback also restores their DDL.
        let triggers = try queryRows(
            SQLiteSchemaRow.self,
            """
            SELECT \(SQLiteSchemaRow.columns)
            FROM sqlite_schema
            WHERE type='trigger'
              AND name IN ('objects_immutable_delete',
            'snapshots_immutable_delete',
            'snapshot_parents_immutable_delete',
            'snapshot_entries_immutable_delete',
            'conflict_candidates_immutable_delete',
            'intent_subsumptions_immutable_delete', 'shallow_boundaries_guard_delete')
            """
        )
        for trigger in triggers {
            guard let name = trigger.name else { throw SyncV2StoreError.schemaMismatch }
            try exec("DROP TRIGGER \(name)")
        }
        let id: [SQLiteValue] = [.text(deletion.workID.description)]
        try purgeMigrationStaging(workID: deletion.workID)
        let objects = try query("""
        SELECT DISTINCT object_id
        FROM snapshot_entries
        WHERE snapshot_id IN (SELECT snapshot_id
        FROM snapshots
        WHERE work_id=?)
        """, id).compactMap { try $0.scalar.blob }
        let resources = try query(
            "SELECT DISTINCT object_id FROM work_resources WHERE work_id=? AND object_id IS NOT NULL",
            id
        ).compactMap { try $0.scalar.blob }
        try exec("DELETE FROM pending_keep_both WHERE source_work_id=? OR new_work_id=?", id + id)
        for table in ["inbox_closure", "inbox_objects", "inbox_snapshots"] {
            try exec(
                "DELETE FROM \(table) WHERE inbox_id IN (SELECT inbox_id FROM inbox_batches WHERE work_id=?)",
                id
            )
        }
        try exec(
            "DELETE FROM snapshot_entries WHERE snapshot_id IN (SELECT snapshot_id FROM snapshots WHERE work_id=?)",
            id
        )
        for table in [
            "history_backfills", "shallow_boundaries", "intent_subsumptions", "restore_records", "conflict_candidates",
            "conflicts", "inbox_batches",
            "upload_transfers", "remote_receipts", "sync_intents", "sealed_commands", "history_occurrences",
            "snapshot_remote_equivalents", "snapshot_parents", "quarantine_records", "work_resources",
            "binding_transitions", "account_bindings", "snapshots", "works"
        ] {
            try exec("DELETE FROM \(table) WHERE work_id=?", id)
        }
        for object in objects {
            try exec("""
            DELETE
            FROM objects
            WHERE object_id=?
              AND NOT EXISTS(SELECT 1
            FROM snapshot_entries e
            WHERE e.object_id=objects.object_id)
            """, [.blob(object)])
        }
        for resource in resources {
            try exec("""
            DELETE
            FROM resources
            WHERE object_id=?
              AND NOT EXISTS(SELECT 1
            FROM work_resources r
            WHERE r.object_id=resources.object_id)
            """, [.blob(resource)])
        }
        for trigger in triggers {
            guard let sql = trigger.sql else { throw SyncV2StoreError.schemaMismatch }
            try exec(sql)
        }
        try exec("UPDATE work_deletions SET phase='completed' WHERE work_id=?", id)
    }
}

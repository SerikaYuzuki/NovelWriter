import Foundation
import NovelCore
import NovelSyncV2

extension WorkRepository {
    func migrationLedgerEntry(migrationID: UUID) throws -> V2MigrationLedgerEntry? {
        try queryRows(
            MigrationLedgerRow.self,
            """
            SELECT \(MigrationLedgerRow.columns)
            FROM migration_ledger WHERE migration_id=?
            """,
            [.text(migrationID.uuidString.lowercased())]
        ).first.map(WorkRepository.migrationLedgerEntry)
    }

    func migrationLedgerEntry(
        sourceKind: String,
        sourceDigest: Data
    ) throws -> V2MigrationLedgerEntry? {
        try queryRows(
            MigrationLedgerRow.self,
            """
            SELECT \(MigrationLedgerRow.columns)
            FROM migration_ledger WHERE source_kind=? AND source_digest=?
            """,
            [.text(sourceKind), .blob(sourceDigest)]
        ).first.map(WorkRepository.migrationLedgerEntry)
    }

    func migrationStagingBatch(migrationID: UUID) throws -> MigrationStagingRow? {
        try queryRows(
            MigrationStagingRow.self,
            """
            SELECT \(MigrationStagingRow.columns)
            FROM migration_staging_batches WHERE migration_id=?
            """,
            [.text(migrationID.uuidString.lowercased())]
        ).first
    }

    func insertMigrationStaging(_ input: V2MigrationStagingInput) throws {
        try exec(
            """
            INSERT INTO migration_staging_batches(
              migration_id,proposed_work_id,proposed_document_id,
              snapshot_id,manifest_bytes,state
            ) VALUES(?,?,?,?,?,'staged')
            """,
            [
                .text(input.migrationID.uuidString.lowercased()),
                .text(input.proposedWorkID.description),
                .text(input.proposedDocumentID.description),
                .blob(input.snapshotID.bytes), .blob(input.manifestBytes)
            ]
        )
        for (objectID, bytes) in input.objects {
            try exec(
                """
                INSERT INTO migration_staging_objects(
                  migration_id,object_id,byte_count,bytes
                ) VALUES(?,?,?,?)
                """,
                [
                    .text(input.migrationID.uuidString.lowercased()),
                    .blob(objectID.bytes), .int(Int64(bytes.count)), .blob(bytes)
                ]
            )
        }
    }

    func migrationStagingObjects(migrationID: UUID) throws -> [ObjectID: Data] {
        let rows = try queryRows(
            ObjectBytesRow.self,
            "SELECT \(ObjectBytesRow.columns) FROM migration_staging_objects WHERE migration_id=? ORDER BY object_id",
            [.text(migrationID.uuidString.lowercased())]
        )
        var result: [ObjectID: Data] = [:]
        for row in rows {
            guard let idBytes = row.objectID, let bytes = row.bytes,
                  row.byteCount == Int64(bytes.count),
                  let objectID = try? ObjectID(rawValue: idBytes.hexString),
                  objectID.bytes == idBytes else {
                throw SyncV2StoreError.invalidSnapshot
            }
            guard result[objectID] == nil else { throw SyncV2StoreError.invalidSnapshot }
            result[objectID] = bytes
        }
        return result
    }

    func attestMigrationStagingObjects(migrationID: UUID, objects: [ObjectID: Data]) throws {
        let stored = try migrationStagingObjects(migrationID: migrationID)
        guard stored.count == objects.count,
              stored.keys.allSatisfy({ stored[$0] == objects[$0] }) else {
            throw SyncV2StoreError.invalidSnapshot
        }
    }
}

/// Uses the caller-owned transaction; never begins or commits one.
extension WorkRepository {
    func recordMigrationDiscoveredInTransaction(
        migrationID: UUID,
        sourceKind: String,
        sourceDigest: Data,
        evidenceBytes: Data
    ) throws -> V2MigrationLedgerEntry {
        if let existing = try migrationLedgerEntry(sourceKind: sourceKind, sourceDigest: sourceDigest) {
            guard existing.evidenceBytes == evidenceBytes else {
                throw SyncV2StoreError.invalidSnapshot
            }
            return existing
        }
        try exec(
            """
            INSERT INTO migration_ledger(
              migration_id,source_kind,source_digest,evidence_bytes,state
            ) VALUES(?,?,?,?, 'discovered')
            """,
            [
                .text(migrationID.uuidString.lowercased()), .text(sourceKind),
                .blob(sourceDigest), .blob(evidenceBytes)
            ]
        )
        guard let entry = try migrationLedgerEntry(migrationID: migrationID) else {
            throw SyncV2StoreError.sqlite("migration ledger insert")
        }
        return entry
    }
}

/// Uses the caller-owned transaction; never begins or commits one.
extension WorkRepository {
    func recordMigrationBackupExportedInTransaction(
        migrationID: UUID,
        exportBackupMarker: String,
        evidenceBytes: Data
    ) throws -> V2MigrationLedgerEntry {
        guard let current = try migrationLedgerEntry(migrationID: migrationID) else {
            throw SyncV2StoreError.workNotFound
        }
        if current.state == .backupExported || current.state == .staged || current.state == .verified {
            guard current.exportBackupMarker == exportBackupMarker else {
                throw SyncV2StoreError.staleCAS
            }
            return current
        }
        guard current.state == .discovered else { throw SyncV2StoreError.staleCAS }
        try exec(
            """
            UPDATE migration_ledger
            SET export_backup_marker=?,evidence_bytes=?,state='backupExported'
            WHERE migration_id=? AND state='discovered'
            """,
            [
                .text(exportBackupMarker), .blob(evidenceBytes),
                .text(migrationID.uuidString.lowercased())
            ]
        )
        guard try changes() == 1,
              let updated = try migrationLedgerEntry(migrationID: migrationID) else {
            throw SyncV2StoreError.staleCAS
        }
        return updated
    }
}

/// Uses the caller-owned transaction; never begins or commits one.
extension WorkRepository {
    func stageMigrationInTransaction(
        _ input: V2MigrationStagingInput
    ) throws -> V2MigrationLedgerEntry {
        guard let current = try migrationLedgerEntry(migrationID: input.migrationID),
              current.state == .backupExported || current.state == .staged else {
            throw SyncV2StoreError.staleCAS
        }
        if let existing = try migrationStagingBatch(migrationID: input.migrationID) {
            guard existing.proposedWorkID == input.proposedWorkID.description,
                  existing.proposedDocumentID == input.proposedDocumentID.description,
                  existing.snapshotID == input.snapshotID.bytes,
                  existing.manifestBytes == input.manifestBytes else {
                throw SyncV2StoreError.invalidSnapshot
            }
            try attestMigrationStagingObjects(migrationID: input.migrationID, objects: input.objects)
            return current
        }
        try insertMigrationStaging(input)
        try exec(
            "UPDATE migration_ledger SET state='staged' WHERE migration_id=?",
            [.text(input.migrationID.uuidString.lowercased())]
        )
        guard let updated = try migrationLedgerEntry(migrationID: input.migrationID) else {
            throw SyncV2StoreError.sqlite("migration stage")
        }
        return updated
    }
}

/// Uses the caller-owned transaction; never begins or commits one.
extension WorkRepository {
    func verifyMigrationInTransaction(
        migrationID: UUID,
        accountID: String,
        evidenceBytes: Data
    ) throws -> V2MigrationLedgerEntry {
        guard let current = try migrationLedgerEntry(migrationID: migrationID),
              current.state == .staged || current.state == .verified else {
            throw SyncV2StoreError.staleCAS
        }
        guard let batch = try queryRows(
            MigrationVerificationRow.self,
            "SELECT \(MigrationVerificationRow.columns) FROM migration_staging_batches WHERE migration_id=?",
            [.text(migrationID.uuidString.lowercased())]
        ).first, batch.state == "staged" || batch.state == "verified" else {
            throw SyncV2StoreError.staleCAS
        }
        let storedObjects = try migrationStagingObjects(migrationID: migrationID)
        try attestMigrationStagingObjects(migrationID: migrationID, objects: storedObjects)
        if current.state == .verified {
            guard current.accountID == accountID else { throw SyncV2StoreError.accountMismatch }
            return current
        }
        try exec(
            """
            UPDATE migration_ledger SET account_id=?,evidence_bytes=?,state='verified'
            WHERE migration_id=? AND state='staged'
            """,
            [.text(accountID), .blob(evidenceBytes), .text(migrationID.uuidString.lowercased())]
        )
        try exec(
            """
            UPDATE migration_staging_batches
            SET verified_account_id=?,state='verified'
            WHERE migration_id=? AND state='staged'
            """,
            [.text(accountID), .text(migrationID.uuidString.lowercased())]
        )
        guard try changes() == 1,
              let updated = try migrationLedgerEntry(migrationID: migrationID) else {
            throw SyncV2StoreError.staleCAS
        }
        return updated
    }
}

import Foundation
import NovelCore
import NovelSyncV2

public extension LocalSyncV2Store {
    @discardableResult
    func quarantineMigration(
        migrationID: UUID,
        reason: String,
        evidenceBytes: Data
    ) throws -> V2MigrationLedgerEntry {
        guard !reason.isEmpty, !evidenceBytes.isEmpty else { throw SyncV2StoreError.invalidSnapshot }
        return try inTransaction {
            guard let current = try migrationLedgerEntry(migrationID: migrationID) else {
                throw SyncV2StoreError.workNotFound
            }
            if current.state == .quarantined {
                return current
            }
            guard current.state != .committed else { throw SyncV2StoreError.staleCAS }
            try exec(
                """
                UPDATE migration_ledger
                SET state='quarantined',quarantined_from_state=?,evidence_bytes=?
                WHERE migration_id=?
                """,
                [
                    .text(current.state.rawValue), .blob(evidenceBytes),
                    .text(migrationID.uuidString.lowercased())
                ]
            )
            try exec(
                "UPDATE migration_staging_batches SET state='quarantined' WHERE migration_id=?",
                [.text(migrationID.uuidString.lowercased())]
            )
            try exec(
                """
                INSERT INTO quarantine_records(
                  quarantine_id,account_id,reason,evidence_bytes,created_at
                ) VALUES(?,?,?,?,?)
                """,
                [
                    .text(UUID().uuidString.lowercased()), current.accountID.map(SQLiteValue.text) ?? .null,
                    .text(reason), .blob(evidenceBytes), .text(Self.now())
                ]
            )
            guard let updated = try migrationLedgerEntry(migrationID: migrationID) else {
                throw SyncV2StoreError.sqlite("migration quarantine")
            }
            return updated
        }
    }

    func commitMigration(
        _ request: V2MigrationCommitRequest
    ) throws -> V2MigrationCommitResult {
        guard request.expectedSourceDigest.count == 32,
              !request.verifiedMarker.isEmpty else {
            throw SyncV2StoreError.accountMismatch
        }
        return try inTransaction {
            guard let ledger = try migrationLedgerEntry(migrationID: request.staging.migrationID),
                  ledger.sourceDigest == request.expectedSourceDigest else {
                throw SyncV2StoreError.accountMismatch
            }
            if ledger.state == .committed {
                return try replayMigration(request, ledger: ledger)
            }
            return try applyMigration(request, ledger: ledger)
        }
    }

    private func replayMigration(
        _ request: V2MigrationCommitRequest,
        ledger: V2MigrationLedgerEntry
    ) throws -> V2MigrationCommitResult {
        guard ledger.adoptionMarker == request.verifiedMarker,
              ledger.accountID == request.binding.accountID else {
            throw SyncV2StoreError.staleCAS
        }
        let stagedObjects = try migrationStagingObjects(migrationID: request.staging.migrationID)
        try attestMigrationStagingObjects(
            migrationID: request.staging.migrationID,
            objects: request.staging.objects
        )
        guard try replayMigrationStateIsValid(
            request: request,
            stagedObjects: stagedObjects
        ) else {
            throw SyncV2StoreError.staleCAS
        }
        return V2MigrationCommitResult(
            workID: request.staging.proposedWorkID,
            snapshotID: request.staging.snapshotID,
            noChanges: true
        )
    }

    private func replayMigrationStateIsValid(
        request: V2MigrationCommitRequest,
        stagedObjects: [ObjectID: Data]
    ) throws -> Bool {
        guard let batch = try migrationBatchForCommit(migrationID: request.staging.migrationID),
              migrationBatchMatches(batch, request: request),
              let manifest = batch[3].blob,
              let model = try? SnapshotCodec.decode(
                  manifestBytes: manifest,
                  objects: stagedObjects
              ),
              migrationModelMatches(model, request: request),
              try bindingIsActive(
                  workID: request.staging.proposedWorkID,
                  binding: request.binding
              ),
              let work = try query(
                  "SELECT document_id,current_snapshot_id,local_generation FROM works WHERE work_id=?",
                  [.text(request.staging.proposedWorkID.description)]
              ).first,
              migrationWorkMatches(work, request: request),
              try portableResourcesEqual(
                  workID: request.staging.proposedWorkID,
                  resources: request.staging.resources
              ),
              try migrationHistoryExists(request: request),
              try migrationIntentExists(request: request) else {
            return false
        }
        return true
    }

    private func applyMigration(
        _ request: V2MigrationCommitRequest,
        ledger: V2MigrationLedgerEntry
    ) throws -> V2MigrationCommitResult {
        guard ledger.state == .verified,
              ledger.accountID == request.binding.accountID,
              ledger.exportBackupMarker != nil else {
            throw SyncV2StoreError.staleCAS
        }
        guard let batch = try migrationBatchForCommit(migrationID: request.staging.migrationID),
              migrationBatchMatches(batch, request: request),
              let manifest = batch[3].blob else {
            throw SyncV2StoreError.staleCAS
        }
        let stagedObjects = try migrationStagingObjects(migrationID: request.staging.migrationID)
        try attestMigrationStagingObjects(
            migrationID: request.staging.migrationID,
            objects: request.staging.objects
        )
        let encoded = try EncodedSnapshot(
            manifest: SnapshotValidator.validate(manifestBytes: manifest),
            manifestBytes: manifest,
            objects: stagedObjects
        )
        guard encoded.manifest.workId == request.staging.proposedWorkID,
              encoded.snapshotId == request.staging.snapshotID,
              encoded.manifest.entries.contains(where: { $0.entityKey == "work/document" }),
              DocumentID(request.document.id) == request.staging.proposedDocumentID else {
            throw SyncV2StoreError.invalidSnapshot
        }
        guard try !workExists(workID: request.staging.proposedWorkID) else {
            throw SyncV2StoreError.workNotFound
        }
        try SnapshotValidator.validateObjects(encoded)
        let decoded = try SnapshotCodec.decode(
            manifestBytes: encoded.manifestBytes,
            objects: encoded.objects
        )
        guard migrationDocumentMatches(decoded, request: request) else {
            throw SyncV2StoreError.invalidSnapshot
        }
        return try persistMigration(
            request: request,
            encoded: encoded,
            decoded: decoded
        )
    }

    private func persistMigration(
        request: V2MigrationCommitRequest,
        encoded: EncodedSnapshot,
        decoded: SnapshotModel
    ) throws -> V2MigrationCommitResult {
        try insertWork(
            workID: request.staging.proposedWorkID,
            documentID: request.staging.proposedDocumentID,
            documentCreatedAt: Self.iso8601(decoded.documentCreatedAt),
            lane: .normal,
            scope: .bound(request.binding)
        )
        try insertEncoded(encoded, workID: request.staging.proposedWorkID)
        try replacePortableResources(
            workID: request.staging.proposedWorkID,
            resources: request.staging.resources
        )
        try exec(
            """
            UPDATE works SET current_snapshot_id=?,local_generation=1
            WHERE work_id=? AND local_generation=0
            """,
            [.blob(encoded.snapshotIDBytes), .text(request.staging.proposedWorkID.description)]
        )
        guard try changes() == 1 else { throw SyncV2StoreError.staleCAS }
        try insertHistory(
            workID: request.staging.proposedWorkID,
            snapshotID: encoded.snapshotId,
            reason: V2CheckpointReason.migration.rawValue,
            pinned: true,
            generation: 1
        )
        _ = try upsertCheckpointIntent(
            workID: request.staging.proposedWorkID,
            snapshotID: encoded.snapshotId,
            generation: 1,
            scope: .bound(request.binding)
        )
        try exec(
            """
            UPDATE migration_ledger SET adoption_marker=?,state='committed'
            WHERE migration_id=? AND state='verified'
            """,
            [.text(request.verifiedMarker), .text(request.staging.migrationID.uuidString.lowercased())]
        )
        guard try changes() == 1 else { throw SyncV2StoreError.staleCAS }
        return V2MigrationCommitResult(
            workID: request.staging.proposedWorkID,
            snapshotID: encoded.snapshotId,
            noChanges: false
        )
    }

    private func migrationBatchForCommit(migrationID: UUID) throws -> [SQLiteValue]? {
        try query(
            """
            SELECT proposed_work_id,proposed_document_id,snapshot_id,manifest_bytes,
                   state,verified_account_id
            FROM migration_staging_batches WHERE migration_id=?
            """,
            [.text(migrationID.uuidString.lowercased())]
        ).first
    }

    private func migrationBatchMatches(
        _ batch: [SQLiteValue],
        request: V2MigrationCommitRequest
    ) -> Bool {
        batch.count >= 6 &&
            batch[0].text == request.staging.proposedWorkID.description &&
            batch[1].text == request.staging.proposedDocumentID.description &&
            batch[2].blob == request.staging.snapshotID.bytes &&
            batch[3].blob == request.staging.manifestBytes &&
            batch[4].text == "verified" &&
            batch[5].text == request.binding.accountID
    }

    private func migrationModelMatches(
        _ model: SnapshotModel,
        request: V2MigrationCommitRequest
    ) -> Bool {
        model.workId == request.staging.proposedWorkID &&
            DocumentID(model.document.id) == request.staging.proposedDocumentID &&
            model.document == request.document &&
            model.documentCreatedAt == request.documentCreatedAt
    }

    private func migrationWorkMatches(
        _ work: [SQLiteValue],
        request: V2MigrationCommitRequest
    ) -> Bool {
        work.count >= 3 &&
            work[0].text == request.staging.proposedDocumentID.description &&
            work[1].blob == request.staging.snapshotID.bytes &&
            work[2].int64 == 1
    }

    private func migrationDocumentMatches(
        _ model: SnapshotModel,
        request: V2MigrationCommitRequest
    ) -> Bool {
        migrationModelMatches(model, request: request)
    }

    private func migrationHistoryExists(request: V2MigrationCommitRequest) throws -> Bool {
        try !query(
            """
            SELECT 1 FROM history_occurrences
            WHERE work_id=? AND snapshot_id=? AND reason=? AND pinned=1
              AND local_generation=1
            """,
            [
                .text(request.staging.proposedWorkID.description),
                .blob(request.staging.snapshotID.bytes),
                .text(V2CheckpointReason.migration.rawValue)
            ]
        ).isEmpty
    }

    private func migrationIntentExists(request: V2MigrationCommitRequest) throws -> Bool {
        try !query(
            """
            SELECT 1 FROM sync_intents
            WHERE work_id=? AND source_snapshot_id=? AND source_generation=1
              AND kind='checkpoint' AND status='pending' AND scope_kind='bound'
              AND server_instance_id=? AND protocol_epoch=? AND account_id=? AND account_fence=?
            """,
            [
                .text(request.staging.proposedWorkID.description),
                .blob(request.staging.snapshotID.bytes)
            ] + request.binding.values
        ).isEmpty
    }
}

import Foundation
import NovelCore
import NovelSyncV2

public enum V2MigrationLedgerState: String, Codable, Sendable {
    case discovered
    case backupExported
    case staged
    case verified
    case committed
    case quarantined
}

public struct V2MigrationLedgerEntry: Equatable, Sendable {
    public let migrationID: UUID
    public let accountID: String?
    public let sourceKind: String
    public let sourceDigest: Data
    public let exportBackupMarker: String?
    public let adoptionMarker: String?
    public let quarantinedFromState: V2MigrationLedgerState?
    public let evidenceBytes: Data
    public let state: V2MigrationLedgerState

    public init(
        migrationID: UUID,
        accountID: String?,
        sourceKind: String,
        sourceDigest: Data,
        exportBackupMarker: String?,
        adoptionMarker: String?,
        quarantinedFromState: V2MigrationLedgerState?,
        evidenceBytes: Data,
        state: V2MigrationLedgerState
    ) {
        self.migrationID = migrationID
        self.accountID = accountID
        self.sourceKind = sourceKind
        self.sourceDigest = sourceDigest
        self.exportBackupMarker = exportBackupMarker
        self.adoptionMarker = adoptionMarker
        self.quarantinedFromState = quarantinedFromState
        self.evidenceBytes = evidenceBytes
        self.state = state
    }
}

public struct V2MigrationStagingInput: Sendable {
    public let migrationID: UUID
    public let proposedWorkID: WorkID
    public let proposedDocumentID: DocumentID
    public let snapshotID: SnapshotID
    public let manifestBytes: Data
    public let objects: [ObjectID: Data]

    public init(
        migrationID: UUID,
        proposedWorkID: WorkID,
        proposedDocumentID: DocumentID,
        snapshotID: SnapshotID,
        manifestBytes: Data,
        objects: [ObjectID: Data]
    ) {
        self.migrationID = migrationID
        self.proposedWorkID = proposedWorkID
        self.proposedDocumentID = proposedDocumentID
        self.snapshotID = snapshotID
        self.manifestBytes = manifestBytes
        self.objects = objects
    }
}

public struct V2MigrationCommitRequest: Sendable {
    public let staging: V2MigrationStagingInput
    public let binding: V2AccountBinding
    public let expectedSourceDigest: Data
    public let verifiedMarker: String
    public let document: NovelDocument
    public let documentCreatedAt: Date

    public init(
        staging: V2MigrationStagingInput,
        binding: V2AccountBinding,
        expectedSourceDigest: Data,
        verifiedMarker: String,
        document: NovelDocument,
        documentCreatedAt: Date
    ) {
        self.staging = staging
        self.binding = binding
        self.expectedSourceDigest = expectedSourceDigest
        self.verifiedMarker = verifiedMarker
        self.document = document
        self.documentCreatedAt = documentCreatedAt
    }
}

public struct V2MigrationCommitResult: Sendable {
    public let workID: WorkID
    public let snapshotID: SnapshotID
    public let noChanges: Bool

    public init(workID: WorkID, snapshotID: SnapshotID, noChanges: Bool) {
        self.workID = workID
        self.snapshotID = snapshotID
        self.noChanges = noChanges
    }
}

public extension LocalSyncV2Store {
    func migrationLedgerEntry(migrationID: UUID) throws -> V2MigrationLedgerEntry? {
        try query(
            """
            SELECT migration_id,account_id,source_kind,source_digest,
                   export_backup_marker,adoption_marker,quarantined_from_state,
                   evidence_bytes,state
            FROM migration_ledger WHERE migration_id=?
            """,
            [.text(migrationID.uuidString.lowercased())]
        ).first.map(Self.migrationLedgerEntry)
    }

    func migrationLedgerEntry(
        sourceKind: String,
        sourceDigest: Data
    ) throws -> V2MigrationLedgerEntry? {
        try query(
            """
            SELECT migration_id,account_id,source_kind,source_digest,
                   export_backup_marker,adoption_marker,quarantined_from_state,
                   evidence_bytes,state
            FROM migration_ledger WHERE source_kind=? AND source_digest=?
            """,
            [.text(sourceKind), .blob(sourceDigest)]
        ).first.map(Self.migrationLedgerEntry)
    }

    @discardableResult
    func recordMigrationDiscovered(
        migrationID: UUID,
        sourceKind: String,
        sourceDigest: Data,
        evidenceBytes: Data
    ) throws -> V2MigrationLedgerEntry {
        guard sourceDigest.count == 32, !sourceKind.isEmpty, !evidenceBytes.isEmpty else {
            throw SyncV2StoreError.invalidSnapshot
        }
        return try inTransaction {
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

    @discardableResult
    func recordMigrationBackupExported(
        migrationID: UUID,
        exportBackupMarker: String,
        evidenceBytes: Data
    ) throws -> V2MigrationLedgerEntry {
        guard !exportBackupMarker.isEmpty, !evidenceBytes.isEmpty else {
            throw SyncV2StoreError.invalidSnapshot
        }
        return try inTransaction {
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

    @discardableResult
    func stageMigration(
        _ input: V2MigrationStagingInput
    ) throws -> V2MigrationLedgerEntry {
        guard !input.manifestBytes.isEmpty,
              SnapshotID(data: input.manifestBytes) == input.snapshotID else {
            throw SyncV2StoreError.invalidSnapshot
        }
        for (objectID, bytes) in input.objects {
            guard ObjectID(data: bytes) == objectID else {
                throw SyncV2StoreError.invalidSnapshot
            }
        }
        return try inTransaction {
            guard let current = try migrationLedgerEntry(migrationID: input.migrationID),
                  current.state == .backupExported || current.state == .staged else {
                throw SyncV2StoreError.staleCAS
            }
            if let existing = try query(
                "SELECT proposed_work_id,proposed_document_id,snapshot_id,manifest_bytes,state FROM migration_staging_batches WHERE migration_id=?",
                [.text(input.migrationID.uuidString.lowercased())]
            ).first {
                guard existing[0].text == input.proposedWorkID.description,
                      existing[1].text == input.proposedDocumentID.description,
                      existing[2].blob == input.snapshotID.bytes,
                      existing[3].blob == input.manifestBytes else {
                    throw SyncV2StoreError.invalidSnapshot
                }
                try attestMigrationStagingObjects(migrationID: input.migrationID, objects: input.objects)
                return current
            }
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

    @discardableResult
    func verifyMigration(
        migrationID: UUID,
        accountID: String,
        evidenceBytes: Data
    ) throws -> V2MigrationLedgerEntry {
        guard !accountID.isEmpty, !evidenceBytes.isEmpty else {
            throw SyncV2StoreError.accountMismatch
        }
        return try inTransaction {
            guard let current = try migrationLedgerEntry(migrationID: migrationID),
                  current.state == .staged || current.state == .verified else {
                throw SyncV2StoreError.staleCAS
            }
            guard let batch = try query(
                "SELECT state,verified_account_id FROM migration_staging_batches WHERE migration_id=?",
                [.text(migrationID.uuidString.lowercased())]
            ).first, batch[0].text == "staged" || batch[0].text == "verified" else {
                throw SyncV2StoreError.staleCAS
            }
            try attestMigrationStagingObjects(migrationID: migrationID, objects: migrationStagingObjects(migrationID: migrationID))
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
                "UPDATE migration_staging_batches SET verified_account_id=?,state='verified' WHERE migration_id=? AND state='staged'",
                [.text(accountID), .text(migrationID.uuidString.lowercased())]
            )
            guard try changes() == 1,
                  let updated = try migrationLedgerEntry(migrationID: migrationID) else {
                throw SyncV2StoreError.staleCAS
            }
            return updated
        }
    }

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
                "INSERT INTO quarantine_records(quarantine_id,account_id,reason,evidence_bytes,created_at) VALUES(?,?,?,?,?)",
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
                guard ledger.adoptionMarker == request.verifiedMarker,
                      ledger.accountID == request.binding.accountID else {
                    throw SyncV2StoreError.staleCAS
                }
                let stagedObjects = try migrationStagingObjects(migrationID: request.staging.migrationID)
                try attestMigrationStagingObjects(migrationID: request.staging.migrationID, objects: request.staging.objects)
                guard let batch = try query(
                    "SELECT proposed_work_id,proposed_document_id,snapshot_id,manifest_bytes,state,verified_account_id FROM migration_staging_batches WHERE migration_id=?",
                    [.text(request.staging.migrationID.uuidString.lowercased())]
                ).first,
                    batch[0].text == request.staging.proposedWorkID.description,
                    batch[1].text == request.staging.proposedDocumentID.description,
                    batch[2].blob == request.staging.snapshotID.bytes,
                    batch[3].blob == request.staging.manifestBytes,
                    batch[4].text == "verified",
                    batch[5].text == request.binding.accountID,
                    let replayManifest = batch[3].blob,
                    let replayModel = try? SnapshotCodec.decode(manifestBytes: replayManifest, objects: stagedObjects),
                    replayModel.workId == request.staging.proposedWorkID,
                    DocumentID(replayModel.document.id) == request.staging.proposedDocumentID,
                    replayModel.document == request.document,
                    replayModel.documentCreatedAt == request.documentCreatedAt,
                    try bindingIsActive(workID: request.staging.proposedWorkID, binding: request.binding),
                    let work = try query(
                        "SELECT document_id,current_snapshot_id,local_generation FROM works WHERE work_id=?",
                        [.text(request.staging.proposedWorkID.description)]
                    ).first,
                    work[0].text == request.staging.proposedDocumentID.description,
                    work[1].blob == request.staging.snapshotID.bytes,
                    work[2].int64 == 1,
                    try !(query(
                        "SELECT 1 FROM history_occurrences WHERE work_id=? AND snapshot_id=? AND reason=? AND pinned=1 AND local_generation=1",
                        [.text(request.staging.proposedWorkID.description), .blob(request.staging.snapshotID.bytes), .text(V2CheckpointReason.migration.rawValue)]
                    ).isEmpty),
                    try !(query(
                        "SELECT 1 FROM sync_intents WHERE work_id=? AND source_snapshot_id=? AND source_generation=1 AND kind='checkpoint' AND status='pending' AND scope_kind='bound' AND server_instance_id=? AND protocol_epoch=? AND account_id=? AND account_fence=?",
                        [.text(request.staging.proposedWorkID.description), .blob(request.staging.snapshotID.bytes)] + request.binding.values
                    ).isEmpty) else {
                    throw SyncV2StoreError.staleCAS
                }
                return V2MigrationCommitResult(
                    workID: request.staging.proposedWorkID,
                    snapshotID: request.staging.snapshotID,
                    noChanges: true
                )
            }
            guard ledger.state == .verified,
                  ledger.accountID == request.binding.accountID,
                  ledger.exportBackupMarker != nil,
                  let batch = try query(
                      "SELECT proposed_work_id,proposed_document_id,snapshot_id,manifest_bytes,state,verified_account_id FROM migration_staging_batches WHERE migration_id=?",
                      [.text(request.staging.migrationID.uuidString.lowercased())]
                  ).first,
                  batch[0].text == request.staging.proposedWorkID.description,
                  batch[1].text == request.staging.proposedDocumentID.description,
                  batch[2].blob == request.staging.snapshotID.bytes,
                  batch[3].blob == request.staging.manifestBytes,
                  batch[4].text == "verified",
                  batch[5].text == request.binding.accountID else {
                throw SyncV2StoreError.staleCAS
            }
            let stagedObjects = try migrationStagingObjects(migrationID: request.staging.migrationID)
            try attestMigrationStagingObjects(migrationID: request.staging.migrationID, objects: request.staging.objects)
            let encoded = try EncodedSnapshot(
                manifest: SnapshotValidator.validate(manifestBytes: batch[3].blob ?? Data()),
                manifestBytes: batch[3].blob ?? Data(),
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
            let decoded = try SnapshotCodec.decode(manifestBytes: encoded.manifestBytes, objects: encoded.objects)
            guard decoded.workId == request.staging.proposedWorkID,
                  DocumentID(decoded.document.id) == request.staging.proposedDocumentID,
                  decoded.document == request.document,
                  decoded.documentCreatedAt == request.documentCreatedAt else {
                throw SyncV2StoreError.invalidSnapshot
            }
            try insertWork(
                workID: request.staging.proposedWorkID,
                documentID: request.staging.proposedDocumentID,
                documentCreatedAt: Self.iso8601(decoded.documentCreatedAt),
                lane: .normal,
                scope: .bound(request.binding)
            )
            try insertEncoded(encoded, workID: request.staging.proposedWorkID)
            try exec(
                "UPDATE works SET current_snapshot_id=?,local_generation=1 WHERE work_id=? AND local_generation=0",
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
                "UPDATE migration_ledger SET adoption_marker=?,state='committed' WHERE migration_id=? AND state='verified'",
                [.text(request.verifiedMarker), .text(request.staging.migrationID.uuidString.lowercased())]
            )
            guard try changes() == 1 else { throw SyncV2StoreError.staleCAS }
            return V2MigrationCommitResult(
                workID: request.staging.proposedWorkID,
                snapshotID: encoded.snapshotId,
                noChanges: false
            )
        }
    }
}

private extension LocalSyncV2Store {
    func migrationStagingObjects(migrationID: UUID) throws -> [ObjectID: Data] {
        let rows = try query(
            "SELECT object_id,byte_count,bytes FROM migration_staging_objects WHERE migration_id=? ORDER BY object_id",
            [.text(migrationID.uuidString.lowercased())]
        )
        var result: [ObjectID: Data] = [:]
        for row in rows {
            guard let idBytes = row[0].blob, let bytes = row[2].blob,
                  row[1].int64 == Int64(bytes.count),
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

    static func migrationLedgerEntry(_ row: [SQLiteValue]) -> V2MigrationLedgerEntry {
        let state = V2MigrationLedgerState(rawValue: row[8].text ?? "")!
        return V2MigrationLedgerEntry(
            migrationID: UUID(uuidString: row[0].text ?? "")!,
            accountID: row[1].text,
            sourceKind: row[2].text ?? "",
            sourceDigest: row[3].blob ?? Data(),
            exportBackupMarker: row[4].text,
            adoptionMarker: row[5].text,
            quarantinedFromState: row[6].text.flatMap(V2MigrationLedgerState.init(rawValue:)),
            evidenceBytes: row[7].blob ?? Data(),
            state: state
        )
    }
}

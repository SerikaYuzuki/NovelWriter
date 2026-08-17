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
    public let resources: [PortableResource]

    public init(
        migrationID: UUID,
        proposedWorkID: WorkID,
        proposedDocumentID: DocumentID,
        snapshotID: SnapshotID,
        manifestBytes: Data,
        objects: [ObjectID: Data],
        resources: [PortableResource] = []
    ) {
        self.migrationID = migrationID
        self.proposedWorkID = proposedWorkID
        self.proposedDocumentID = proposedDocumentID
        self.snapshotID = snapshotID
        self.manifestBytes = manifestBytes
        self.objects = objects
        self.resources = resources
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
            if let existing = try migrationStagingBatch(migrationID: input.migrationID) {
                guard existing[0].text == input.proposedWorkID.description,
                      existing[1].text == input.proposedDocumentID.description,
                      existing[2].blob == input.snapshotID.bytes,
                      existing[3].blob == input.manifestBytes else {
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
}

extension LocalSyncV2Store {
    private func migrationStagingBatch(migrationID: UUID) throws -> [SQLiteValue]? {
        try query(
            """
            SELECT proposed_work_id,proposed_document_id,snapshot_id,manifest_bytes,state
            FROM migration_staging_batches WHERE migration_id=?
            """,
            [.text(migrationID.uuidString.lowercased())]
        ).first
    }

    private func insertMigrationStaging(_ input: V2MigrationStagingInput) throws {
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

    private static func migrationLedgerEntry(_ row: [SQLiteValue]) -> V2MigrationLedgerEntry {
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

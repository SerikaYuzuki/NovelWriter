import Foundation
import NovelCore
import NovelSyncV2

public extension LocalSyncV2Store {
    func migrationLedgerEntry(migrationID: UUID) throws -> V2MigrationLedgerEntry? {
        try workRepository.migrationLedgerEntry(migrationID: migrationID)
    }

    func migrationLedgerEntry(
        sourceKind: String,
        sourceDigest: Data
    ) throws -> V2MigrationLedgerEntry? {
        try workRepository.migrationLedgerEntry(sourceKind: sourceKind, sourceDigest: sourceDigest)
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
            try workRepository.recordMigrationDiscoveredInTransaction(
                migrationID: migrationID,
                sourceKind: sourceKind,
                sourceDigest: sourceDigest,
                evidenceBytes: evidenceBytes
            )
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
            try workRepository.recordMigrationBackupExportedInTransaction(
                migrationID: migrationID,
                exportBackupMarker: exportBackupMarker,
                evidenceBytes: evidenceBytes
            )
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
            try workRepository.stageMigrationInTransaction(input)
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
            try workRepository.verifyMigrationInTransaction(
                migrationID: migrationID,
                accountID: accountID,
                evidenceBytes: evidenceBytes
            )
        }
    }
}

public extension LocalSyncV2Store {
    @discardableResult
    func quarantineMigration(
        migrationID: UUID,
        reason: String,
        evidenceBytes: Data
    ) throws -> V2MigrationLedgerEntry {
        guard !reason.isEmpty, !evidenceBytes.isEmpty else { throw SyncV2StoreError.invalidSnapshot }
        return try inTransaction {
            try workRepository.quarantineMigrationInTransaction(
                migrationID: migrationID,
                reason: reason,
                evidenceBytes: evidenceBytes
            )
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
            guard let ledger = try workRepository.migrationLedgerEntry(migrationID: request.staging.migrationID),
                  ledger.sourceDigest == request.expectedSourceDigest else {
                throw SyncV2StoreError.accountMismatch
            }
            if ledger.state == .committed {
                return try workRepository.replayMigration(request, ledger: ledger)
            }
            return try workRepository.applyMigration(request, ledger: ledger)
        }
    }
}

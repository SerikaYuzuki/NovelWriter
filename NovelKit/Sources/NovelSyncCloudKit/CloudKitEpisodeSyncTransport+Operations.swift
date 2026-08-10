import CloudKit
import Foundation
import NovelSync

extension CloudKitEpisodeSyncTransport {
    func inspectRevisionRecords(
        key: EpisodeSyncKey,
        externalParentIDs: Set<SyncRevisionID>,
        candidateRevisionIDs: Set<SyncRevisionID>
    ) async throws -> (existingExternalParentIDs: Set<SyncRevisionID>, collidingRevisionIDs: Set<SyncRevisionID>) {
        let allIDs = externalParentIDs.union(candidateRevisionIDs)
        guard !allIDs.isEmpty else { return ([], []) }
        let recordIDByRevision = Dictionary(uniqueKeysWithValues: allIDs.map {
            ($0, CKRecord.ID.episodeRevision($0, key: key))
        })
        let results: [CKRecord.ID: Result<CKRecord, any Error>]
        do {
            results = try await database.records(
                for: Array(recordIDByRevision.values),
                desiredKeys: [
                    CloudKitSyncSchema.Field.protocolVersion,
                    CloudKitSyncSchema.Field.workID,
                    CloudKitSyncSchema.Field.episodeID,
                    CloudKitSyncSchema.Field.revisionID,
                    CloudKitSyncSchema.Field.parentRevisionIDs,
                    CloudKitSyncSchema.Field.bodyDigest,
                    CloudKitSyncSchema.Field.bodyByteCount,
                    CloudKitSyncSchema.Field.mutationID
                ]
            )
        } catch {
            throw mappedOperationError(error)
        }

        var existingParents = Set<SyncRevisionID>()
        var collisions = Set<SyncRevisionID>()
        for (revisionID, recordID) in recordIDByRevision {
            guard let result = results[recordID] else {
                throw CloudKitSyncAdapterError.operationFailed
            }
            switch result {
            case let .success(record):
                try codec.validateRevisionMetadataRecord(
                    record,
                    expectedKey: key,
                    expectedRevisionID: revisionID
                )
                if externalParentIDs.contains(revisionID) {
                    existingParents.insert(revisionID)
                }
                if candidateRevisionIDs.contains(revisionID) {
                    collisions.insert(revisionID)
                }
            case let .failure(error):
                if CloudKitErrorMapper.isUnknownItem(error) {
                    continue
                }
                throw mappedOperationError(error)
            }
        }
        guard existingParents == externalParentIDs else {
            throw EpisodeSyncTransportError.missingRevision
        }
        return (existingParents, collisions)
    }

    func modifyAtomically(_ records: [CKRecord]) async throws -> [CKRecord.ID: CKRecord] {
        guard !records.isEmpty,
              records.allSatisfy({ $0.recordID.zoneID == CloudKitSyncSchema.zoneID }) else {
            throw CloudKitSyncAdapterError.invalidArguments
        }
        let result: (
            saveResults: [CKRecord.ID: Result<CKRecord, any Error>],
            deleteResults: [CKRecord.ID: Result<Void, any Error>]
        )
        do {
            result = try await database.modifyRecords(
                saving: records,
                deleting: [],
                savePolicy: .ifServerRecordUnchanged,
                atomically: true
            )
        } catch {
            throw error
        }
        guard result.deleteResults.isEmpty else {
            throw CloudKitSyncAdapterError.operationFailed
        }
        var saved: [CKRecord.ID: CKRecord] = [:]
        var failures: [any Error] = []
        for record in records {
            guard let itemResult = result.saveResults[record.recordID] else {
                throw CloudKitSyncAdapterError.operationFailed
            }
            switch itemResult {
            case let .success(serverRecord):
                saved[record.recordID] = serverRecord
            case let .failure(error):
                failures.append(error)
            }
        }
        if let conflict = failures.first(where: CloudKitErrorMapper.containsServerRecordChanged) {
            throw conflict
        }
        if let zoneReset = failures.first(where: CloudKitErrorMapper.isZoneReset) {
            throw zoneReset
        }
        if let zoneMissing = failures.first(where: CloudKitErrorMapper.isZoneMissing) {
            throw zoneMissing
        }
        if let materialFailure = failures.first(where: { !CloudKitErrorMapper.isBatchRequestFailed($0) }) {
            if failures.count == 1 {
                throw materialFailure
            }
            throw CloudKitSyncAdapterError.partialFailure(
                Set(failures.map(CloudKitErrorMapper.failureKind))
            )
        }
        if let batchFailure = failures.first {
            throw batchFailure
        }
        return saved
    }
}

import CloudKit
import Foundation
import NovelSync

extension CloudKitRecordCodec {
    func makeRevisionRecord(
        _ revision: EpisodeRevision,
        mutationID: SyncMutationID
    ) throws -> CloudKitRevisionRecord {
        try revision.validate()
        let staged = try assetStore.stage(content: revision.content)
        let record = CKRecord(
            recordType: CloudKitSyncSchema.RecordType.episodeRevision,
            recordID: .episodeRevision(revision.revisionID, key: revision.key)
        )
        setCommonFields(on: record, workID: revision.key.workID)
        record[CloudKitSyncSchema.Field.episodeID] = revision.key.episodeID.rawValue.uuidString as CKRecordValue
        record[CloudKitSyncSchema.Field.revisionID] = revision.revisionID.rawValue.uuidString as CKRecordValue
        record[CloudKitSyncSchema.Field.parentRevisionIDs] = revision.parentRevisionIDs
            .map(\.rawValue.uuidString) as CKRecordValue
        record[CloudKitSyncSchema.Field.branchID] = revision.branchID.rawValue.uuidString as CKRecordValue
        record[CloudKitSyncSchema.Field.authorReplicaID] = revision.authorReplicaID.rawValue.uuidString as CKRecordValue
        record[CloudKitSyncSchema.Field.authorSessionID] = revision.authorSessionID.rawValue.uuidString as CKRecordValue
        record[CloudKitSyncSchema.Field.clientCreatedAt] = revision.clientCreatedAt as CKRecordValue
        record[CloudKitSyncSchema.Field.bodyDigest] = revision.contentDigest.rawValue as CKRecordValue
        record[CloudKitSyncSchema.Field.bodyByteCount] = NSNumber(value: Int64(revision.content.utf8.count))
        record[CloudKitSyncSchema.Field.bodyAsset] = staged.asset
        record[CloudKitSyncSchema.Field.mutationID] = mutationID.rawValue.uuidString as CKRecordValue
        return CloudKitRevisionRecord(record: record, stagedAsset: staged)
    }

    func decodeRevisionRecord(
        _ record: CKRecord,
        expectedKey: EpisodeSyncKey,
        expectedRevisionID: SyncRevisionID
    ) throws -> EpisodeRevision {
        try validateRevisionRecordIdentity(record, expectedKey: expectedKey, expectedRevisionID: expectedRevisionID)
        let parents = try decodeParents(record, expectedRevisionID: expectedRevisionID)
        let branchID = try SyncBranchID(
            rawValue: parseCanonicalUUID(requiredString(record, CloudKitSyncSchema.Field.branchID))
        )
        let authorReplicaID = try parseSyncReplicaID(
            requiredString(record, CloudKitSyncSchema.Field.authorReplicaID)
        )
        let authorSessionID = try parseSyncSessionID(
            requiredString(record, CloudKitSyncSchema.Field.authorSessionID)
        )
        guard let createdAt = record[CloudKitSyncSchema.Field.clientCreatedAt] as? Date,
              let asset = record[CloudKitSyncSchema.Field.bodyAsset] as? CKAsset else {
            throw CloudKitSyncAdapterError.invalidRemoteRecord
        }
        let expectedDigest = try SyncContentDigest(
            validating: requiredString(record, CloudKitSyncSchema.Field.bodyDigest)
        )
        _ = try parseCanonicalUUID(requiredString(record, CloudKitSyncSchema.Field.mutationID))
        let byteCount = try requiredInt(record, CloudKitSyncSchema.Field.bodyByteCount)
        let data = try assetStore.read(asset: asset, expectedByteCount: byteCount)
        guard let content = String(data: data, encoding: .utf8),
              Data(content.utf8) == data,
              SyncContentDigest(content: content) == expectedDigest else {
            throw CloudKitSyncAdapterError.invalidRemoteAsset
        }
        let revision = try EpisodeRevision(
            key: expectedKey,
            revisionID: expectedRevisionID,
            parentRevisionIDs: parents,
            branchID: branchID,
            authorReplicaID: authorReplicaID,
            authorSessionID: authorSessionID,
            content: content,
            clientCreatedAt: createdAt
        )
        guard revision.contentDigest == expectedDigest else {
            throw CloudKitSyncAdapterError.invalidRemoteAsset
        }
        return revision
    }

    func validateRevisionMetadataRecord(
        _ record: CKRecord,
        expectedKey: EpisodeSyncKey,
        expectedRevisionID: SyncRevisionID
    ) throws {
        try validateRevisionRecordIdentity(record, expectedKey: expectedKey, expectedRevisionID: expectedRevisionID)
        _ = try decodeParents(record, expectedRevisionID: expectedRevisionID)
        _ = try SyncContentDigest(validating: requiredString(record, CloudKitSyncSchema.Field.bodyDigest))
        _ = try parseCanonicalUUID(requiredString(record, CloudKitSyncSchema.Field.mutationID))
        let byteCount = try requiredInt(record, CloudKitSyncSchema.Field.bodyByteCount)
        guard byteCount <= EpisodeRevision.maximumContentUTF8Bytes else {
            throw CloudKitSyncAdapterError.invalidRemoteRecord
        }
    }

    private func validateRevisionRecordIdentity(
        _ record: CKRecord,
        expectedKey: EpisodeSyncKey,
        expectedRevisionID: SyncRevisionID
    ) throws {
        guard record.recordType == CloudKitSyncSchema.RecordType.episodeRevision,
              record.recordID == .episodeRevision(expectedRevisionID, key: expectedKey) else {
            throw CloudKitSyncAdapterError.invalidRemoteRecord
        }
        try validateCommonFields(record, expectedWorkID: expectedKey.workID)
        try validateCanonicalUUIDField(
            record,
            field: CloudKitSyncSchema.Field.episodeID,
            expected: expectedKey.episodeID.rawValue
        )
        try validateCanonicalUUIDField(
            record,
            field: CloudKitSyncSchema.Field.revisionID,
            expected: expectedRevisionID.rawValue
        )
    }

    private func decodeParents(
        _ record: CKRecord,
        expectedRevisionID: SyncRevisionID
    ) throws -> [SyncRevisionID] {
        let parentStrings = try requiredStringArray(record, CloudKitSyncSchema.Field.parentRevisionIDs)
        guard parentStrings.count <= 2 else {
            throw CloudKitSyncAdapterError.invalidRemoteRecord
        }
        let parents = try parentStrings.map(parseSyncRevisionID)
        guard Set(parents).count == parents.count,
              !parents.contains(expectedRevisionID) else {
            throw CloudKitSyncAdapterError.invalidRemoteRecord
        }
        return parents
    }
}

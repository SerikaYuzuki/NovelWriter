import CloudKit
import Foundation
import NovelSync

extension CloudKitRecordCodec {
    func makeMutationReceiptRecord(_ receipt: CloudKitMutationReceipt) -> CKRecord {
        let record = CKRecord(
            recordType: CloudKitSyncSchema.RecordType.mutationReceipt,
            recordID: .mutationReceipt(receipt.mutationID, key: receipt.key)
        )
        setCommonFields(on: record, workID: receipt.key.workID)
        record[CloudKitSyncSchema.Field.episodeID] = receipt.key.episodeID.rawValue.uuidString as CKRecordValue
        record[CloudKitSyncSchema.Field.mutationID] = receipt.mutationID.rawValue.uuidString as CKRecordValue
        record[CloudKitSyncSchema.Field.commandDigest] = receipt.commandDigest.rawValue as CKRecordValue
        record[CloudKitSyncSchema.Field.resultHeadRevisionID] = receipt.resultHeadRevisionID.rawValue.uuidString as CKRecordValue
        record[CloudKitSyncSchema.Field.resultLeaseEpoch] = NSNumber(value: Int64(receipt.resultLease.authority.epoch))
        record[CloudKitSyncSchema.Field.resultHolderReplicaID] = receipt.resultLease.authority.holderReplicaID
            .rawValue.uuidString as CKRecordValue
        record[CloudKitSyncSchema.Field.resultHolderSessionID] = receipt.resultLease.authority.holderSessionID
            .rawValue.uuidString as CKRecordValue
        record[CloudKitSyncSchema.Field.resultLeaseExpiresAt] = receipt.resultLease.expiresAt as CKRecordValue
        return record
    }

    func decodeMutationReceipt(
        _ record: CKRecord,
        expectedKey: EpisodeSyncKey,
        expectedMutationID: SyncMutationID
    ) throws -> CloudKitMutationReceipt {
        guard record.recordType == CloudKitSyncSchema.RecordType.mutationReceipt,
              record.recordID == .mutationReceipt(expectedMutationID, key: expectedKey) else {
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
            field: CloudKitSyncSchema.Field.mutationID,
            expected: expectedMutationID.rawValue
        )
        let commandDigest = try SyncContentDigest(
            validating: requiredString(record, CloudKitSyncSchema.Field.commandDigest)
        )
        let headID = try parseSyncRevisionID(
            requiredString(record, CloudKitSyncSchema.Field.resultHeadRevisionID)
        )
        let epoch = try requiredUnsignedInt64(record, CloudKitSyncSchema.Field.resultLeaseEpoch)
        let authority = try EpisodeLeaseAuthority(
            holderReplicaID: parseSyncReplicaID(
                requiredString(record, CloudKitSyncSchema.Field.resultHolderReplicaID)
            ),
            holderSessionID: parseSyncSessionID(
                requiredString(record, CloudKitSyncSchema.Field.resultHolderSessionID)
            ),
            epoch: epoch
        )
        guard let expiresAt = record[CloudKitSyncSchema.Field.resultLeaseExpiresAt] as? Date else {
            throw CloudKitSyncAdapterError.invalidRemoteRecord
        }
        return CloudKitMutationReceipt(
            key: expectedKey,
            mutationID: expectedMutationID,
            commandDigest: commandDigest,
            resultHeadRevisionID: headID,
            resultLease: EpisodeLease(authority: authority, expiresAt: expiresAt)
        )
    }
}

import CloudKit
import CoreFoundation
import Foundation
import NovelSync

struct CloudKitEpisodeControl: Sendable {
    let record: CKRecord?
    let key: EpisodeSyncKey
    let headRevisionID: SyncRevisionID?
    let leaseEpoch: UInt64
    let lease: EpisodeLease?
}

struct CloudKitMutationReceipt: Equatable, Sendable {
    let key: EpisodeSyncKey
    let mutationID: SyncMutationID
    let commandDigest: SyncContentDigest
    let resultHeadRevisionID: SyncRevisionID
    let resultLease: EpisodeLease
}

struct CloudKitRevisionRecord: Sendable {
    let record: CKRecord
    let stagedAsset: CloudKitStagedAsset
}

struct CloudKitRecordCodec: Sendable {
    static let maximumWorkTitleUTF8Bytes = 64 * 1024

    let assetStore: CloudKitAssetStore

    func makeWorkRecord(_ descriptor: SyncWorkDescriptor) throws -> CKRecord {
        guard descriptor.title.utf8.count <= Self.maximumWorkTitleUTF8Bytes else {
            throw CloudKitSyncAdapterError.invalidArguments
        }
        let record = CKRecord(recordType: CloudKitSyncSchema.RecordType.work, recordID: .syncWork(descriptor.workID))
        setCommonFields(on: record, workID: descriptor.workID)
        record[CloudKitSyncSchema.Field.sourceDocumentID] = descriptor.sourceDocumentID.uuidString as CKRecordValue
        record[CloudKitSyncSchema.Field.structureDigest] = descriptor.structureDigest.rawValue as CKRecordValue
        record[CloudKitSyncSchema.Field.title] = descriptor.title as CKRecordValue
        return record
    }

    func decodeWorkRecord(_ record: CKRecord) throws -> SyncWorkDescriptor {
        guard record.recordType == CloudKitSyncSchema.RecordType.work,
              record.recordID.zoneID == CloudKitSyncSchema.zoneID else {
            throw CloudKitSyncAdapterError.invalidRemoteRecord
        }
        try validateProtocolVersion(record)
        let workID = try parseSyncWorkID(requiredString(record, CloudKitSyncSchema.Field.workID))
        guard record.recordID == .syncWork(workID) else {
            throw CloudKitSyncAdapterError.invalidRemoteRecord
        }
        let sourceDocumentID = try parseCanonicalUUID(
            requiredString(record, CloudKitSyncSchema.Field.sourceDocumentID)
        )
        let structureDigest: SyncWorkStructureDigest
        do {
            structureDigest = try SyncWorkStructureDigest(
                validating: requiredString(record, CloudKitSyncSchema.Field.structureDigest)
            )
        } catch {
            throw CloudKitSyncAdapterError.invalidRemoteRecord
        }
        let title = try requiredString(record, CloudKitSyncSchema.Field.title)
        guard title.utf8.count <= Self.maximumWorkTitleUTF8Bytes else {
            throw CloudKitSyncAdapterError.invalidRemoteRecord
        }
        return SyncWorkDescriptor(
            workID: workID,
            sourceDocumentID: sourceDocumentID,
            structureDigest: structureDigest,
            title: title
        )
    }

    func makeEmptyControlRecord(for key: EpisodeSyncKey) -> CKRecord {
        let record = CKRecord(recordType: CloudKitSyncSchema.RecordType.episodeControl, recordID: .episodeControl(key))
        setCommonFields(on: record, workID: key.workID)
        record[CloudKitSyncSchema.Field.episodeID] = key.episodeID.rawValue.uuidString as CKRecordValue
        record[CloudKitSyncSchema.Field.leaseEpoch] = NSNumber(value: Int64(0))
        return record
    }

    func updateControlRecord(
        _ existing: CKRecord?,
        key: EpisodeSyncKey,
        headRevisionID: SyncRevisionID?,
        leaseEpoch: UInt64,
        lease: EpisodeLease?
    ) throws -> CKRecord {
        guard leaseEpoch <= EpisodeLeaseAuthority.maximumEpoch,
              lease?.authority.epoch == leaseEpoch || lease == nil else {
            throw EpisodeSyncTransportError.leaseEpochOverflow
        }
        let record = existing ?? makeEmptyControlRecord(for: key)
        guard record.recordID == .episodeControl(key),
              record.recordType == CloudKitSyncSchema.RecordType.episodeControl else {
            throw CloudKitSyncAdapterError.invalidRemoteRecord
        }
        setCommonFields(on: record, workID: key.workID)
        record[CloudKitSyncSchema.Field.episodeID] = key.episodeID.rawValue.uuidString as CKRecordValue
        record[CloudKitSyncSchema.Field.headRevisionID] = headRevisionID?.rawValue.uuidString as CKRecordValue?
        record[CloudKitSyncSchema.Field.leaseEpoch] = NSNumber(value: Int64(leaseEpoch))
        record[CloudKitSyncSchema.Field.holderReplicaID] = lease?.authority.holderReplicaID.rawValue.uuidString as CKRecordValue?
        record[CloudKitSyncSchema.Field.holderSessionID] = lease?.authority.holderSessionID.rawValue.uuidString as CKRecordValue?
        record[CloudKitSyncSchema.Field.leaseExpiresAt] = lease?.expiresAt as CKRecordValue?
        return record
    }

    func decodeControlRecord(_ record: CKRecord, expectedKey: EpisodeSyncKey) throws -> CloudKitEpisodeControl {
        guard record.recordType == CloudKitSyncSchema.RecordType.episodeControl,
              record.recordID == .episodeControl(expectedKey) else {
            throw CloudKitSyncAdapterError.invalidRemoteRecord
        }
        try validateCommonFields(record, expectedWorkID: expectedKey.workID)
        try validateCanonicalUUIDField(
            record,
            field: CloudKitSyncSchema.Field.episodeID,
            expected: expectedKey.episodeID.rawValue
        )
        let epoch = try requiredUnsignedInt64(record, CloudKitSyncSchema.Field.leaseEpoch)
        guard epoch <= EpisodeLeaseAuthority.maximumEpoch else {
            throw CloudKitSyncAdapterError.invalidRemoteRecord
        }

        let headID = try optionalString(record, CloudKitSyncSchema.Field.headRevisionID).map(parseSyncRevisionID)
        let holderReplica = try optionalString(record, CloudKitSyncSchema.Field.holderReplicaID)
        let holderSession = try optionalString(record, CloudKitSyncSchema.Field.holderSessionID)
        let rawExpiresAt = record[CloudKitSyncSchema.Field.leaseExpiresAt]
        let expiresAt = rawExpiresAt as? Date
        let hasAnyLeaseField = holderReplica != nil || holderSession != nil || rawExpiresAt != nil
        let lease: EpisodeLease?
        if hasAnyLeaseField {
            guard let holderReplica, let holderSession, let expiresAt else {
                throw CloudKitSyncAdapterError.invalidRemoteRecord
            }
            let authority = try EpisodeLeaseAuthority(
                holderReplicaID: parseSyncReplicaID(holderReplica),
                holderSessionID: parseSyncSessionID(holderSession),
                epoch: epoch
            )
            lease = EpisodeLease(authority: authority, expiresAt: expiresAt)
        } else {
            lease = nil
        }
        return CloudKitEpisodeControl(
            record: record,
            key: expectedKey,
            headRevisionID: headID,
            leaseEpoch: epoch,
            lease: lease
        )
    }

    func removeStagedAssets(_ assets: [CloudKitStagedAsset]) {
        assetStore.remove(assets)
    }

    func setCommonFields(on record: CKRecord, workID: SyncWorkID) {
        record[CloudKitSyncSchema.Field.protocolVersion] = NSNumber(value: CloudKitSyncSchema.protocolVersion)
        record[CloudKitSyncSchema.Field.workID] = workID.rawValue.uuidString as CKRecordValue
    }

    func validateCommonFields(_ record: CKRecord, expectedWorkID: SyncWorkID) throws {
        guard record.recordID.zoneID == CloudKitSyncSchema.zoneID else {
            throw CloudKitSyncAdapterError.invalidRemoteRecord
        }
        try validateProtocolVersion(record)
        try validateCanonicalUUIDField(
            record,
            field: CloudKitSyncSchema.Field.workID,
            expected: expectedWorkID.rawValue
        )
    }

    func validateProtocolVersion(_ record: CKRecord) throws {
        guard let number = record[CloudKitSyncSchema.Field.protocolVersion] as? NSNumber,
              isIntegralNumber(number) else {
            throw CloudKitSyncAdapterError.invalidRemoteRecord
        }
        let version = number.int64Value
        guard version == CloudKitSyncSchema.protocolVersion else {
            throw CloudKitSyncAdapterError.unsupportedSchemaVersion(version)
        }
    }

    func validateCanonicalUUIDField(_ record: CKRecord, field: String, expected: UUID) throws {
        let decoded = try parseCanonicalUUID(requiredString(record, field))
        guard decoded == expected else { throw CloudKitSyncAdapterError.invalidRemoteRecord }
    }

    func requiredString(_ record: CKRecord, _ field: String) throws -> String {
        guard let value = record[field] as? String else {
            throw CloudKitSyncAdapterError.invalidRemoteRecord
        }
        return value
    }

    func optionalString(_ record: CKRecord, _ field: String) throws -> String? {
        guard let value = record[field] else { return nil }
        guard let string = value as? String else {
            throw CloudKitSyncAdapterError.invalidRemoteRecord
        }
        return string
    }

    func requiredStringArray(_ record: CKRecord, _ field: String) throws -> [String] {
        guard let values = record[field] as? [String] else {
            throw CloudKitSyncAdapterError.invalidRemoteRecord
        }
        return values
    }

    func requiredInt(_ record: CKRecord, _ field: String) throws -> Int {
        guard let number = record[field] as? NSNumber,
              isIntegralNumber(number),
              number.int64Value >= 0,
              number.int64Value <= Int64(Int.max) else {
            throw CloudKitSyncAdapterError.invalidRemoteRecord
        }
        return Int(number.int64Value)
    }

    func requiredUnsignedInt64(_ record: CKRecord, _ field: String) throws -> UInt64 {
        guard let number = record[field] as? NSNumber,
              isIntegralNumber(number),
              number.int64Value >= 0 else {
            throw CloudKitSyncAdapterError.invalidRemoteRecord
        }
        return UInt64(number.int64Value)
    }

    func isIntegralNumber(_ number: NSNumber) -> Bool {
        guard CFGetTypeID(number) != CFBooleanGetTypeID(),
              number.doubleValue.isFinite else {
            return false
        }
        return number.doubleValue == Double(number.int64Value)
    }

    func parseSyncWorkID(_ value: String) throws -> SyncWorkID {
        try SyncWorkID(rawValue: parseCanonicalUUID(value))
    }

    func parseSyncRevisionID(_ value: String) throws -> SyncRevisionID {
        try SyncRevisionID(rawValue: parseCanonicalUUID(value))
    }

    func parseSyncReplicaID(_ value: String) throws -> SyncReplicaID {
        try SyncReplicaID(rawValue: parseCanonicalUUID(value))
    }

    func parseSyncSessionID(_ value: String) throws -> SyncEditSessionID {
        try SyncEditSessionID(rawValue: parseCanonicalUUID(value))
    }

    func parseCanonicalUUID(_ value: String) throws -> UUID {
        guard value.utf8.count == 36,
              let uuid = UUID(uuidString: value),
              uuid.uuidString == value else {
            throw CloudKitSyncAdapterError.invalidRemoteRecord
        }
        return uuid
    }
}

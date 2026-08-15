import CloudKit
import Foundation
import NovelSync

extension CloudKitRecordCodec {
    func makeNoteRecord(
        _ entity: NoteSyncRecord,
        existing: CKRecord? = nil
    ) throws -> (record: CKRecord, stagedAsset: CloudKitStagedAsset?) {
        let recordType = CloudKitSyncSchema.recordType(for: entity.key.kind)
        let recordID = CKRecord.ID.noteEntity(entity.key)
        let record: CKRecord
        if let existing {
            guard existing.recordID == recordID, existing.recordType == recordType else {
                throw CloudKitSyncAdapterError.invalidRemoteRecord
            }
            record = existing
        } else {
            record = CKRecord(recordType: recordType, recordID: recordID)
        }
        setCommonFields(on: record, workID: entity.key.workID)
        record[CloudKitSyncSchema.Field.entityID] = entity.key.entityID.rawValue.uuidString as CKRecordValue
        record[CloudKitSyncSchema.Field.entityKind] = entity.key.kind.rawValue as CKRecordValue
        record[CloudKitSyncSchema.Field.contentDigest] = entity.digest.rawValue as CKRecordValue
        if case let .work(payload) = entity.payload {
            record[CloudKitSyncSchema.Field.title] = SyncWorkLibraryEntry.displayTitleProjection(payload.title)
                as CKRecordValue
        } else {
            record[CloudKitSyncSchema.Field.title] = nil
        }
        let payload = try NoteSyncCanonicalJSON.encodePayload(entity.payload)
        let staged: CloudKitStagedAsset?
        if payload.count <= CloudKitSyncSchema.maximumInlinePayloadUTF8Bytes,
           let json = String(data: payload, encoding: .utf8) {
            record[CloudKitSyncSchema.Field.payloadJSON] = json as CKRecordValue
            record[CloudKitSyncSchema.Field.payloadAsset] = nil
            record[CloudKitSyncSchema.Field.payloadByteCount] = nil
            staged = nil
        } else {
            let asset = try assetStore.stage(
                data: payload,
                maximumByteCount: NoteSyncRecord.maximumPayloadUTF8Bytes,
                fileExtension: "json"
            )
            record[CloudKitSyncSchema.Field.payloadJSON] = nil
            record[CloudKitSyncSchema.Field.payloadAsset] = asset.asset
            record[CloudKitSyncSchema.Field.payloadByteCount] = Int64(payload.count) as CKRecordValue
            staged = asset
        }
        return (record, staged)
    }

    func decodeNoteRecord(_ record: CKRecord) throws -> NoteSyncRecord {
        guard let kind = CloudKitSyncSchema.entityKind(forRecordType: record.recordType),
              record.recordID.zoneID == CloudKitSyncSchema.zoneID else {
            throw CloudKitSyncAdapterError.invalidRemoteRecord
        }
        try validateProtocolVersion(record)
        let workID = try parseSyncWorkID(requiredString(record, CloudKitSyncSchema.Field.workID))
        let entityID = try WorkStableID(rawValue: parseCanonicalUUID(
            requiredString(record, CloudKitSyncSchema.Field.entityID)
        ))
        let encodedKind = try requiredString(record, CloudKitSyncSchema.Field.entityKind)
        guard encodedKind == kind.rawValue else {
            throw CloudKitSyncAdapterError.invalidRemoteRecord
        }
        let key = NoteSyncEntityKey(workID: workID, kind: kind, entityID: entityID)
        guard record.recordID == .noteEntity(key) else {
            throw CloudKitSyncAdapterError.invalidRemoteRecord
        }
        let json = try optionalString(record, CloudKitSyncSchema.Field.payloadJSON)
        let asset = record[CloudKitSyncSchema.Field.payloadAsset] as? CKAsset
        let payloadData: Data
        switch (json, asset) {
        case let (json?, nil):
            payloadData = Data(json.utf8)
        case let (nil, asset?):
            let byteCount = try requiredInt(record, CloudKitSyncSchema.Field.payloadByteCount)
            payloadData = try assetStore.read(
                asset: asset,
                expectedByteCount: byteCount,
                maximumByteCount: NoteSyncRecord.maximumPayloadUTF8Bytes
            )
        default:
            throw CloudKitSyncAdapterError.invalidRemoteRecord
        }
        let payload = try NoteSyncCanonicalJSON.decodePayload(from: payloadData, kind: kind)
        let entity = try NoteSyncRecord(key: key, payload: payload)
        let digest = try SyncContentDigest(
            validating: requiredString(record, CloudKitSyncSchema.Field.contentDigest)
        )
        guard entity.digest == digest else {
            throw CloudKitSyncAdapterError.invalidRemoteRecord
        }
        return entity
    }
}

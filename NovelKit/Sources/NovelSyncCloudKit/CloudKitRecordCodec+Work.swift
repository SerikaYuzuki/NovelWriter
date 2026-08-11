import CloudKit
import Foundation
import NovelSync

struct CloudKitWorkControl: Sendable {
    let record: CKRecord?
    let workID: SyncWorkID
    let headRevisionID: SyncRevisionID?
    let headSnapshotDigest: SyncContentDigest?
}

struct CloudKitWorkMutationReceipt: Equatable, Sendable {
    let workID: SyncWorkID
    let mutationID: SyncMutationID
    let commandDigest: SyncContentDigest
    let resultHeadRevisionID: SyncRevisionID
    let resultHeadSnapshotDigest: SyncContentDigest
}

struct CloudKitWorkRevisionRecord: Sendable {
    let record: CKRecord
    let stagedAsset: CloudKitStagedAsset
}

extension CloudKitRecordCodec {
    func makeEmptyWorkControlRecord(for workID: SyncWorkID) -> CKRecord {
        let record = CKRecord(
            recordType: CloudKitSyncSchema.RecordType.workControl,
            recordID: .workControl(workID)
        )
        setCommonFields(on: record, workID: workID)
        return record
    }

    func updateWorkControlRecord(
        _ existing: CKRecord?,
        workID: SyncWorkID,
        headRevisionID: SyncRevisionID?,
        headSnapshotDigest: SyncContentDigest?
    ) throws -> CKRecord {
        guard (headRevisionID == nil) == (headSnapshotDigest == nil) else {
            throw CloudKitSyncAdapterError.invalidArguments
        }
        let record = existing ?? makeEmptyWorkControlRecord(for: workID)
        guard record.recordType == CloudKitSyncSchema.RecordType.workControl,
              record.recordID == .workControl(workID) else {
            throw CloudKitSyncAdapterError.invalidRemoteRecord
        }
        setCommonFields(on: record, workID: workID)
        record[CloudKitSyncSchema.Field.headRevisionID] = headRevisionID?.rawValue.uuidString as CKRecordValue?
        record[CloudKitSyncSchema.Field.snapshotDigest] = headSnapshotDigest?.rawValue as CKRecordValue?
        return record
    }

    func decodeWorkControlRecord(
        _ record: CKRecord,
        expectedWorkID: SyncWorkID
    ) throws -> CloudKitWorkControl {
        guard record.recordType == CloudKitSyncSchema.RecordType.workControl,
              record.recordID == .workControl(expectedWorkID) else {
            throw CloudKitSyncAdapterError.invalidRemoteRecord
        }
        try validateCommonFields(record, expectedWorkID: expectedWorkID)
        let headRevisionID = try optionalString(
            record,
            CloudKitSyncSchema.Field.headRevisionID
        ).map(parseSyncRevisionID)
        let headSnapshotDigest = try optionalString(
            record,
            CloudKitSyncSchema.Field.snapshotDigest
        ).map { try SyncContentDigest(validating: $0) }
        guard (headRevisionID == nil) == (headSnapshotDigest == nil) else {
            throw CloudKitSyncAdapterError.invalidRemoteRecord
        }
        return CloudKitWorkControl(
            record: record,
            workID: expectedWorkID,
            headRevisionID: headRevisionID,
            headSnapshotDigest: headSnapshotDigest
        )
    }

    func makeWorkRevisionRecord(
        _ revision: WorkRevision,
        mutationID: SyncMutationID
    ) throws -> CloudKitWorkRevisionRecord {
        try revision.validate()
        let canonical = try WorkCanonicalJSON.encodeRevision(revision)
        let revisionDigest = SyncContentDigest(
            content: String(decoding: canonical, as: UTF8.self)
        )
        let staged = try assetStore.stage(
            data: canonical,
            maximumByteCount: WorkRevision.maximumCanonicalByteCount,
            fileExtension: "json"
        )
        let record = CKRecord(
            recordType: CloudKitSyncSchema.RecordType.workRevision,
            recordID: .workRevision(revision.revisionID, workID: revision.workID)
        )
        setCommonFields(on: record, workID: revision.workID)
        record[CloudKitSyncSchema.Field.revisionID] = revision.revisionID.rawValue.uuidString as CKRecordValue
        record[CloudKitSyncSchema.Field.parentRevisionIDs] = revision.parentRevisionIDs
            .map(\.rawValue.uuidString) as CKRecordValue
        record[CloudKitSyncSchema.Field.branchID] = revision.branchID.rawValue.uuidString as CKRecordValue
        record[CloudKitSyncSchema.Field.authorReplicaID] = revision.authorReplicaID.rawValue.uuidString as CKRecordValue
        record[CloudKitSyncSchema.Field.authorSessionID] = revision.authorSessionID.rawValue.uuidString as CKRecordValue
        record[CloudKitSyncSchema.Field.clientCreatedAt] = revision.clientCreatedAt as CKRecordValue
        record[CloudKitSyncSchema.Field.snapshotDigest] = revision.snapshotDigest.rawValue as CKRecordValue
        record[CloudKitSyncSchema.Field.snapshotByteCount] = NSNumber(value: revision.snapshotByteCount)
        record[CloudKitSyncSchema.Field.revisionDigest] = revisionDigest.rawValue as CKRecordValue
        record[CloudKitSyncSchema.Field.revisionByteCount] = NSNumber(value: canonical.count)
        record[CloudKitSyncSchema.Field.revisionAsset] = staged.asset
        record[CloudKitSyncSchema.Field.mutationID] = mutationID.rawValue.uuidString as CKRecordValue
        // v1のWorkSnapshotはNovelDocumentだけを同期する。将来資料manifestを追加しても
        // record typeを分岐させず拡張できるよう、現在の明示的な空metadataを残す。
        record[CloudKitSyncSchema.Field.attachmentCount] = NSNumber(value: 0)
        return CloudKitWorkRevisionRecord(record: record, stagedAsset: staged)
    }

    func decodeWorkRevisionRecord(
        _ record: CKRecord,
        expectedWorkID: SyncWorkID,
        expectedRevisionID: SyncRevisionID
    ) throws -> WorkRevision {
        try validateWorkRevisionRecordIdentity(
            record,
            expectedWorkID: expectedWorkID,
            expectedRevisionID: expectedRevisionID
        )
        let parentIDs = try decodeWorkParents(
            record,
            expectedRevisionID: expectedRevisionID
        )
        let branchID = try SyncBranchID(
            rawValue: parseCanonicalUUID(requiredString(record, CloudKitSyncSchema.Field.branchID))
        )
        let authorReplicaID = try parseSyncReplicaID(
            requiredString(record, CloudKitSyncSchema.Field.authorReplicaID)
        )
        let authorSessionID = try parseSyncSessionID(
            requiredString(record, CloudKitSyncSchema.Field.authorSessionID)
        )
        guard let clientCreatedAt = record[CloudKitSyncSchema.Field.clientCreatedAt] as? Date,
              let asset = record[CloudKitSyncSchema.Field.revisionAsset] as? CKAsset else {
            throw CloudKitSyncAdapterError.invalidRemoteRecord
        }
        let snapshotDigest = try SyncContentDigest(
            validating: requiredString(record, CloudKitSyncSchema.Field.snapshotDigest)
        )
        let snapshotByteCount = try requiredInt(record, CloudKitSyncSchema.Field.snapshotByteCount)
        guard snapshotByteCount <= WorkSnapshot.maximumCanonicalByteCount else {
            throw CloudKitSyncAdapterError.invalidRemoteRecord
        }
        let revisionDigest = try SyncContentDigest(
            validating: requiredString(record, CloudKitSyncSchema.Field.revisionDigest)
        )
        let revisionByteCount = try requiredInt(record, CloudKitSyncSchema.Field.revisionByteCount)
        _ = try parseCanonicalUUID(requiredString(record, CloudKitSyncSchema.Field.mutationID))
        try validateEmptyAttachmentMetadata(record)

        let data = try assetStore.read(
            asset: asset,
            expectedByteCount: revisionByteCount,
            maximumByteCount: WorkRevision.maximumCanonicalByteCount
        )
        guard let canonicalString = String(data: data, encoding: .utf8),
              Data(canonicalString.utf8) == data,
              SyncContentDigest(content: canonicalString) == revisionDigest else {
            throw CloudKitSyncAdapterError.invalidRemoteAsset
        }
        let revision: WorkRevision
        do {
            revision = try WorkCanonicalJSON.decodeRevision(data)
            guard try WorkCanonicalJSON.encodeRevision(revision) == data else {
                throw CloudKitSyncAdapterError.invalidRemoteAsset
            }
        } catch let error as CloudKitSyncAdapterError {
            throw error
        } catch {
            throw CloudKitSyncAdapterError.invalidRemoteAsset
        }
        guard revision.workID == expectedWorkID,
              revision.revisionID == expectedRevisionID,
              revision.parentRevisionIDs == parentIDs,
              revision.branchID == branchID,
              revision.authorReplicaID == authorReplicaID,
              revision.authorSessionID == authorSessionID,
              revision.clientCreatedAt == clientCreatedAt,
              revision.snapshotDigest == snapshotDigest,
              revision.snapshotByteCount == snapshotByteCount else {
            throw CloudKitSyncAdapterError.invalidRemoteRecord
        }
        return revision
    }

    func validateWorkRevisionMetadataRecord(
        _ record: CKRecord,
        expectedWorkID: SyncWorkID,
        expectedRevisionID: SyncRevisionID
    ) throws {
        try validateWorkRevisionRecordIdentity(
            record,
            expectedWorkID: expectedWorkID,
            expectedRevisionID: expectedRevisionID
        )
        _ = try decodeWorkParents(record, expectedRevisionID: expectedRevisionID)
        _ = try SyncContentDigest(
            validating: requiredString(record, CloudKitSyncSchema.Field.snapshotDigest)
        )
        let snapshotByteCount = try requiredInt(record, CloudKitSyncSchema.Field.snapshotByteCount)
        _ = try SyncContentDigest(
            validating: requiredString(record, CloudKitSyncSchema.Field.revisionDigest)
        )
        let revisionByteCount = try requiredInt(record, CloudKitSyncSchema.Field.revisionByteCount)
        _ = try parseCanonicalUUID(requiredString(record, CloudKitSyncSchema.Field.mutationID))
        try validateEmptyAttachmentMetadata(record)
        guard snapshotByteCount <= WorkSnapshot.maximumCanonicalByteCount,
              revisionByteCount <= WorkRevision.maximumCanonicalByteCount else {
            throw CloudKitSyncAdapterError.invalidRemoteRecord
        }
    }

    func makeWorkMutationReceiptRecord(_ receipt: CloudKitWorkMutationReceipt) -> CKRecord {
        let record = CKRecord(
            recordType: CloudKitSyncSchema.RecordType.workMutationReceipt,
            recordID: .workMutationReceipt(receipt.mutationID, workID: receipt.workID)
        )
        setCommonFields(on: record, workID: receipt.workID)
        record[CloudKitSyncSchema.Field.mutationID] = receipt.mutationID.rawValue.uuidString as CKRecordValue
        record[CloudKitSyncSchema.Field.commandDigest] = receipt.commandDigest.rawValue as CKRecordValue
        record[CloudKitSyncSchema.Field.resultHeadRevisionID] = receipt.resultHeadRevisionID
            .rawValue.uuidString as CKRecordValue
        record[CloudKitSyncSchema.Field.snapshotDigest] = receipt.resultHeadSnapshotDigest
            .rawValue as CKRecordValue
        return record
    }

    func decodeWorkMutationReceipt(
        _ record: CKRecord,
        expectedWorkID: SyncWorkID,
        expectedMutationID: SyncMutationID
    ) throws -> CloudKitWorkMutationReceipt {
        guard record.recordType == CloudKitSyncSchema.RecordType.workMutationReceipt,
              record.recordID == .workMutationReceipt(expectedMutationID, workID: expectedWorkID) else {
            throw CloudKitSyncAdapterError.invalidRemoteRecord
        }
        try validateCommonFields(record, expectedWorkID: expectedWorkID)
        try validateCanonicalUUIDField(
            record,
            field: CloudKitSyncSchema.Field.mutationID,
            expected: expectedMutationID.rawValue
        )
        return try CloudKitWorkMutationReceipt(
            workID: expectedWorkID,
            mutationID: expectedMutationID,
            commandDigest: SyncContentDigest(
                validating: requiredString(record, CloudKitSyncSchema.Field.commandDigest)
            ),
            resultHeadRevisionID: parseSyncRevisionID(
                requiredString(record, CloudKitSyncSchema.Field.resultHeadRevisionID)
            ),
            resultHeadSnapshotDigest: SyncContentDigest(
                validating: requiredString(record, CloudKitSyncSchema.Field.snapshotDigest)
            )
        )
    }

    private func validateWorkRevisionRecordIdentity(
        _ record: CKRecord,
        expectedWorkID: SyncWorkID,
        expectedRevisionID: SyncRevisionID
    ) throws {
        guard record.recordType == CloudKitSyncSchema.RecordType.workRevision,
              record.recordID == .workRevision(expectedRevisionID, workID: expectedWorkID) else {
            throw CloudKitSyncAdapterError.invalidRemoteRecord
        }
        try validateCommonFields(record, expectedWorkID: expectedWorkID)
        try validateCanonicalUUIDField(
            record,
            field: CloudKitSyncSchema.Field.revisionID,
            expected: expectedRevisionID.rawValue
        )
    }

    private func decodeWorkParents(
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

    private func validateEmptyAttachmentMetadata(_ record: CKRecord) throws {
        let attachmentCount = try requiredInt(record, CloudKitSyncSchema.Field.attachmentCount)
        let manifestDigest = try optionalString(
            record,
            CloudKitSyncSchema.Field.attachmentManifestDigest
        )
        guard attachmentCount == 0, manifestDigest == nil else {
            // v1 clientは資料binaryを取得できない。metadataだけ見て同期済みと誤認せず、
            // resource transportが実装されるまでは非空manifestを明示的に拒否する。
            throw CloudKitSyncAdapterError.invalidRemoteRecord
        }
    }
}

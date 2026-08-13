import CloudKit
import Foundation
import NovelSync
@testable import NovelSyncCloudKit
import Testing

@Suite("CloudKit whole-work schema")
struct CloudKitWorkSyncSchemaTests {
    @Test("whole-work records are additive and cannot collide with episode records")
    func namesAndTypesAreDisjoint() throws {
        let revisionID = try SyncRevisionID(
            rawValue: #require(UUID(uuidString: "11111111-1111-4111-8111-111111111111"))
        )
        let mutationID = try SyncMutationID(
            rawValue: #require(UUID(uuidString: "22222222-2222-4222-8222-222222222222"))
        )

        let workControl = CloudKitSyncRecordNames.workControl(cloudTestWorkID)
        let workRevision = CloudKitSyncRecordNames.workRevision(revisionID, workID: cloudTestWorkID)
        let workReceipt = CloudKitSyncRecordNames.workMutationReceipt(mutationID, workID: cloudTestWorkID)
        let episodeControl = CloudKitSyncRecordNames.episodeControl(cloudTestKey)

        #expect(workControl == "v1.work.4D875891-E4A9-45CC-B0E3-9CB9024EAA18.whole.control")
        #expect(workRevision.hasSuffix(".whole.revision.11111111-1111-4111-8111-111111111111"))
        #expect(workReceipt.hasSuffix(".whole.mutation.22222222-2222-4222-8222-222222222222"))
        #expect(workControl != episodeControl)
        #expect(CloudKitSyncSchema.RecordType.workControl != CloudKitSyncSchema.RecordType.episodeControl)
        #expect(CloudKitSyncSchema.RecordType.workRevision != CloudKitSyncSchema.RecordType.episodeRevision)
        #expect(
            CloudKitSyncSchema.RecordType.workMutationReceipt
                != CloudKitSyncSchema.RecordType.mutationReceipt
        )
        #expect(CKRecord.ID.workControl(cloudTestWorkID).zoneID == CloudKitSyncSchema.zoneID)
        #expect(
            CKRecord.ID.workRevision(revisionID, workID: cloudTestWorkID).zoneID
                == CloudKitSyncSchema.zoneID
        )
        #expect(
            Set(CloudKitSyncSchema.workSyncProductionRecordTypes) == [
                "FUMINIWAWorkControlV1",
                "FUMINIWAWorkRevisionV1",
                "FUMINIWAWorkMutationReceiptV1"
            ]
        )
    }

    @Test("production checklist covers every runtime record, field type, and query index")
    func productionSchemaChecklistMatchesCodecRecords() throws {
        let checklist = CloudKitSyncSchema.productionSchemaChecklist
        #expect(checklist.count == 14)
        #expect(
            Set(checklist.map(\.name)) == [
                "FUMINIWASyncWorkV1",
                "FUMINIWAEpisodeControlV1",
                "FUMINIWAEpisodeRevisionV1",
                "FUMINIWAMutationReceiptV1",
                "FUMINIWAWorkControlV1",
                "FUMINIWAWorkRevisionV1",
                "FUMINIWAWorkMutationReceiptV1",
                "FUMINIWANoteWorkV1",
                "FUMINIWANoteChapterV1",
                "FUMINIWANoteEpisodeV1",
                "FUMINIWANoteCharacterV1",
                "FUMINIWANotePlotCardV1",
                "FUMINIWANoteFlagV1",
                "FUMINIWANoteWorldNoteV1"
            ]
        )
        #expect(checklist.allSatisfy { $0.queryableSystemFields == ["recordName"] })

        let root = try makeCloudTestDirectory()
        defer { removeCloudTestDirectory(root) }
        let codec = try CloudKitRecordCodec(assetStore: CloudKitAssetStore(rootURL: root))
        let encoded = try encodedProductionChecklistRecords(codec: codec)
        defer { codec.removeStagedAssets(encoded.stagedAssets) }

        for record in encoded.records {
            let schema = try #require(checklist.first { $0.name == record.recordType })
            let keys = Set(record.allKeys())
            #expect(schema.requiredFields.isSubset(of: keys))
            #expect(keys.isSubset(of: Set(schema.fields.keys)))
            for key in keys {
                let value = try #require(record[key])
                #expect(cloudKitProductionFieldType(of: value) == schema.fields[key])
            }
        }
    }

    @Test("revision parent lists are optional schema fields")
    func revisionParentListsAreOptional() throws {
        let checklist = CloudKitSyncSchema.productionSchemaChecklist
        #expect(checklist.allSatisfy { recordType in
            recordType.optionalFields.isSubset(of: Set(recordType.fields.keys))
        })
        let episodeRevisionSchema = try #require(checklist.first {
            $0.name == CloudKitSyncSchema.RecordType.episodeRevision
        })
        let workRevisionSchema = try #require(checklist.first {
            $0.name == CloudKitSyncSchema.RecordType.workRevision
        })
        #expect(episodeRevisionSchema.optionalFields.contains(CloudKitSyncSchema.Field.parentRevisionIDs))
        #expect(workRevisionSchema.optionalFields.contains(CloudKitSyncSchema.Field.parentRevisionIDs))
    }

    @Test("whole-work payloads use assets instead of the one-megabyte record field")
    func largeCanonicalPayloadStagesAsAsset() throws {
        let root = try makeCloudTestDirectory()
        defer { removeCloudTestDirectory(root) }
        let store = try CloudKitAssetStore(rootURL: root)
        let payload = Data(repeating: 0x61, count: 1_100_000)

        let staged = try store.stage(
            data: payload,
            maximumByteCount: WorkSnapshot.maximumCanonicalByteCount,
            fileExtension: "json"
        )
        defer { store.remove([staged]) }

        #expect(staged.asset.fileURL == staged.url)
        #expect(
            try store.read(
                asset: staged.asset,
                expectedByteCount: payload.count,
                maximumByteCount: WorkSnapshot.maximumCanonicalByteCount
            ) == payload
        )
    }

    @Test("asset staging rejects caller limits and unsafe file extensions")
    func assetStagingRespectsResourceContract() throws {
        let root = try makeCloudTestDirectory()
        defer { removeCloudTestDirectory(root) }
        let store = try CloudKitAssetStore(rootURL: root)

        #expect(throws: CloudKitSyncAdapterError.invalidArguments) {
            try store.stage(
                data: Data(repeating: 0, count: 2),
                maximumByteCount: 1,
                fileExtension: "json"
            )
        }
        #expect(throws: CloudKitSyncAdapterError.invalidArguments) {
            try store.stage(
                data: Data(),
                maximumByteCount: 1,
                fileExtension: "../json"
            )
        }
    }
}

private func encodedProductionChecklistRecords(
    codec: CloudKitRecordCodec
) throws -> (records: [CKRecord], stagedAssets: [CloudKitStagedAsset]) {
    let structureDigest = try SyncWorkStructureDigest(
        validating: String(repeating: "a", count: 64)
    )
    let descriptor = try SyncWorkDescriptor(
        workID: cloudTestWorkID,
        sourceDocumentID: #require(
            UUID(uuidString: "AAAAAAAA-AAAA-4AAA-8AAA-AAAAAAAAAAAA")
        ),
        structureDigest: structureDigest,
        title: "schema checklist"
    )
    let lease = try makeCloudTestLease()
    let episodeRevision = try makeCloudTestRevision(
        id: #require(UUID(uuidString: "11111111-1111-4111-8111-111111111111")),
        parents: [],
        content: "本文"
    )
    let episodeMutationID = SyncMutationID()
    let encodedEpisode = try codec.makeRevisionRecord(
        episodeRevision,
        mutationID: episodeMutationID
    )
    let episodeReceipt = codec.makeMutationReceiptRecord(
        CloudKitMutationReceipt(
            key: cloudTestKey,
            mutationID: episodeMutationID,
            commandDigest: SyncContentDigest(content: "episode-command"),
            resultHeadRevisionID: episodeRevision.revisionID,
            resultLease: lease
        )
    )
    let workRevision = try makeWorkRevision()
    let workMutationID = SyncMutationID()
    let encodedWork = try codec.makeWorkRevisionRecord(
        workRevision,
        mutationID: workMutationID
    )
    let workReceipt = codec.makeWorkMutationReceiptRecord(
        CloudKitWorkMutationReceipt(
            workID: cloudTestWorkID,
            mutationID: workMutationID,
            commandDigest: SyncContentDigest(content: "work-command"),
            resultHeadRevisionID: workRevision.revisionID,
            resultHeadSnapshotDigest: workRevision.snapshotDigest
        )
    )
    let records = try [
        codec.makeWorkRecord(descriptor),
        codec.updateControlRecord(
            nil,
            key: cloudTestKey,
            headRevisionID: episodeRevision.revisionID,
            leaseEpoch: lease.authority.epoch,
            lease: lease
        ),
        encodedEpisode.record,
        episodeReceipt,
        codec.updateWorkControlRecord(
            nil,
            workID: cloudTestWorkID,
            headRevisionID: workRevision.revisionID,
            headSnapshotDigest: workRevision.snapshotDigest,
            libraryEntry: SyncWorkLibraryEntry(head: workRevision)
        ),
        encodedWork.record,
        workReceipt
    ]
    return (records, [encodedEpisode.stagedAsset, encodedWork.stagedAsset])
}

private func cloudKitProductionFieldType(
    of value: CKRecordValue
) -> CloudKitSyncSchema.ProductionFieldType? {
    switch value {
    case is String:
        .string
    case is NSNumber:
        .int64
    case is Date:
        .timestamp
    case is CKAsset:
        .asset
    case is [String]:
        .stringList
    default:
        nil
    }
}

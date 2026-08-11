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

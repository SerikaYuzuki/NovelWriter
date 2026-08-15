import CloudKit
import Foundation
import NovelCore
import NovelSync
@testable import NovelSyncCloudKit
import Testing

@Suite("CloudKit note workID query fallback")
struct CloudKitNoteWorkIDQueryTests {
    @Test("invalidArguments from a missing workID index may scan the type")
    func invalidArgumentsAllowsTypeScan() {
        #expect(CloudKitNoteWorkIDQuery.shouldScanType(after: CloudKitSyncAdapterError.invalidArguments))
        #expect(CloudKitNoteWorkIDQuery.shouldUseRecordIDFallback(after: CloudKitSyncAdapterError.invalidArguments))
        #expect(
            CloudKitNoteWorkIDQuery.shouldScanType(
                after: CloudKitSyncAdapterError.partialFailure([.invalidArguments])
            )
        )
        #expect(!CloudKitNoteWorkIDQuery.shouldScanType(after: CloudKitSyncAdapterError.recordNotFound))
        #expect(!CloudKitNoteWorkIDQuery.shouldScanType(after: CloudKitSyncAdapterError.zoneUnavailable))
        #expect(!CloudKitNoteWorkIDQuery.shouldUseRecordIDFallback(after: CloudKitSyncAdapterError.zoneUnavailable))
        #expect(
            CloudKitNoteWorkIDQuery.shouldTreatMissingTypeAsEmpty(
                after: CloudKitSyncAdapterError.recordNotFound
            )
        )
        #expect(
            CloudKitNoteWorkIDQuery.shouldTreatMissingTypeAsEmpty(after: CKError(.unknownItem))
        )
        #expect(
            !CloudKitNoteWorkIDQuery.shouldTreatMissingTypeAsEmpty(
                after: CloudKitSyncAdapterError.invalidArguments
            )
        )
        #expect(
            !CloudKitNoteWorkIDQuery.shouldTreatMissingTypeAsEmpty(
                after: CloudKitSyncAdapterError.zoneUnavailable
            )
        )
    }

    @Test("type scan keeps only records whose workID field matches")
    func matchingFiltersByWorkIDField() throws {
        let root = try makeCloudTestDirectory()
        defer { removeCloudTestDirectory(root) }
        let codec = try CloudKitRecordCodec(assetStore: CloudKitAssetStore(rootURL: root))
        let wanted = try codec.makeNoteRecord(
            NoteSyncRecord(
                key: .work(cloudTestWorkID),
                payload: .work(
                    NoteSyncWorkPayload(
                        documentID: WorkStableID(rawValue: cloudTestWorkID.rawValue),
                        title: "wanted",
                        synopsis: "",
                        chapterOrder: [],
                        characterOrder: [],
                        plotCardOrder: [],
                        flagOrder: [],
                        worldNoteOrder: []
                    )
                )
            )
        ).record
        let otherWorkID = SyncWorkID()
        let other = try codec.makeNoteRecord(
            NoteSyncRecord(
                key: .work(otherWorkID),
                payload: .work(
                    NoteSyncWorkPayload(
                        documentID: WorkStableID(rawValue: otherWorkID.rawValue),
                        title: "other",
                        synopsis: "",
                        chapterOrder: [],
                        characterOrder: [],
                        plotCardOrder: [],
                        flagOrder: [],
                        worldNoteOrder: []
                    )
                )
            )
        ).record
        let matched = CloudKitNoteWorkIDQuery.matching(cloudTestWorkID, in: [other, wanted])
        #expect(matched.map(\.recordID) == [wanted.recordID])
        #expect((matched[0][CloudKitSyncSchema.Field.workID] as? String) == cloudTestWorkID.rawValue.uuidString)
    }
}

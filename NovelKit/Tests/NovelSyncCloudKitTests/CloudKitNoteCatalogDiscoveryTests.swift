import Foundation
import NovelCore
import NovelSync
@testable import NovelSyncCloudKit
import Testing

@Suite("CloudKit note catalog discovery")
struct CloudKitNoteCatalogDiscoveryTests {
    @Test("note record names yield WorkIDs without requiring a CKQuery")
    func workIDsParseFromNoteRecordNames() {
        let workID = cloudTestWorkID
        let workName = CloudKitSyncRecordNames.noteEntity(.work(workID))
        let episodeName = CloudKitSyncRecordNames.noteEntity(
            NoteSyncEntityKey(
                workID: workID,
                kind: .episode,
                entityID: WorkStableID(rawValue: cloudTestEpisodeID.rawValue)
            )
        )
        #expect(CloudKitSyncRecordNames.workID(fromNoteRecordName: workName) == workID)
        #expect(CloudKitSyncRecordNames.workID(fromNoteRecordName: episodeName) == workID)
        #expect(CloudKitSyncRecordNames.workID(fromNoteRecordName: "v1.work.not-a-note") == nil)

        let ids = CloudKitNoteCatalogDiscovery.uniqueWorkIDs(
            fromRecordNames: [episodeName, workName, "ignored"]
        )
        #expect(ids == [workID])
        #expect(!CloudKitNoteCatalogDiscovery.modificationDatePredicate().predicateFormat.isEmpty)
        #expect(
            CloudKitNoteCatalogDiscovery.workIDPresentPredicate().predicateFormat
                .contains(CloudKitSyncSchema.Field.workID)
        )
        #expect(CloudKitNoteCatalogDiscovery.workIDHexPrefixPredicates().count == 16)
    }

    @Test("catalog discovery prefers workID field queries over recordName TRUEPREDICATE")
    func workIDCatalogPredicatesCoverHexPrefixes() {
        let prefixes = CloudKitNoteCatalogDiscovery.workIDHexPrefixPredicates().map(\.predicateFormat)
        #expect(prefixes.contains { $0.contains("BEGINSWITH") && $0.contains("A") })
        #expect(prefixes.contains { $0.contains("0") })
    }
}

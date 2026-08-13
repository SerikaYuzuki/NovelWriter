import CloudKit
import NovelSync
@testable import NovelSyncCloudKit
import Testing

@Suite("CKSyncEngine boundary")
struct CloudKitChangeTrackingDriverTests {
    @Test("push changes auto-fetch and Note pending records are sent by the engine")
    func pushFetchSendsNotePendingRecords() {
        #expect(CloudKitChangeTrackingDriver.automaticallyFetchesPushChanges)
        #expect(CloudKitChangeTrackingDriver.sendsPendingRecordChanges)
    }

    @Test("pending queue keeps Note records and drops Episode/Work CAS names")
    func pendingQueueFiltersNoteRecordsOnly() {
        let noteID = CKRecord.ID.noteEntity(.work(cloudTestWorkID))
        let episodeID = CKRecord.ID.episodeControl(cloudTestKey)
        let pending: [CKSyncEngine.PendingRecordZoneChange] = [
            .saveRecord(noteID),
            .saveRecord(episodeID),
            .deleteRecord(noteID)
        ]
        let filtered = CloudKitNotePendingQueue.noteChanges(from: pending)
        #expect(filtered.count == 2)
        #expect(CloudKitNotePendingQueue.isNoteRecordName(noteID.recordName))
        #expect(!CloudKitNotePendingQueue.isNoteRecordName(episodeID.recordName))
    }
}

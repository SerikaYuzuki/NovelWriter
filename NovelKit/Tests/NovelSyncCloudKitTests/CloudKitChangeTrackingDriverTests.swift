import CloudKit
import NovelCore
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

    @Test("intended Note saves without engine ack fail closed")
    func unackedIntendedSavesFailClosed() throws {
        let record = try NoteSyncRecord(
            key: .work(cloudTestWorkID),
            payload: .work(
                NoteSyncWorkPayload(
                    documentID: WorkStableID(rawValue: cloudTestWorkID.rawValue),
                    title: "unacked",
                    synopsis: "",
                    chapterOrder: [],
                    characterOrder: [],
                    plotCardOrder: [],
                    flagOrder: [],
                    worldNoteOrder: []
                )
            )
        )
        let outcome = CloudKitNoteSendOutcome()
        #expect(throws: CloudKitSyncAdapterError.operationFailed) {
            try outcome.apply(intended: [record], existingConflicts: []) { _ in
                throw CloudKitSyncAdapterError.invalidRemoteRecord
            }
        }
    }

    @Test("fetched note record names accumulate WorkIDs for catalog recovery")
    func mailboxObservesNoteWorkIDsFromRecordNames() {
        let mailbox = CloudKitNotePendingMailbox()
        let workName = CloudKitSyncRecordNames.noteEntity(.work(cloudTestWorkID))
        mailbox.recordObservedNoteWorkIDs(fromRecordNames: [workName, "not-a-note"])
        #expect(mailbox.observedNoteWorkIDs() == [cloudTestWorkID])
        mailbox.clearObservedNoteWorkIDs()
        #expect(mailbox.observedNoteWorkIDs().isEmpty)
    }
}

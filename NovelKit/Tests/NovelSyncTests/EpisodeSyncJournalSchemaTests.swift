import Foundation
import NovelSync
import Testing

extension SyncCodableAndDigestTests {
    @Test("journal v2 golden fixture fixes portable working-copy and detached revision fields")
    func journalV2GoldenFixture() throws {
        let url = try #require(
            Bundle.module.url(forResource: "episode-sync-journal-v2", withExtension: "json")
        )
        let data = try Data(contentsOf: url)
        let record = try FileEpisodeSyncJournal.makeDecoder().decode(
            EpisodeSyncJournalRecord.self,
            from: data
        )

        #expect(record.schemaVersion == 2)
        #expect(record.protocolVersion == 1)
        #expect(record.localWorkingCopyID == SyncTestValues.localWorkingCopyID)
        #expect(record.replicaID == SyncTestValues.replicaA)
        #expect(record.branchID == SyncTestValues.branchID)
        #expect(record.localHead.content == "本文\n😀\n続き")
        #expect(record.localHead.parentRevisionIDs == [record.lastKnownRemoteHead?.revisionID])
        #expect(record.remoteConfirmation == .unconfirmed)
        #expect(record.localEditIntent == .explicit)
        #expect(record.reconciliationStatus == .pending)

        let encoded = try FileEpisodeSyncJournal.makeEncoder().encode(record)
        #expect(try jsonObject(from: encoded) == jsonObject(from: data))
    }

    @Test("journal pending cap is enforced while decoding app-private data")
    func journalPendingDecodeCap() throws {
        let revision = try SyncTestValues.revision(
            id: "66666666-6666-6666-6666-666666666693",
            parents: [],
            content: "wire"
        )
        let record = try EpisodeSyncJournalRecord(
            key: SyncTestValues.key,
            localWorkingCopyID: SyncTestValues.localWorkingCopyID,
            branchID: SyncTestValues.branchID,
            lastKnownRemoteHead: revision,
            localHead: revision
        )
        var object = try #require(
            jsonObject(from: FileEpisodeSyncJournal.makeEncoder().encode(record)) as? [String: Any]
        )
        let template = try #require(object["localHead"])
        object["pendingRevisions"] = (
            0 ... EpisodeSyncJournalRecord.maximumPendingRevisionCount
        ).map { _ in template }
        let data = try JSONSerialization.data(withJSONObject: object)
        #expect(throws: EpisodeSyncJournalError.self) {
            _ = try JSONDecoder().decode(EpisodeSyncJournalRecord.self, from: data)
        }
    }

    @Test("journal rejects duplicate pending revision IDs")
    func journalRejectsDuplicatePendingIDs() throws {
        let history = try makeMaterializationHistory()
        let valid = try EpisodeSyncJournalRecord(
            key: SyncTestValues.key,
            localWorkingCopyID: SyncTestValues.localWorkingCopyID,
            branchID: SyncTestValues.branchID,
            lastKnownRemoteHead: history.base,
            localHead: history.working,
            pendingRevisions: [history.working]
        )
        var object = try #require(
            jsonObject(from: FileEpisodeSyncJournal.makeEncoder().encode(valid)) as? [String: Any]
        )
        let pending = try #require(object["pendingRevisions"] as? [Any])
        object["pendingRevisions"] = [pending[0], pending[0]]
        let data = try JSONSerialization.data(withJSONObject: object)
        #expect(throws: EpisodeSyncJournalError.self) {
            _ = try FileEpisodeSyncJournal.makeDecoder().decode(
                EpisodeSyncJournalRecord.self,
                from: data
            )
        }
    }

    @Test("journal rejects a materialization head absent from the pending graph")
    func journalRejectsUnattestedMaterializationHead() throws {
        let history = try makeMaterializationHistory()
        #expect(throws: EpisodeSyncJournalError.self) {
            _ = try EpisodeSyncJournalRecord(
                key: SyncTestValues.key,
                localWorkingCopyID: SyncTestValues.localWorkingCopyID,
                branchID: SyncTestValues.branchID,
                lastKnownRemoteHead: history.base,
                localHead: history.working,
                pendingMaterialization: EpisodePendingMaterialization(
                    workingRevisionID: history.working.revisionID,
                    integratedRevision: history.integrated
                ),
                localEditIntent: .explicit
            )
        }
    }

    @Test("journal rejects conflict and pending materialization together")
    func journalRejectsConflictWithPendingMaterialization() throws {
        let history = try makeMaterializationHistory()
        #expect(throws: EpisodeSyncJournalError.self) {
            _ = try EpisodeSyncJournalRecord(
                key: SyncTestValues.key,
                localWorkingCopyID: SyncTestValues.localWorkingCopyID,
                branchID: SyncTestValues.branchID,
                lastKnownRemoteHead: history.base,
                localHead: history.working,
                pendingRevisions: [history.working, history.integrated],
                conflict: EpisodeConflict(
                    base: history.base,
                    local: history.working,
                    remote: history.integrated
                ),
                pendingMaterialization: EpisodePendingMaterialization(
                    workingRevisionID: history.working.revisionID,
                    integratedRevision: history.integrated
                )
            )
        }
    }

    private struct MaterializationHistory {
        let base: EpisodeRevision
        let working: EpisodeRevision
        let integrated: EpisodeRevision
    }

    private func makeMaterializationHistory() throws -> MaterializationHistory {
        let base = try SyncTestValues.revision(
            id: "66666666-6666-6666-6666-666666666694",
            parents: [],
            content: "base"
        )
        let working = try SyncTestValues.revision(
            id: "66666666-6666-6666-6666-666666666695",
            parents: [base.revisionID],
            content: "working"
        )
        let integrated = try SyncTestValues.revision(
            id: "66666666-6666-6666-6666-666666666696",
            parents: [base.revisionID, working.revisionID],
            content: "integrated"
        )
        return MaterializationHistory(base: base, working: working, integrated: integrated)
    }
}

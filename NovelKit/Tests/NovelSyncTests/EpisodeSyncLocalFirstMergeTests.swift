import Foundation
import NovelSync
import NovelSyncTesting
import Testing

extension EpisodeSyncLocalFirstTests {
    @Test("first explicit edit publishes only local revisions, never the observed remote record")
    func firstExplicitEditBuildsPortablePendingAncestry() async throws {
        let server = InMemoryEpisodeSyncServer()
        let owner = makeCoordinator(
            server: server,
            journal: InMemoryEpisodeSyncJournal(),
            session: SyncTestValues.sessionA
        )
        _ = try await owner.link(
            localContent: "base",
            createdAt: SyncTestValues.date,
            leaseExpiresAt: SyncTestValues.expiry
        )
        let remote = try #require(await server.currentHead(for: SyncTestValues.key))

        let cleanJournal = InMemoryEpisodeSyncJournal()
        let clean = makeCoordinator(
            server: server,
            journal: cleanJournal,
            replica: SyncTestValues.replicaB,
            session: SyncTestValues.sessionB
        )
        _ = try await clean.observeRemoteBase(localContent: "base", createdAt: SyncTestValues.date)
        _ = try await clean.recordLocalEdit(
            "base+edit",
            createdAt: SyncTestValues.date.addingTimeInterval(1)
        )
        let cleanRecord = try #require(await cleanJournal.storedRecord(for: SyncTestValues.key))
        #expect(cleanRecord.pendingRevisions.count == 1)
        #expect(cleanRecord.pendingRevisions[0].parentRevisionIDs == [remote.revisionID])

        let divergentJournal = InMemoryEpisodeSyncJournal()
        let divergent = makeCoordinator(
            server: server,
            journal: divergentJournal,
            replica: SyncTestValues.replicaB,
            session: SyncEditSessionID()
        )
        _ = try await divergent.observeRemoteBase(
            localContent: "package snapshot",
            createdAt: SyncTestValues.date
        )
        _ = try await divergent.recordLocalEdit(
            "package snapshot+edit",
            createdAt: SyncTestValues.date.addingTimeInterval(1)
        )
        let divergentRecord = try #require(
            await divergentJournal.storedRecord(for: SyncTestValues.key)
        )
        #expect(divergentRecord.pendingRevisions.count == 2)
        #expect(divergentRecord.pendingRevisions[0].content == "package snapshot")
        #expect(divergentRecord.pendingRevisions[1].parentRevisionIDs == [
            divergentRecord.pendingRevisions[0].revisionID
        ])
    }

    @Test("same resulting digest collapses silently without taking the writer lease")
    func sameDigestCollapsesWithoutTakeover() async throws {
        let setup = try await makeDivergedPair(
            localContent: "同じ結果",
            remoteContent: "同じ結果"
        )
        let epoch = await setup.server.currentLeaseEpoch(for: SyncTestValues.key)
        let state = try await setup.follower.synchronizeLocalFirst(
            expiresAt: SyncTestValues.expiry,
            createdAt: SyncTestValues.date.addingTimeInterval(2)
        )
        #expect(syncContext(from: state)?.pendingRevisionCount == 0)
        #expect(syncContext(from: state)?.remoteConfirmation == .confirmed)
        #expect(await setup.server.currentLeaseEpoch(for: SyncTestValues.key) == epoch)
    }

    @Test("non-overlapping edits auto merge as a two-parent head and await safe materialization")
    func nonOverlappingEditsAutoMerge() async throws {
        let setup = try await makeDivergedPair(
            baseContent: "甲\n乙\n",
            localContent: "甲L\n乙\n",
            remoteContent: "甲\n乙R\n"
        )
        let state = try await setup.follower.synchronizeLocalFirst(
            expiresAt: SyncTestValues.expiry,
            createdAt: SyncTestValues.date.addingTimeInterval(3)
        )
        let remote = try #require(await setup.server.currentHead(for: SyncTestValues.key))
        let materialization = try #require(syncContext(from: state)?.pendingMaterialization)
        #expect(remote.content == "甲L\n乙R\n")
        #expect(remote.parentRevisionIDs.count == 2)
        #expect(syncContext(from: state)?.localHead.content == "甲L\n乙\n")
        #expect(materialization.integratedRevision == remote)

        let materialized = try await setup.follower.confirmIntegratedContentMaterialized(
            materialization,
            installedContentDigest: materialization.integratedRevision.contentDigest
        )
        #expect(syncContext(from: materialized)?.localHead == remote)
        #expect(syncContext(from: materialized)?.remoteConfirmation == .confirmed)
    }

    @Test("an edit before materialization rebases onto the integrated body without dropping remote text")
    func editBeforeMaterializationPreservesBothSides() async throws {
        let setup = try await makeDivergedPair(
            baseContent: "甲\n乙\n",
            localContent: "甲L\n乙\n",
            remoteContent: "甲\n乙R\n"
        )
        _ = try await setup.follower.synchronizeLocalFirst(
            expiresAt: SyncTestValues.expiry,
            createdAt: SyncTestValues.date.addingTimeInterval(3)
        )
        _ = try await setup.follower.recordLocalEdit(
            "甲L2\n乙\n",
            createdAt: SyncTestValues.date.addingTimeInterval(4)
        )
        _ = try await setup.follower.synchronizeLocalFirst(
            expiresAt: SyncTestValues.expiry,
            createdAt: SyncTestValues.date.addingTimeInterval(5)
        )
        #expect(await setup.server.currentHead(for: SyncTestValues.key)?.content == "甲L2\n乙R\n")
    }

    @Test("an overlapping edit before materialization remains durable as review state")
    func overlapBeforeMaterializationIsDurable() async throws {
        let setup = try await makeDivergedPair(
            baseContent: "abcde",
            localContent: "abXde",
            remoteContent: "abcdY"
        )
        _ = try await setup.follower.synchronizeLocalFirst(
            expiresAt: SyncTestValues.expiry,
            createdAt: SyncTestValues.date.addingTimeInterval(3)
        )
        let receipt = try await setup.follower.recordLocalEdit(
            "abXdQ",
            createdAt: SyncTestValues.date.addingTimeInterval(4)
        )
        let record = try #require(await setup.journal.storedRecord(for: SyncTestValues.key))
        #expect(record.localHead.revisionID == receipt.revisionID)
        #expect(record.conflict?.local.content == "abXdQ")
        #expect(record.conflict?.remote.content == "abXdY")
        #expect(record.pendingMaterialization == nil)
        #expect(record.reconciliationStatus == .reviewRequired)
    }

    @Test("overlap preserves base, both bodies, review draft, and later local edits")
    func overlapPreservesReviewStateAndContinuesEditing() async throws {
        let setup = try await makeDivergedPair(
            localContent: "aXc",
            remoteContent: "aYc"
        )
        let state = try await setup.follower.synchronizeLocalFirst(
            expiresAt: SyncTestValues.expiry,
            createdAt: SyncTestValues.date.addingTimeInterval(3)
        )
        let conflict = try #require(syncConflict(from: state))
        let draft = try #require(await setup.follower.integrationReviewDraft)
        #expect(conflict.base?.content == "abc")
        #expect(conflict.local.content == "aXc")
        #expect(conflict.remote.content == "aYc")
        #expect(draft.reason == .overlappingChanges)

        _ = try await setup.follower.recordLocalEdit(
            "aXZc",
            createdAt: SyncTestValues.date.addingTimeInterval(4)
        )
        let preserved = try #require(await setup.journal.storedRecord(for: SyncTestValues.key))
        #expect(preserved.conflict?.local.content == "aXZc")
        #expect(preserved.conflict?.remote.content == "aYc")
        #expect(preserved.integrationReviewDraft?.localRevisionID == preserved.localHead.revisionID)
    }

    @Test("review draft includes every safe hunk around an unresolved overlap")
    func conflictDraftIncludesNonOverlappingHunks() async throws {
        let setup = try await makeDivergedPair(
            baseContent: "甲\n乙\n丙\n丁\n戊\n",
            localContent: "甲L\n乙\n狼LOCAL\n丁\n戊L\n",
            remoteContent: "甲\n乙R\n猫REMOTE\n丁R\n戊\n"
        )
        let state = try await setup.follower.synchronizeLocalFirst(
            expiresAt: SyncTestValues.expiry,
            createdAt: SyncTestValues.date.addingTimeInterval(3)
        )
        #expect(syncConflict(from: state) != nil)
        #expect(
            await setup.follower.integrationReviewDraft?.proposedContent
                == "甲L\n乙R\n狼LOCAL\n丁R\n戊L\n"
        )
    }
}

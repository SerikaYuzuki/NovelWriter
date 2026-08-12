import Foundation
import NovelSync
import NovelSyncTesting
import Testing

extension EpisodeSyncLocalFirstTests {
    @Test("a second conflict resolution retains the complete unpublished ancestry across restart")
    // This end-to-end graph must expose every revision at each durability boundary.
    // swiftlint:disable:next function_body_length
    func repeatedConflictResolutionRetainsUnpublishedAncestry() async throws {
        let server = InMemoryEpisodeSyncServer()
        let owner = makeCoordinator(
            server: server,
            journal: InMemoryEpisodeSyncJournal(),
            session: SyncTestValues.sessionA
        )
        _ = try await owner.link(
            localContent: "B remote",
            createdAt: SyncTestValues.date,
            leaseExpiresAt: SyncTestValues.expiry
        )
        let remoteB = try #require(await server.currentHead(for: SyncTestValues.key))

        let localBranch = SyncBranchID()
        let localA = try EpisodeRevision(
            key: SyncTestValues.key,
            parentRevisionIDs: [],
            branchID: localBranch,
            authorReplicaID: SyncTestValues.replicaB,
            authorSessionID: SyncTestValues.sessionB,
            content: "A local fork",
            clientCreatedAt: SyncTestValues.date.addingTimeInterval(1)
        )
        let packageAhead = try EpisodeRevision(
            key: SyncTestValues.key,
            parentRevisionIDs: [localA.revisionID],
            branchID: localBranch,
            authorReplicaID: SyncTestValues.replicaB,
            authorSessionID: SyncTestValues.sessionB,
            content: "X package-ahead",
            clientCreatedAt: SyncTestValues.date.addingTimeInterval(2)
        )
        let firstConflict = EpisodeConflict(base: nil, local: packageAhead, remote: remoteB)
        let journal = InMemoryEpisodeSyncJournal()
        try await journal.save(
            EpisodeSyncJournalRecord(
                key: SyncTestValues.key,
                localWorkingCopyID: SyncTestValues.localWorkingCopyID,
                replicaID: SyncTestValues.replicaB,
                branchID: localBranch,
                lastKnownRemoteHead: remoteB,
                localHead: packageAhead,
                pendingRevisions: [localA, packageAhead],
                conflict: firstConflict,
                mode: .forcedFork
            )
        )
        let follower = makeCoordinator(
            server: server,
            journal: journal,
            replica: SyncTestValues.replicaB,
            session: SyncTestValues.sessionB
        )
        _ = try await follower.restore()
        let firstChoice = try await follower.stageConflictResolutionLocalFirst(
            expectedConflict: firstConflict,
            choice: .keepLocal,
            createdAt: SyncTestValues.date.addingTimeInterval(3)
        )
        _ = try await follower.confirmStagedConflictResolutionMaterialized(
            firstChoice,
            installedContentDigest: firstChoice.chosenRevision.contentDigest
        )
        #expect(await journal.storedRecord(for: SyncTestValues.key)?.pendingRevisions == [
            localA,
            packageAhead,
            firstChoice.chosenRevision
        ])

        _ = try await owner.recordLocalContent(
            "C raced remote",
            createdAt: SyncTestValues.date.addingTimeInterval(4)
        )
        _ = try await owner.synchronize()
        let remoteC = try #require(await server.currentHead(for: SyncTestValues.key))
        let returnedToReview = try await follower.synchronizeLocalFirst(
            expiresAt: SyncTestValues.expiry,
            createdAt: SyncTestValues.date.addingTimeInterval(5)
        )
        let secondConflict = try #require(syncConflict(from: returnedToReview))
        #expect(secondConflict.local == firstChoice.chosenRevision)
        #expect(secondConflict.remote == remoteC)
        #expect(await journal.storedRecord(for: SyncTestValues.key)?.pendingRevisions == [
            localA,
            packageAhead,
            firstChoice.chosenRevision
        ])

        let restarted = makeCoordinator(
            server: server,
            journal: journal,
            replica: SyncTestValues.replicaB,
            session: SyncEditSessionID()
        )
        _ = try await restarted.restore()
        let secondChoice = try await restarted.stageConflictResolutionLocalFirst(
            expectedConflict: secondConflict,
            choice: .keepLocal,
            createdAt: SyncTestValues.date.addingTimeInterval(6)
        )
        _ = try await restarted.confirmStagedConflictResolutionMaterialized(
            secondChoice,
            installedContentDigest: secondChoice.chosenRevision.contentDigest
        )
        let materialized = try #require(await journal.storedRecord(for: SyncTestValues.key))
        #expect(materialized.pendingRevisions == [
            localA,
            packageAhead,
            firstChoice.chosenRevision,
            secondChoice.chosenRevision
        ])
        #expect(secondChoice.chosenRevision.parentRevisionIDs == [
            remoteC.revisionID,
            firstChoice.chosenRevision.revisionID
        ])

        let publishSession = SyncEditSessionID()
        let publishRestart = makeCoordinator(
            server: server,
            journal: journal,
            replica: SyncTestValues.replicaB,
            session: publishSession
        )
        _ = try await publishRestart.restore()
        _ = try await publishRestart.synchronizeLocalFirst(
            expiresAt: SyncTestValues.expiry,
            createdAt: SyncTestValues.date.addingTimeInterval(7)
        )
        let relay = try #require(await server.currentHead(for: SyncTestValues.key))
        #expect(relay.content == secondChoice.chosenRevision.content)
        #expect(relay.parentRevisionIDs == [secondChoice.chosenRevision.revisionID])
        #expect(relay.authorReplicaID == SyncTestValues.replicaB)
        #expect(relay.authorSessionID == publishSession)
        let published = try await server.fetchRevision(
            secondChoice.chosenRevision.revisionID,
            for: SyncTestValues.key
        )
        #expect(published.parentRevisionIDs == [
            remoteC.revisionID,
            firstChoice.chosenRevision.revisionID
        ])
        let acknowledged = try #require(await journal.storedRecord(for: SyncTestValues.key))
        #expect(acknowledged.pendingRevisions.isEmpty)
        #expect(acknowledged.conflict == nil)
        #expect(acknowledged.stagedConflictResolution == nil)
        #expect(acknowledged.conflictResolutionRecovery == nil)
    }
}

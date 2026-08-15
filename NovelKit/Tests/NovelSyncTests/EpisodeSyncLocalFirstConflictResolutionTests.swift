import Foundation
import NovelSync
import NovelSyncTesting
import Testing

extension EpisodeSyncLocalFirstTests {
    @Test("conflict choice is materialized locally before exact two-parent publish")
    func conflictResolutionIsPackageFirstAndRetainsExactParents() async throws {
        let setup = try await makeDivergedPair(localContent: "aXc", remoteContent: "aYc")
        let conflicted = try await setup.follower.synchronizeLocalFirst(
            expiresAt: SyncTestValues.expiry,
            createdAt: SyncTestValues.date.addingTimeInterval(3)
        )
        let conflict = try #require(syncConflict(from: conflicted))
        let fetchesBeforeStage = await setup.server.snapshotFetchInvocationCount()
        let materialization = try await setup.follower.stageConflictResolutionLocalFirst(
            expectedConflict: conflict,
            choice: .manual(content: "aZc"),
            createdAt: SyncTestValues.date.addingTimeInterval(4)
        )
        #expect(await setup.server.snapshotFetchInvocationCount() == fetchesBeforeStage)
        #expect(await setup.server.currentHead(for: SyncTestValues.key) == conflict.remote)
        #expect(materialization.chosenRevision.parentRevisionIDs == [
            conflict.remote.revisionID,
            conflict.local.revisionID
        ])

        _ = try await setup.follower.synchronizeLocalFirst(
            expiresAt: SyncTestValues.expiry,
            createdAt: SyncTestValues.date.addingTimeInterval(5)
        )
        #expect(await setup.server.snapshotFetchInvocationCount() == fetchesBeforeStage)
        _ = try await setup.follower.confirmStagedConflictResolutionMaterialized(
            materialization,
            installedContentDigest: materialization.chosenRevision.contentDigest
        )
        let recovery = try #require(await setup.follower.conflictResolutionRecovery)
        #expect(recovery.sourceLocalRevision == conflict.local)
        #expect(recovery.sourceRemoteRevision == conflict.remote)
        #expect(recovery.chosenRevision == materialization.chosenRevision)

        let restarted = makeCoordinator(
            server: setup.server,
            journal: setup.journal,
            replica: SyncTestValues.replicaB,
            session: SyncEditSessionID()
        )
        _ = try await restarted.restore()
        #expect(await restarted.conflictResolutionRecovery == recovery)
        _ = try await restarted.synchronizeLocalFirst(
            expiresAt: SyncTestValues.expiry,
            createdAt: SyncTestValues.date.addingTimeInterval(6)
        )
        let chosen = try await setup.server.fetchRevision(
            materialization.chosenRevision.revisionID,
            for: SyncTestValues.key
        )
        #expect(chosen.parentRevisionIDs == [conflict.remote.revisionID, conflict.local.revisionID])
        #expect(await setup.server.currentHead(for: SyncTestValues.key)?.content == "aZc")
        #expect(await restarted.conflictResolutionRecovery == nil)
    }

    @Test("remote advance during conflict claim retains both sources and the chosen draft")
    func conflictResolutionRemoteAdvanceReturnsToReview() async throws {
        let review = try await makeSupersededResolutionReview()
        let setup = review.setup
        let currentConflict = review.currentConflict
        let restarted = review.restarted
        let finalChoice = try await restarted.stageConflictResolutionLocalFirst(
            expectedConflict: currentConflict,
            choice: .manual(content: "aFinalc"),
            createdAt: SyncTestValues.date.addingTimeInterval(8)
        )
        let restaged = makeCoordinator(
            server: setup.server,
            journal: setup.journal,
            replica: SyncTestValues.replicaB,
            session: SyncEditSessionID()
        )
        _ = try await restaged.restore()
        #expect(await restaged.conflictChoiceAwaitingMaterialization == finalChoice)
        #expect(await restaged.conflictResolutionRecovery?.chosenRevision.content == "aZc")
        _ = try await restaged.confirmStagedConflictResolutionMaterialized(
            finalChoice,
            installedContentDigest: finalChoice.chosenRevision.contentDigest
        )
        #expect(await restaged.conflictResolutionRecovery?.supersededChosenRevision?.content == "aZc")
        let confirmedRestart = makeCoordinator(
            server: setup.server,
            journal: setup.journal,
            replica: SyncTestValues.replicaB,
            session: SyncEditSessionID()
        )
        _ = try await confirmedRestart.restore()
        #expect(await confirmedRestart.conflictResolutionRecovery?.chosenRevision == finalChoice.chosenRevision)
        #expect(await confirmedRestart.conflictResolutionRecovery?.supersededChosenRevision?.content == "aZc")
        _ = try await confirmedRestart.synchronizeLocalFirst(
            expiresAt: SyncTestValues.expiry,
            createdAt: SyncTestValues.date.addingTimeInterval(9)
        )
        let publishedChoice = try await setup.server.fetchRevision(
            finalChoice.chosenRevision.revisionID,
            for: SyncTestValues.key
        )
        #expect(publishedChoice.parentRevisionIDs == [
            currentConflict.remote.revisionID,
            currentConflict.local.revisionID
        ])
        #expect(await setup.server.currentHead(for: SyncTestValues.key)?.content == "aFinalc")
        #expect(await confirmedRestart.conflictResolutionRecovery == nil)
    }

    private struct SupersededResolutionReview {
        let setup: DivergedPair
        let currentConflict: EpisodeConflict
        let restarted: EpisodeSyncCoordinator
    }

    private func makeSupersededResolutionReview() async throws -> SupersededResolutionReview {
        let setup = try await makeDivergedPair(localContent: "aXc", remoteContent: "aYc")
        let conflicted = try await setup.follower.synchronizeLocalFirst(
            expiresAt: SyncTestValues.expiry,
            createdAt: SyncTestValues.date.addingTimeInterval(3)
        )
        let conflict = try #require(syncConflict(from: conflicted))
        let materialization = try await setup.follower.stageConflictResolutionLocalFirst(
            expectedConflict: conflict,
            choice: .manual(content: "aZc"),
            createdAt: SyncTestValues.date.addingTimeInterval(4)
        )
        _ = try await setup.follower.confirmStagedConflictResolutionMaterialized(
            materialization,
            installedContentDigest: materialization.chosenRevision.contentDigest
        )
        try await advanceRemoteDuringPausedClaim(setup)
        _ = try await setup.follower.recordLocalEdit(
            "aXc3",
            createdAt: SyncTestValues.date.addingTimeInterval(7)
        )
        let restarted = makeCoordinator(
            server: setup.server,
            journal: setup.journal,
            replica: SyncTestValues.replicaB,
            session: SyncEditSessionID()
        )
        _ = try await restarted.restore()
        let preserved = try #require(await setup.journal.storedRecord(for: SyncTestValues.key))
        try expectSupersededRecovery(preserved, originalConflict: conflict)
        return try SupersededResolutionReview(
            setup: setup,
            currentConflict: #require(preserved.conflict),
            restarted: restarted
        )
    }

    private func advanceRemoteDuringPausedClaim(_ setup: DivergedPair) async throws {
        await setup.server.pauseNextClaim()
        let resolving = Task {
            try await setup.follower.synchronizeLocalFirst(
                expiresAt: SyncTestValues.expiry,
                createdAt: SyncTestValues.date.addingTimeInterval(5)
            )
        }
        await setup.server.waitUntilClaimIsPaused()
        _ = try await setup.owner.recordLocalContent(
            "aYc2",
            createdAt: SyncTestValues.date.addingTimeInterval(6)
        )
        _ = try await setup.owner.synchronize()
        await setup.server.resumePausedClaim()
        _ = try await resolving.value
    }

    private func expectSupersededRecovery(
        _ record: EpisodeSyncJournalRecord,
        originalConflict: EpisodeConflict
    ) throws {
        let recovery = try #require(record.conflictResolutionRecovery)
        #expect(recovery.sourceLocalRevision == originalConflict.local)
        #expect(recovery.sourceRemoteRevision == originalConflict.remote)
        #expect(recovery.chosenRevision.content == "aZc")
        #expect(record.conflict?.local.content == "aXc3")
        #expect(record.conflict?.remote.content == "aYc2")
        #expect(record.pendingMaterialization == nil)
        #expect(record.reconciliationStatus == .reviewRequired)
    }

    @Test("a staged conflict choice survives termination and waits for package acknowledgement")
    func stagedConflictResolutionResumesAfterRestart() async throws {
        let setup = try await makeDivergedPair(localContent: "aXc", remoteContent: "aYc")
        let conflicted = try await setup.follower.synchronizeLocalFirst(
            expiresAt: SyncTestValues.expiry,
            createdAt: SyncTestValues.date.addingTimeInterval(3)
        )
        let conflict = try #require(syncConflict(from: conflicted))
        let materialization = try await setup.follower.stageConflictResolutionLocalFirst(
            expectedConflict: conflict,
            choice: .manual(content: "aZc"),
            createdAt: SyncTestValues.date.addingTimeInterval(4)
        )
        let staged = try #require(await setup.journal.storedRecord(for: SyncTestValues.key))
        #expect(staged.stagedConflictResolution?.content == "aZc")
        #expect(staged.conflict == conflict)

        let restarted = makeCoordinator(
            server: setup.server,
            journal: setup.journal,
            replica: SyncTestValues.replicaB,
            session: SyncEditSessionID()
        )
        _ = try await restarted.restore()
        #expect(await restarted.conflictChoiceAwaitingMaterialization == materialization)
        _ = try await restarted.synchronizeLocalFirst(
            expiresAt: SyncTestValues.expiry,
            createdAt: SyncTestValues.date.addingTimeInterval(5)
        )
        #expect(await setup.server.currentHead(for: SyncTestValues.key) == conflict.remote)
        _ = try await restarted.confirmStagedConflictResolutionMaterialized(
            materialization,
            installedContentDigest: materialization.chosenRevision.contentDigest
        )
        #expect(await restarted.conflictResolutionRecovery?.chosenRevision.content == "aZc")
    }

    @Test("offline publish after package acknowledgement retains all recovery bodies until remote ack")
    func conflictRecoverySurvivesOfflinePublishAndRestart() async throws {
        let setup = try await makeDivergedPair(localContent: "aXc", remoteContent: "aYc")
        let conflicted = try await setup.follower.synchronizeLocalFirst(
            expiresAt: SyncTestValues.expiry,
            createdAt: SyncTestValues.date.addingTimeInterval(3)
        )
        let conflict = try #require(syncConflict(from: conflicted))
        let materialization = try await setup.follower.stageConflictResolutionLocalFirst(
            expectedConflict: conflict,
            choice: .manual(content: "aZc"),
            createdAt: SyncTestValues.date.addingTimeInterval(4)
        )
        _ = try await setup.follower.confirmStagedConflictResolutionMaterialized(
            materialization,
            installedContentDigest: materialization.chosenRevision.contentDigest
        )
        await setup.server.setOnline(false)
        _ = try await setup.follower.synchronizeLocalFirst(
            expiresAt: SyncTestValues.expiry,
            createdAt: SyncTestValues.date.addingTimeInterval(5)
        )

        let restarted = makeCoordinator(
            server: setup.server,
            journal: setup.journal,
            replica: SyncTestValues.replicaB,
            session: SyncEditSessionID()
        )
        _ = try await restarted.restore()
        let recovery = try #require(await restarted.conflictResolutionRecovery)
        #expect(recovery.sourceLocalRevision == conflict.local)
        #expect(recovery.sourceRemoteRevision == conflict.remote)
        #expect(recovery.chosenRevision == materialization.chosenRevision)

        await setup.server.setOnline(true)
        _ = try await restarted.synchronizeLocalFirst(
            expiresAt: SyncTestValues.expiry,
            createdAt: SyncTestValues.date.addingTimeInterval(6)
        )
        #expect(await setup.server.currentHead(for: SyncTestValues.key)?.content == "aZc")
        #expect(await restarted.conflictResolutionRecovery == nil)
    }

    @Test("edits after package conflict resolution remain children of the chosen merge")
    func conflictResolutionTailIsPublishedWithoutDroppingChosenBody() async throws {
        let setup = try await makeDivergedPair(localContent: "aXc", remoteContent: "aYc")
        let conflicted = try await setup.follower.synchronizeLocalFirst(
            expiresAt: SyncTestValues.expiry,
            createdAt: SyncTestValues.date.addingTimeInterval(3)
        )
        let conflict = try #require(syncConflict(from: conflicted))
        let materialization = try await setup.follower.stageConflictResolutionLocalFirst(
            expectedConflict: conflict,
            choice: .manual(content: "aZc"),
            createdAt: SyncTestValues.date.addingTimeInterval(4)
        )
        _ = try await setup.follower.confirmStagedConflictResolutionMaterialized(
            materialization,
            installedContentDigest: materialization.chosenRevision.contentDigest
        )
        let tail = try await setup.follower.recordLocalEdit(
            "aZc tail",
            createdAt: SyncTestValues.date.addingTimeInterval(5)
        )
        let queued = try #require(await setup.journal.storedRecord(for: SyncTestValues.key))
        #expect(queued.pendingRevisions.contains(materialization.chosenRevision))
        #expect(queued.localHead.parentRevisionIDs == [materialization.chosenRevision.revisionID])
        #expect(queued.localHead.revisionID == tail.revisionID)

        _ = try await setup.follower.synchronizeLocalFirst(
            expiresAt: SyncTestValues.expiry,
            createdAt: SyncTestValues.date.addingTimeInterval(6)
        )
        #expect(await setup.server.currentHead(for: SyncTestValues.key)?.content == "aZc tail")
        #expect(await setup.follower.conflictResolutionRecovery == nil)
    }
}

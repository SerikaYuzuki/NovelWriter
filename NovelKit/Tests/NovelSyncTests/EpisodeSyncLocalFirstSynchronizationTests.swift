import Foundation
import NovelSync
import NovelSyncTesting
import Testing

extension EpisodeSyncLocalFirstTests {
    @Test("unknown ancestry never auto merges or mutates the remote head")
    func unknownAncestryStaysForReview() async throws {
        let server = InMemoryEpisodeSyncServer()
        let owner = makeCoordinator(
            server: server,
            journal: InMemoryEpisodeSyncJournal(),
            session: SyncTestValues.sessionA
        )
        _ = try await owner.link(
            localContent: "remote",
            createdAt: SyncTestValues.date,
            leaseExpiresAt: SyncTestValues.expiry
        )
        let remote = try #require(await server.currentHead(for: SyncTestValues.key))

        let journal = InMemoryEpisodeSyncJournal()
        let detached = makeCoordinator(
            server: server,
            journal: journal,
            replica: SyncTestValues.replicaB,
            session: SyncTestValues.sessionB
        )
        _ = try await detached.recordLocalEdit("local", createdAt: SyncTestValues.date)
        let state = try await detached.synchronizeLocalFirst(
            expiresAt: SyncTestValues.expiry,
            createdAt: SyncTestValues.date.addingTimeInterval(1)
        )
        #expect(syncConflict(from: state)?.base == nil)
        #expect(await detached.integrationReviewDraft?.reason == .commonAncestorUnknown)
        #expect(await server.currentHead(for: SyncTestValues.key) == remote)
    }

    @Test("a local edit during a suspended merge claim is recomputed before publish")
    func editDuringClaimCannotPublishStaleMergedContent() async throws {
        let setup = try await makeDivergedPair(
            baseContent: "甲\n乙\n",
            localContent: "甲L1\n乙\n",
            remoteContent: "甲\n乙R\n"
        )
        await setup.server.pauseNextClaim()
        let syncing = Task {
            try await setup.follower.synchronizeLocalFirst(
                expiresAt: SyncTestValues.expiry,
                createdAt: SyncTestValues.date.addingTimeInterval(3)
            )
        }
        await setup.server.waitUntilClaimIsPaused()
        _ = try await setup.follower.recordLocalEdit(
            "甲L2\n乙\n",
            createdAt: SyncTestValues.date.addingTimeInterval(4)
        )
        await setup.server.resumePausedClaim()
        _ = try await syncing.value
        #expect(await setup.server.currentHead(for: SyncTestValues.key)?.content == "甲L2\n乙R\n")
    }

    @Test("one local-first synchronization drains edits added during upload")
    func uploadTailIsDrainedInSameSynchronization() async throws {
        let setup = try await makeDirectPublishPair(localContent: "first")

        await setup.server.pauseNextPublish()
        let syncing = Task {
            try await setup.follower.synchronizeLocalFirst(
                expiresAt: SyncTestValues.expiry,
                createdAt: SyncTestValues.date.addingTimeInterval(2)
            )
        }
        await setup.server.waitUntilPublishIsPaused()
        _ = try await setup.follower.recordLocalEdit(
            "second",
            createdAt: SyncTestValues.date.addingTimeInterval(3)
        )
        await setup.server.resumePausedPublish()
        let final = try await syncing.value
        #expect(await setup.server.currentHead(for: SyncTestValues.key)?.content == "second")
        #expect(syncContext(from: final)?.pendingRevisionCount == 0)
    }

    @Test("an edit during an unavailable claim remains durable after restart")
    func unavailableClaimCannotRollBackLocalTail() async throws {
        let setup = try await makeDivergedPair(
            baseContent: "甲\n乙\n",
            localContent: "甲L1\n乙\n",
            remoteContent: "甲\n乙R\n"
        )
        await setup.server.pauseNextClaim()
        let syncing = Task {
            try await setup.follower.synchronizeLocalFirst(
                expiresAt: SyncTestValues.expiry,
                createdAt: SyncTestValues.date.addingTimeInterval(3)
            )
        }
        await setup.server.waitUntilClaimIsPaused()
        _ = try await setup.follower.recordLocalEdit(
            "甲L2\n乙\n",
            createdAt: SyncTestValues.date.addingTimeInterval(4)
        )
        await setup.server.setOnline(false)
        await setup.server.resumePausedClaim()
        _ = try await syncing.value

        let restarted = makeCoordinator(
            server: setup.server,
            journal: setup.journal,
            replica: SyncTestValues.replicaB,
            session: SyncEditSessionID()
        )
        _ = try await restarted.restore()
        #expect(await syncContext(from: restarted.state)?.localHead.content == "甲L2\n乙\n")
    }

    @Test("an edit during an unavailable publish is replayed after restart")
    func unavailablePublishCannotRollBackLocalTail() async throws {
        let setup = try await makeDirectPublishPair(localContent: "first")
        await setup.server.pauseNextPublish()
        let syncing = Task {
            try await setup.follower.synchronizeLocalFirst(
                expiresAt: SyncTestValues.expiry,
                createdAt: SyncTestValues.date.addingTimeInterval(2)
            )
        }
        await setup.server.waitUntilPublishIsPaused()
        _ = try await setup.follower.recordLocalEdit(
            "second",
            createdAt: SyncTestValues.date.addingTimeInterval(3)
        )
        await setup.server.setOnline(false)
        await setup.server.resumePausedPublish()
        _ = try await syncing.value

        let restarted = makeCoordinator(
            server: setup.server,
            journal: setup.journal,
            replica: SyncTestValues.replicaB,
            session: SyncEditSessionID()
        )
        _ = try await restarted.restore()
        #expect(await syncContext(from: restarted.state)?.localHead.content == "second")
        await setup.server.setOnline(true)
        _ = try await restarted.synchronizeLocalFirst(
            expiresAt: SyncTestValues.expiry,
            createdAt: SyncTestValues.date.addingTimeInterval(4)
        )
        #expect(await setup.server.currentHead(for: SyncTestValues.key)?.content == "second")
    }

    struct DivergedPair {
        let server: InMemoryEpisodeSyncServer
        let owner: EpisodeSyncCoordinator
        let follower: EpisodeSyncCoordinator
        let journal: InMemoryEpisodeSyncJournal
    }

    func makeCleanRemoteAdvance(
        baseContent: String,
        remoteContent: String
    ) async throws -> DivergedPair {
        let server = InMemoryEpisodeSyncServer()
        let owner = makeCoordinator(
            server: server,
            journal: InMemoryEpisodeSyncJournal(),
            session: SyncTestValues.sessionA
        )
        _ = try await owner.link(
            localContent: baseContent,
            createdAt: SyncTestValues.date,
            leaseExpiresAt: SyncTestValues.expiry
        )
        let journal = InMemoryEpisodeSyncJournal()
        let follower = makeCoordinator(
            server: server,
            journal: journal,
            replica: SyncTestValues.replicaB,
            session: SyncTestValues.sessionB
        )
        _ = try await follower.observeRemoteBase(
            localContent: baseContent,
            createdAt: SyncTestValues.date
        )
        _ = try await owner.recordLocalContent(
            remoteContent,
            createdAt: SyncTestValues.date.addingTimeInterval(1)
        )
        _ = try await owner.synchronize()
        _ = try await follower.observeRemoteBase(
            localContent: baseContent,
            createdAt: SyncTestValues.date.addingTimeInterval(2)
        )
        return DivergedPair(server: server, owner: owner, follower: follower, journal: journal)
    }

    func makeDivergedPair(
        baseContent: String = "abc",
        localContent: String,
        remoteContent: String
    ) async throws -> DivergedPair {
        let server = InMemoryEpisodeSyncServer()
        let owner = makeCoordinator(
            server: server,
            journal: InMemoryEpisodeSyncJournal(),
            session: SyncTestValues.sessionA
        )
        _ = try await owner.link(
            localContent: baseContent,
            createdAt: SyncTestValues.date,
            leaseExpiresAt: SyncTestValues.expiry
        )
        let journal = InMemoryEpisodeSyncJournal()
        let follower = makeCoordinator(
            server: server,
            journal: journal,
            replica: SyncTestValues.replicaB,
            session: SyncTestValues.sessionB
        )
        _ = try await follower.observeRemoteBase(
            localContent: baseContent,
            createdAt: SyncTestValues.date
        )
        _ = try await follower.recordLocalEdit(
            localContent,
            createdAt: SyncTestValues.date.addingTimeInterval(1)
        )
        _ = try await owner.recordLocalContent(
            remoteContent,
            createdAt: SyncTestValues.date.addingTimeInterval(1)
        )
        _ = try await owner.synchronize()
        return DivergedPair(server: server, owner: owner, follower: follower, journal: journal)
    }

    func makeDirectPublishPair(localContent: String) async throws -> DivergedPair {
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
        let journal = InMemoryEpisodeSyncJournal()
        let follower = makeCoordinator(
            server: server,
            journal: journal,
            replica: SyncTestValues.replicaB,
            session: SyncTestValues.sessionB
        )
        _ = try await follower.observeRemoteBase(
            localContent: "base",
            createdAt: SyncTestValues.date
        )
        _ = try await follower.recordLocalEdit(
            localContent,
            createdAt: SyncTestValues.date.addingTimeInterval(1)
        )
        return DivergedPair(server: server, owner: owner, follower: follower, journal: journal)
    }

    func makeCoordinator(
        server: InMemoryEpisodeSyncServer,
        journal: InMemoryEpisodeSyncJournal,
        replica: SyncReplicaID = SyncTestValues.replicaA,
        session: SyncEditSessionID
    ) -> EpisodeSyncCoordinator {
        EpisodeSyncCoordinator(
            key: SyncTestValues.key,
            localWorkingCopyID: SyncTestValues.localWorkingCopyID,
            replicaID: replica,
            sessionID: session,
            transport: server,
            journal: journal
        )
    }
}

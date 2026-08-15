import Foundation
import NovelSync
import NovelSyncTesting
import Testing

// swiftlint:disable function_body_length
extension EpisodeSyncCoordinatorTests {
    @Test("local change during an awaited publish survives acknowledgement and is sent next")
    func publishReentrancyPreservesTail() async throws {
        let server = InMemoryEpisodeSyncServer()
        let coordinator = makeCoordinator(
            server: server,
            journal: InMemoryEpisodeSyncJournal(),
            replica: SyncTestValues.replicaA,
            session: SyncTestValues.sessionA
        )
        _ = try await coordinator.link(
            localContent: "base",
            createdAt: SyncTestValues.date,
            leaseExpiresAt: SyncTestValues.expiry
        )
        _ = try await coordinator.recordLocalContent("first", createdAt: SyncTestValues.date.addingTimeInterval(1))
        await server.pauseNextPublish()
        let publishing = Task { try await coordinator.synchronize() }
        await server.waitUntilPublishIsPaused()
        _ = try await coordinator.recordLocalContent("second", createdAt: SyncTestValues.date.addingTimeInterval(2))
        await server.resumePausedPublish()
        let afterFirstPublish = try await publishing.value

        #expect(syncContext(from: afterFirstPublish)?.localHead.content == "second")
        #expect(syncContext(from: afterFirstPublish)?.pendingRevisionCount == 1)
        #expect(await server.currentHead(for: SyncTestValues.key)?.content == "first")
        _ = try await coordinator.synchronize()
        #expect(await server.currentHead(for: SyncTestValues.key)?.content == "second")
    }

    @Test("a captured fence snapshot cannot roll back a newer queued publish")
    func staleFenceSnapshotDoesNotRollBackNewerPublish() async throws {
        let server = InMemoryEpisodeSyncServer()
        let journal = InMemoryEpisodeSyncJournal()
        let coordinator = makeCoordinator(
            server: server,
            journal: journal,
            replica: SyncTestValues.replicaA,
            session: SyncTestValues.sessionA
        )
        _ = try await coordinator.link(
            localContent: "R0",
            createdAt: SyncTestValues.date,
            leaseExpiresAt: SyncTestValues.expiry
        )

        await server.pauseNextSnapshotResponseAfterCapture()
        let inspecting = Task { try await coordinator.inspectFence() }
        await server.waitUntilSnapshotResponseIsPaused()

        _ = try await coordinator.recordLocalContent(
            "R1",
            createdAt: SyncTestValues.date.addingTimeInterval(1)
        )
        let publishing = Task { try await coordinator.synchronize() }
        await Task.yield()
        #expect(await server.currentHead(for: SyncTestValues.key)?.content == "R0")

        await server.resumePausedSnapshotResponse()
        let observation = try await inspecting.value
        guard case let .authorityValid(snapshot) = observation else {
            Issue.record("the stale observation was applied after a newer local generation")
            return
        }
        #expect(snapshot.head?.content == "R0")

        let final = try await publishing.value
        guard case let .upToDate(context) = final else {
            Issue.record("the queued publish did not finish at the newest revision")
            return
        }
        #expect(context.localHead.content == "R1")
        #expect(await server.currentHead(for: SyncTestValues.key)?.content == "R1")
        #expect(await journal.storedRecord(for: SyncTestValues.key)?.localHead.content == "R1")
    }

    @Test("lost response retry acknowledges old commit but never revives its stale lease or head")
    func lostResponseRetryUsesCurrentSnapshot() async throws {
        let server = InMemoryEpisodeSyncServer()
        let mac = makeCoordinator(
            server: server,
            journal: InMemoryEpisodeSyncJournal(),
            replica: SyncTestValues.replicaA,
            session: SyncTestValues.sessionA
        )
        _ = try await mac.link(
            localContent: "base",
            createdAt: SyncTestValues.date,
            leaseExpiresAt: SyncTestValues.expiry
        )
        _ = try await mac.recordLocalContent("mac committed", createdAt: SyncTestValues.date.addingTimeInterval(0.75))
        await server.loseNextPublishResponseAfterCommit()
        let lost = try await mac.synchronize()
        guard case .offlineFork = lost else {
            Issue.record("response loss did not preserve the local sealed mutation")
            return
        }

        let phone = makeCoordinator(
            server: server,
            journal: InMemoryEpisodeSyncJournal(),
            replica: SyncTestValues.replicaB,
            session: SyncTestValues.sessionB
        )
        _ = try await phone.link(
            localContent: "mac committed",
            createdAt: SyncTestValues.date,
            leaseExpiresAt: SyncTestValues.expiry
        )
        let phoneGrant = try await phone.prepareForcedContinuation(expiresAt: SyncTestValues.expiry)
        _ = try await phone.confirmAuthorityInstall(
            phoneGrant,
            installedRemoteDigest: phoneGrant.snapshot.head?.contentDigest
        )
        _ = try await phone.recordLocalContent("phone newer", createdAt: SyncTestValues.date.addingTimeInterval(2))
        _ = try await phone.synchronize()

        _ = try await mac.recordLocalContent("mac tail", createdAt: SyncTestValues.date.addingTimeInterval(3))
        let retried = try await mac.synchronize()
        let conflict = try #require(syncConflict(from: retried))
        #expect(conflict.base?.content == "mac committed")
        #expect(conflict.local.content == "mac tail")
        #expect(conflict.remote.content == "phone newer")
        #expect(syncContext(from: retried)?.lease == nil)
        #expect(await server.currentHead(for: SyncTestValues.key)?.content == "phone newer")
    }

    @Test("fresh session replays only a sealed outbox and a forced epoch rejects it")
    func freshSessionSealedReplayCannotPublishAfterForce() async throws {
        let server = InMemoryEpisodeSyncServer()
        let journal = InMemoryEpisodeSyncJournal()
        let oldWriter = makeCoordinator(
            server: server,
            journal: journal,
            replica: SyncTestValues.replicaA,
            session: SyncTestValues.sessionA
        )
        _ = try await oldWriter.link(
            localContent: "base",
            createdAt: SyncTestValues.date,
            leaseExpiresAt: SyncTestValues.expiry
        )
        _ = try await oldWriter.recordLocalContent(
            "sealed but not sent",
            createdAt: SyncTestValues.date.addingTimeInterval(1)
        )
        let unsealed = try #require(await journal.storedRecord(for: SyncTestValues.key))
        let candidate = try #require(unsealed.pendingRevisions.last)
        let seal = EpisodeSealedPublish(
            mutationID: SyncMutationID(),
            revisionIDs: [candidate.revisionID],
            candidateHeadRevisionID: candidate.revisionID,
            expectedHeadRevisionID: unsealed.lastKnownRemoteHead?.revisionID
        )
        let sealedRecord = try EpisodeSyncJournalRecord(
            key: unsealed.key,
            localWorkingCopyID: SyncTestValues.localWorkingCopyID,
            branchID: unsealed.branchID,
            lastKnownRemoteHead: unsealed.lastKnownRemoteHead,
            localHead: unsealed.localHead,
            pendingRevisions: unsealed.pendingRevisions,
            sealedPublish: seal,
            lease: unsealed.lease,
            conflict: unsealed.conflict,
            mode: unsealed.mode
        )
        try await journal.save(sealedRecord)

        let phone = makeCoordinator(
            server: server,
            journal: InMemoryEpisodeSyncJournal(),
            replica: SyncTestValues.replicaB,
            session: SyncTestValues.sessionB
        )
        _ = try await phone.link(
            localContent: "base",
            createdAt: SyncTestValues.date,
            leaseExpiresAt: SyncTestValues.expiry
        )
        let phoneGrant = try await phone.prepareForcedContinuation(expiresAt: SyncTestValues.expiry)
        _ = try await phone.confirmAuthorityInstall(
            phoneGrant,
            installedRemoteDigest: phoneGrant.snapshot.head?.contentDigest
        )
        _ = try await phone.recordLocalContent(
            "phone remote",
            createdAt: SyncTestValues.date.addingTimeInterval(2)
        )
        _ = try await phone.synchronize()

        let restarted = makeCoordinator(
            server: server,
            journal: journal,
            replica: SyncTestValues.replicaA,
            session: SyncEditSessionID()
        )
        _ = try await restarted.restore()
        let replayed = try await restarted.synchronize()
        let conflict = try #require(syncConflict(from: replayed))
        #expect(conflict.base?.content == "base")
        #expect(conflict.local.content == "sealed but not sent")
        #expect(conflict.remote.content == "phone remote")
        #expect(await server.currentHead(for: SyncTestValues.key)?.content == "phone remote")
        #expect(await journal.storedRecord(for: SyncTestValues.key)?.sealedPublish == nil)
        await expectCoordinatorError(.noEditingAuthority) {
            _ = try await restarted.recordLocalContent("new edit", createdAt: SyncTestValues.date)
        }
    }

    @Test("force grant collapses a captured local revision identical to the exact remote head")
    func forceGrantCollapsesEquivalentLocal() async throws {
        let server = InMemoryEpisodeSyncServer()
        let owner = makeCoordinator(
            server: server,
            journal: InMemoryEpisodeSyncJournal(),
            replica: SyncTestValues.replicaA,
            session: SyncTestValues.sessionA
        )
        _ = try await owner.link(
            localContent: "base",
            createdAt: SyncTestValues.date,
            leaseExpiresAt: SyncTestValues.expiry
        )
        let follower = makeCoordinator(
            server: server,
            journal: InMemoryEpisodeSyncJournal(),
            replica: SyncTestValues.replicaB,
            session: SyncTestValues.sessionB
        )
        _ = try await follower.link(
            localContent: "base",
            createdAt: SyncTestValues.date,
            leaseExpiresAt: SyncTestValues.expiry
        )
        _ = try await owner.recordLocalContent("same text", createdAt: SyncTestValues.date)
        _ = try await owner.synchronize()

        let grant = try await follower.prepareForcedContinuation(expiresAt: SyncTestValues.expiry)
        _ = try await follower.preserveLocalFork(
            content: "same text",
            createdAt: SyncTestValues.date,
            for: grant
        )
        let confirmed = try await follower.confirmAuthorityInstall(
            grant,
            installedRemoteDigest: grant.snapshot.head?.contentDigest
        )
        #expect(syncConflict(from: confirmed) == nil)
        #expect(syncContext(from: confirmed)?.pendingRevisionCount == 0)
        #expect(syncContext(from: confirmed)?.localHead == grant.snapshot.head)
    }

    @Test("fenced equal text becomes authority-lost read-only instead of an offline fork")
    func fenceEqualTextRemainsReadOnly() async throws {
        let server = InMemoryEpisodeSyncServer()
        let mac = makeCoordinator(
            server: server,
            journal: InMemoryEpisodeSyncJournal(),
            replica: SyncTestValues.replicaA,
            session: SyncTestValues.sessionA
        )
        _ = try await mac.link(
            localContent: "base",
            createdAt: SyncTestValues.date,
            leaseExpiresAt: SyncTestValues.expiry
        )
        let phone = makeCoordinator(
            server: server,
            journal: InMemoryEpisodeSyncJournal(),
            replica: SyncTestValues.replicaB,
            session: SyncTestValues.sessionB
        )
        _ = try await phone.link(
            localContent: "base",
            createdAt: SyncTestValues.date,
            leaseExpiresAt: SyncTestValues.expiry
        )
        let grant = try await phone.prepareForcedContinuation(expiresAt: SyncTestValues.expiry)
        _ = try await phone.confirmAuthorityInstall(
            grant,
            installedRemoteDigest: grant.snapshot.head?.contentDigest
        )
        _ = try await phone.recordLocalContent("same text", createdAt: SyncTestValues.date)
        _ = try await phone.synchronize()

        _ = try await mac.recordLocalContent("same text", createdAt: SyncTestValues.date)
        let observation = try await mac.inspectFence()
        _ = try await mac.preserveLocalFork(
            content: "same text",
            createdAt: SyncTestValues.date,
            for: observation
        )
        let confirmed = try await mac.confirmObservedRemoteInstall(
            observation,
            installedRemoteDigest: observation.remoteSnapshot?.head?.contentDigest
        )
        guard case .authorityLost = confirmed else {
            Issue.record("fenced equivalent text became editable")
            return
        }
        await expectCoordinatorError(.noEditingAuthority) {
            _ = try await mac.recordLocalContent("must stay read-only", createdAt: SyncTestValues.date)
        }
    }
}

// swiftlint:enable function_body_length

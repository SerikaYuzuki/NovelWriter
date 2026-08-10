import Foundation
import NovelSync
import NovelSyncTesting
import Testing

// End-to-end state-machine scenarios intentionally keep each race in one readable fixture.
// swiftlint:disable file_length type_body_length function_body_length
@Suite("Episode sync coordinator")
struct EpisodeSyncCoordinatorTests {
    @Test("force takeover fences old writer, preserves both forks, and publishes a two-parent merge")
    func forceTakeoverPreservesBothForks() async throws {
        let server = InMemoryEpisodeSyncServer()
        let macJournal = InMemoryEpisodeSyncJournal()
        let mac = makeCoordinator(
            server: server,
            journal: macJournal,
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
        let phoneGrant = try await phone.prepareForcedContinuation(expiresAt: SyncTestValues.expiry)
        _ = try await phone.confirmAuthorityInstall(
            phoneGrant,
            installedRemoteDigest: phoneGrant.snapshot.head?.contentDigest
        )
        _ = try await phone.recordLocalContent("phone fork", createdAt: SyncTestValues.date.addingTimeInterval(1))
        _ = try await phone.synchronize()

        _ = try await mac.recordLocalContent("mac fork", createdAt: SyncTestValues.date.addingTimeInterval(2))
        let fenced = try await mac.synchronize()
        let conflict = try #require(syncConflict(from: fenced))
        #expect(conflict.base?.content == "base")
        #expect(conflict.local.content == "mac fork")
        #expect(conflict.remote.content == "phone fork")
        let fencedRecord = try #require(await macJournal.storedRecord(for: SyncTestValues.key))
        #expect(fencedRecord.conflict == conflict)
        #expect(fencedRecord.pendingRevisions.map(\.content) == ["mac fork"])

        await #expect(throws: EpisodeSyncCoordinatorError.unresolvedConflict) {
            _ = try await mac.prepareForcedContinuation(expiresAt: SyncTestValues.expiry)
        }
        let macGrant = try await mac.prepareConflictResolutionAuthority(
            expectedConflict: conflict,
            expiresAt: SyncTestValues.expiry
        )
        _ = try await mac.preserveLocalFork(
            content: "mac fork",
            createdAt: SyncTestValues.date.addingTimeInterval(3),
            for: macGrant
        )
        _ = try await mac.confirmAuthorityInstall(
            macGrant,
            installedRemoteDigest: macGrant.snapshot.head?.contentDigest
        )
        let resolved = try await mac.resolveConflict(
            using: .keepLocal,
            createdAt: SyncTestValues.date.addingTimeInterval(4)
        )

        let finalContext = try #require(syncContext(from: resolved))
        #expect(finalContext.localHead.content == "mac fork")
        #expect(finalContext.localHead.parentRevisionIDs.count == 2)
        #expect(Set(finalContext.localHead.parentRevisionIDs) == [
            conflict.remote.revisionID,
            conflict.local.revisionID
        ])
        #expect(await server.currentHead(for: SyncTestValues.key) == finalContext.localHead)
    }

    @Test("stale conflict confirmation refreshes remote parent without replacing local fork")
    func staleConflictConfirmationPreservesLocalFork() async throws {
        let server = InMemoryEpisodeSyncServer()
        let macJournal = InMemoryEpisodeSyncJournal()
        let mac = makeCoordinator(
            server: server,
            journal: macJournal,
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
        let phoneGrant = try await phone.prepareForcedContinuation(expiresAt: SyncTestValues.expiry)
        _ = try await phone.confirmAuthorityInstall(
            phoneGrant,
            installedRemoteDigest: phoneGrant.snapshot.head?.contentDigest
        )
        _ = try await phone.recordLocalContent("phone first", createdAt: SyncTestValues.date.addingTimeInterval(1))
        _ = try await phone.synchronize()

        _ = try await mac.recordLocalContent("mac fork", createdAt: SyncTestValues.date.addingTimeInterval(2))
        let macState = try await mac.synchronize()
        let staleConflict = try #require(syncConflict(from: macState))
        _ = try await phone.recordLocalContent("phone latest", createdAt: SyncTestValues.date.addingTimeInterval(3))
        _ = try await phone.synchronize()

        await #expect(throws: EpisodeSyncCoordinatorError.conflictSuperseded) {
            _ = try await mac.prepareConflictResolutionAuthority(
                expectedConflict: staleConflict,
                expiresAt: SyncTestValues.expiry
            )
        }

        let record = try #require(await macJournal.storedRecord(for: SyncTestValues.key))
        #expect(record.conflict?.local.content == "mac fork")
        #expect(record.conflict?.remote.content == "phone latest")
        #expect(record.pendingRevisions.map(\.content) == ["mac fork"])
    }

    @Test("offline force cannot grant editing or mutate the local journal")
    func offlineForceIsReadOnly() async throws {
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

        let journal = InMemoryEpisodeSyncJournal()
        let follower = makeCoordinator(
            server: server,
            journal: journal,
            replica: SyncTestValues.replicaB,
            session: SyncTestValues.sessionB
        )
        _ = try await follower.link(
            localContent: "base",
            createdAt: SyncTestValues.date,
            leaseExpiresAt: SyncTestValues.expiry
        )
        let before = try #require(await journal.storedRecord(for: SyncTestValues.key))
        await server.setOnline(false)

        do {
            _ = try await follower.prepareForcedContinuation(expiresAt: SyncTestValues.expiry)
            Issue.record("offline force unexpectedly succeeded")
        } catch {
            #expect(error as? EpisodeSyncTransportError == .unavailable)
        }
        #expect(await journal.storedRecord(for: SyncTestValues.key) == before)
        await expectCoordinatorError(.noEditingAuthority) {
            _ = try await follower.recordLocalContent("must stay read-only", createdAt: SyncTestValues.date)
        }
    }

    @Test("fresh process restore is unverified and remains read-only while offline")
    func restoreRequiresOnlineRevalidation() async throws {
        let server = InMemoryEpisodeSyncServer()
        let journal = InMemoryEpisodeSyncJournal()
        let original = makeCoordinator(
            server: server,
            journal: journal,
            replica: SyncTestValues.replicaA,
            session: SyncTestValues.sessionA
        )
        _ = try await original.link(
            localContent: "base",
            createdAt: SyncTestValues.date,
            leaseExpiresAt: SyncTestValues.expiry
        )

        let restarted = makeCoordinator(
            server: server,
            journal: journal,
            replica: SyncTestValues.replicaA,
            session: SyncTestValues.sessionA
        )
        let restored = try await restarted.restore()
        guard case .restoredUnverified = restored else {
            Issue.record("restored lease was treated as verified authority")
            return
        }
        await expectCoordinatorError(.noEditingAuthority) {
            _ = try await restarted.recordLocalContent("offline edit", createdAt: SyncTestValues.date)
        }

        await server.setOnline(false)
        let offline = try await restarted.synchronize()
        guard case .restoredUnverified = offline else {
            Issue.record("offline restart unexpectedly became writable")
            return
        }
    }

    @Test("initial link mismatch is an explicit base-unknown conflict and never auto-publishes")
    func initialLinkMismatchIsConflict() async throws {
        let server = InMemoryEpisodeSyncServer()
        let owner = makeCoordinator(
            server: server,
            journal: InMemoryEpisodeSyncJournal(),
            replica: SyncTestValues.replicaA,
            session: SyncTestValues.sessionA
        )
        _ = try await owner.link(
            localContent: "remote original",
            createdAt: SyncTestValues.date,
            leaseExpiresAt: SyncTestValues.expiry
        )
        let remoteBefore = try #require(await server.currentHead(for: SyncTestValues.key))

        let followerJournal = InMemoryEpisodeSyncJournal()
        let follower = makeCoordinator(
            server: server,
            journal: followerJournal,
            replica: SyncTestValues.replicaB,
            session: SyncTestValues.sessionB
        )
        let linked = try await follower.link(
            localContent: "unrelated local import",
            createdAt: SyncTestValues.date,
            leaseExpiresAt: SyncTestValues.expiry
        )
        let conflict = try #require(syncConflict(from: linked))
        #expect(conflict.base == nil)
        #expect(conflict.local.parentRevisionIDs.isEmpty)
        #expect(conflict.remote == remoteBefore)
        #expect(await server.currentHead(for: SyncTestValues.key) == remoteBefore)
        #expect(await server.storedRevisionCount(for: SyncTestValues.key) == 1)
    }

    @Test("clean stale follower installs the exact forced head without creating a false conflict")
    func cleanFollowerForceInstallsRemote() async throws {
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

        _ = try await owner.recordLocalContent("remote v2", createdAt: SyncTestValues.date.addingTimeInterval(1))
        _ = try await owner.synchronize()
        let grant = try await follower.prepareForcedContinuation(expiresAt: SyncTestValues.expiry)
        #expect(grant.snapshot.head?.content == "remote v2")
        let confirmed = try await follower.confirmAuthorityInstall(
            grant,
            installedRemoteDigest: grant.snapshot.head?.contentDigest
        )
        #expect(syncConflict(from: confirmed) == nil)
        #expect(syncContext(from: confirmed)?.localHead == grant.snapshot.head)
        _ = try await follower.recordLocalContent(
            "phone continues",
            createdAt: SyncTestValues.date.addingTimeInterval(2)
        )
    }

    @Test("grant confirmation rechecks lease and head after another force takeover")
    func grantConfirmationRejectsSupersededGrant() async throws {
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

        let contenderB = makeCoordinator(
            server: server,
            journal: InMemoryEpisodeSyncJournal(),
            replica: SyncTestValues.replicaB,
            session: SyncTestValues.sessionB
        )
        _ = try await contenderB.link(
            localContent: "base",
            createdAt: SyncTestValues.date,
            leaseExpiresAt: SyncTestValues.expiry
        )
        let grantB = try await contenderB.prepareForcedContinuation(expiresAt: SyncTestValues.expiry)

        let contenderC = makeCoordinator(
            server: server,
            journal: InMemoryEpisodeSyncJournal(),
            replica: SyncReplicaID(),
            session: SyncEditSessionID()
        )
        _ = try await contenderC.link(
            localContent: "base",
            createdAt: SyncTestValues.date,
            leaseExpiresAt: SyncTestValues.expiry
        )
        let grantC = try await contenderC.prepareForcedContinuation(expiresAt: SyncTestValues.expiry)
        _ = try await contenderC.confirmAuthorityInstall(
            grantC,
            installedRemoteDigest: grantC.snapshot.head?.contentDigest
        )

        await expectCoordinatorError(.authorityGrantSuperseded) {
            _ = try await contenderB.confirmAuthorityInstall(
                grantB,
                installedRemoteDigest: grantB.snapshot.head?.contentDigest
            )
        }
        await expectCoordinatorError(.noEditingAuthority) {
            _ = try await contenderB.recordLocalContent("must not write", createdAt: SyncTestValues.date)
        }
    }

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

    private func makeCoordinator(
        server: InMemoryEpisodeSyncServer,
        journal: InMemoryEpisodeSyncJournal,
        replica: SyncReplicaID,
        session: SyncEditSessionID
    ) -> EpisodeSyncCoordinator {
        EpisodeSyncCoordinator(
            key: SyncTestValues.key,
            replicaID: replica,
            sessionID: session,
            transport: server,
            journal: journal
        )
    }

    private func expectCoordinatorError(
        _ expected: EpisodeSyncCoordinatorError,
        operation: () async throws -> Void
    ) async {
        do {
            try await operation()
            Issue.record("expected coordinator error \(expected)")
        } catch {
            #expect(error as? EpisodeSyncCoordinatorError == expected)
        }
    }
}

// swiftlint:enable file_length type_body_length function_body_length

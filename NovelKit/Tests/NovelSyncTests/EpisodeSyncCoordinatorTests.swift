import Foundation
import NovelSync
import NovelSyncTesting
import Testing

// End-to-end state-machine scenarios intentionally keep each race in one readable fixture.
// swiftlint:disable file_length type_body_length function_body_length
@Suite("Episode sync coordinator")
struct EpisodeSyncCoordinatorTests {
    @Test("cancelled publish restores a retryable state from the durable journal")
    func cancelledPublishDoesNotRemainSynchronizing() async throws {
        let server = InMemoryEpisodeSyncServer()
        let journal = InMemoryEpisodeSyncJournal()
        let coordinator = makeCoordinator(
            server: server,
            journal: journal,
            replica: SyncTestValues.replicaA,
            session: SyncTestValues.sessionA
        )
        _ = try await coordinator.link(
            localContent: "base",
            createdAt: SyncTestValues.date,
            leaseExpiresAt: SyncTestValues.expiry
        )
        _ = try await coordinator.recordLocalContent(
            "local draft",
            createdAt: SyncTestValues.date.addingTimeInterval(1)
        )
        await server.cancelNextPublish()

        await #expect(throws: CancellationError.self) {
            _ = try await coordinator.synchronize()
        }
        let interrupted = await coordinator.state
        guard case let .localChanges(context) = interrupted else {
            Issue.record("cancelled publish remained in a transient state")
            return
        }
        #expect(context.localHead.content == "local draft")
        #expect(context.pendingRevisionCount == 1)
        #expect(await journal.storedRecord(for: SyncTestValues.key)?.sealedPublish != nil)

        let retried = try await coordinator.synchronize()
        guard case let .upToDate(context) = retried else {
            Issue.record("sealed publish was not retryable after cancellation")
            return
        }
        #expect(context.localHead.content == "local draft")
        #expect(context.pendingRevisionCount == 0)
    }

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

    @Test("a native edit completed during conflict discovery extends the durable local fork")
    func lateNativeEditIsPreservedInConflict() async throws {
        let server = InMemoryEpisodeSyncServer()
        let journal = InMemoryEpisodeSyncJournal()
        let mac = makeCoordinator(
            server: server,
            journal: journal,
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
        _ = try await phone.recordLocalContent("remote", createdAt: SyncTestValues.date)
        _ = try await phone.synchronize()

        _ = try await mac.recordLocalContent("local L", createdAt: SyncTestValues.date)
        let discovered = try await mac.synchronize()
        let original = try #require(syncConflict(from: discovered))
        await server.setOnline(false)
        let preserved = try await mac.preserveConflictLocalContent(
            "late native X",
            expectedConflict: original,
            createdAt: SyncTestValues.date.addingTimeInterval(1)
        )
        let updated = try #require(syncConflict(from: preserved))
        #expect(updated.local.content == "late native X")
        #expect(updated.remote == original.remote)
        let preservedRecord = try #require(await journal.storedRecord(for: SyncTestValues.key))
        #expect(preservedRecord.pendingRevisions.map(\.content) == ["local L", "late native X"])
        #expect(updated.local.parentRevisionIDs == [original.local.revisionID])

        let coalesced = try await mac.preserveConflictLocalContent(
            "later native Y",
            expectedConflict: updated,
            createdAt: SyncTestValues.date.addingTimeInterval(2)
        )
        let latest = try #require(syncConflict(from: coalesced))
        let coalescedRecord = try #require(await journal.storedRecord(for: SyncTestValues.key))
        #expect(coalescedRecord.pendingRevisions.map(\.content) == ["local L", "later native Y"])
        #expect(latest.local.parentRevisionIDs == [original.local.revisionID])

        // remote本文をすでにmaterialize済みなら、既存Yをremoteで置換しない。
        _ = try await mac.preserveConflictLocalContent(
            latest.remote.content,
            expectedConflict: latest,
            createdAt: SyncTestValues.date.addingTimeInterval(3)
        )
        #expect(await journal.storedRecord(for: SyncTestValues.key)?.conflict?.local.content == "later native Y")
        await #expect(throws: EpisodeSyncCoordinatorError.conflictSuperseded) {
            _ = try await mac.preserveConflictLocalContent(
                "stale",
                expectedConflict: original,
                createdAt: SyncTestValues.date
            )
        }
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

    @Test("conflict takeover cannot fence a writer that advances the confirmed head")
    func conflictTakeoverUsesExactHeadCAS() async throws {
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
        let phoneGrant = try await phone.prepareForcedContinuation(expiresAt: SyncTestValues.expiry)
        _ = try await phone.confirmAuthorityInstall(
            phoneGrant,
            installedRemoteDigest: phoneGrant.snapshot.head?.contentDigest
        )
        _ = try await phone.recordLocalContent("remote R1", createdAt: SyncTestValues.date)
        _ = try await phone.synchronize()

        _ = try await mac.recordLocalContent("local L", createdAt: SyncTestValues.date)
        let conflicted = try await mac.synchronize()
        let staleConflict = try #require(syncConflict(from: conflicted))
        let phoneLease = try #require(await server.currentLease(for: SyncTestValues.key))

        await server.pauseNextClaim()
        let takeover = Task {
            try await mac.prepareConflictResolutionAuthority(
                expectedConflict: staleConflict,
                expiresAt: SyncTestValues.expiry
            )
        }
        await server.waitUntilClaimIsPaused()
        _ = try await phone.recordLocalContent(
            "remote R2",
            createdAt: SyncTestValues.date.addingTimeInterval(1)
        )
        _ = try await phone.synchronize()
        await server.resumePausedClaim()

        do {
            _ = try await takeover.value
            Issue.record("stale conflict confirmation unexpectedly took authority")
        } catch {
            #expect(error as? EpisodeSyncCoordinatorError == .conflictSuperseded)
        }
        #expect(await server.currentLease(for: SyncTestValues.key) == phoneLease)
        #expect(await server.currentHead(for: SyncTestValues.key)?.content == "remote R2")
        let macState = await mac.state
        let refreshed = try #require(syncConflict(from: macState))
        #expect(refreshed.local.content == "local L")
        #expect(refreshed.remote.content == "remote R2")
    }

    @Test("merge revision and publish seal survive termination before the first publish")
    func mergeSealSurvivesPrePublishTermination() async throws {
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
        let conflicted = try await mac.synchronize()
        let conflict = try #require(syncConflict(from: conflicted))
        let grant = try await mac.prepareConflictResolutionAuthority(
            expectedConflict: conflict,
            expiresAt: SyncTestValues.expiry
        )
        _ = try await mac.confirmAuthorityInstall(
            grant,
            installedRemoteDigest: grant.snapshot.head?.contentDigest
        )

        await server.setOnline(false)
        _ = try await mac.resolveConflict(
            using: .keepLocal,
            createdAt: SyncTestValues.date.addingTimeInterval(3)
        )
        let interrupted = try #require(await macJournal.storedRecord(for: SyncTestValues.key))
        #expect(interrupted.conflict == nil)
        #expect(interrupted.sealedPublish?.candidateHeadRevisionID == interrupted.localHead.revisionID)
        #expect(Set(interrupted.localHead.parentRevisionIDs) == [
            conflict.local.revisionID,
            conflict.remote.revisionID
        ])

        let restarted = makeCoordinator(
            server: server,
            journal: macJournal,
            replica: SyncTestValues.replicaA,
            session: SyncEditSessionID()
        )
        _ = try await restarted.restore()
        await server.setOnline(true)
        let replayed = try await restarted.synchronize()
        let replayedContext = try #require(syncContext(from: replayed))
        #expect(replayedContext.localHead.content == "mac fork")
        #expect(await server.currentHead(for: SyncTestValues.key) == replayedContext.localHead)
        #expect(await macJournal.storedRecord(for: SyncTestValues.key)?.sealedPublish == nil)
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

    @Test("fresh process surfaces a durable conflict before any new local capture")
    func restorePreservesDurableConflict() async throws {
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
        _ = try await original.recordLocalContent(
            "durable local fork",
            createdAt: SyncTestValues.date.addingTimeInterval(1)
        )

        let pending = try #require(await journal.storedRecord(for: SyncTestValues.key))
        let remote = try #require(pending.lastKnownRemoteHead)
        let conflict = EpisodeConflict(
            base: remote,
            local: pending.localHead,
            remote: remote
        )
        let conflictedRecord = try EpisodeSyncJournalRecord(
            key: pending.key,
            branchID: pending.branchID,
            lastKnownRemoteHead: pending.lastKnownRemoteHead,
            localHead: pending.localHead,
            pendingRevisions: pending.pendingRevisions,
            sealedPublish: pending.sealedPublish,
            lease: pending.lease,
            conflict: conflict,
            mode: .forcedFork
        )
        try await journal.save(conflictedRecord)

        let restarted = makeCoordinator(
            server: server,
            journal: journal,
            replica: SyncTestValues.replicaA,
            session: SyncEditSessionID()
        )
        _ = try await restarted.restore()
        let restored = try await restarted.synchronize()
        let restoredConflict = try #require(syncConflict(from: restored))
        #expect(restoredConflict.local.content == "durable local fork")
        #expect(restoredConflict.remote.content == "base")

        let preserved = try #require(await journal.storedRecord(for: SyncTestValues.key))
        #expect(preserved.pendingRevisions.map(\.content) == ["durable local fork"])
        #expect(preserved.conflict?.local.content == "durable local fork")
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

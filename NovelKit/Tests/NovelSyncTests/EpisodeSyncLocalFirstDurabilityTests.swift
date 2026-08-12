import Foundation
import NovelSync
import NovelSyncTesting
import Testing

extension EpisodeSyncLocalFirstTests {
    @Test("restore and an immediate edit serialize without stale load overwrite")
    func restoreLoadRacePreservesLatestEdit() async throws {
        let server = InMemoryEpisodeSyncServer()
        let journal = InMemoryEpisodeSyncJournal()
        let original = makeCoordinator(
            server: server,
            journal: journal,
            session: SyncTestValues.sessionA
        )
        _ = try await original.recordLocalEdit("base", createdAt: SyncTestValues.date)
        let baseline = try #require(await journal.storedRecord(for: SyncTestValues.key))

        let restarted = makeCoordinator(
            server: server,
            journal: journal,
            session: SyncEditSessionID()
        )
        await journal.pauseNextLoadAfterCapture()
        let restoring = Task { try await restarted.restore() }
        await journal.waitUntilLoadIsPaused()
        let editing = Task {
            try await restarted.recordLocalEdit(
                "latest",
                createdAt: SyncTestValues.date.addingTimeInterval(1)
            )
        }
        await Task.yield()
        await journal.resumePausedLoad()
        _ = try await restoring.value
        _ = try await editing.value

        let final = try #require(await journal.storedRecord(for: SyncTestValues.key))
        #expect(final.branchID == baseline.branchID)
        #expect(final.localHead.content == "latest")
    }

    @Test("a paused offline-state save cannot overwrite a newer local edit")
    func offlineStatusSaveSerializesBeforeNewerEdit() async throws {
        let server = InMemoryEpisodeSyncServer()
        await server.setOnline(false)
        let journal = InMemoryEpisodeSyncJournal()
        let coordinator = makeCoordinator(
            server: server,
            journal: journal,
            session: SyncTestValues.sessionA
        )
        _ = try await coordinator.recordLocalEdit("first", createdAt: SyncTestValues.date)

        await journal.pauseNextSaveBeforeCommit()
        let synchronizing = Task {
            try await coordinator.synchronizeLocalFirst(
                expiresAt: SyncTestValues.expiry,
                createdAt: SyncTestValues.date.addingTimeInterval(1)
            )
        }
        await journal.waitUntilSaveIsPaused()
        let editing = Task {
            try await coordinator.recordLocalEdit(
                "second",
                createdAt: SyncTestValues.date.addingTimeInterval(2)
            )
        }
        await Task.yield()
        await journal.resumePausedSave()
        _ = try await synchronizing.value
        _ = try await editing.value

        let restarted = makeCoordinator(
            server: server,
            journal: journal,
            session: SyncEditSessionID()
        )
        _ = try await restarted.restore()
        let durable = try #require(await journal.storedRecord(for: SyncTestValues.key))
        #expect(durable.localHead.content == "second")
        #expect(durable.pendingRevisions.last?.content == "second")
    }

    @Test("a package write followed by termination before edit journaling is recovered from its baseline")
    func packageJournalKillBoundaryRecoversExplicitEdit() async throws {
        let server = InMemoryEpisodeSyncServer()
        await server.setOnline(false)
        let journal = InMemoryEpisodeSyncJournal()
        let original = makeCoordinator(
            server: server,
            journal: journal,
            session: SyncTestValues.sessionA
        )
        _ = try await original.observeLocalBase(
            localContent: "保存前",
            createdAt: SyncTestValues.date
        )

        // packageだけが「保存後」へ進んだ直後にprocessが終了した境界を再現する。
        let restarted = makeCoordinator(
            server: server,
            journal: journal,
            session: SyncEditSessionID()
        )
        _ = try await restarted.recordLocalEdit(
            "保存後",
            createdAt: SyncTestValues.date.addingTimeInterval(1)
        )
        let recovered = try #require(await journal.storedRecord(for: SyncTestValues.key))
        #expect(recovered.localEditIntent == .explicit)
        #expect(recovered.pendingRevisions.map(\.content) == ["保存前", "保存後"])
        #expect(recovered.localHead.content == "保存後")
    }

    @Test("an explicit same-body mutation promotes an unconfirmed observed baseline")
    func sameBodyFirstMutationIsNotErasedByBaselineOrdering() async throws {
        let server = InMemoryEpisodeSyncServer()
        let journal = InMemoryEpisodeSyncJournal()
        let coordinator = makeCoordinator(
            server: server,
            journal: journal,
            session: SyncTestValues.sessionA
        )
        _ = try await coordinator.observeLocalBase(
            localContent: "B",
            createdAt: SyncTestValues.date
        )
        _ = try await coordinator.recordLocalEdit("B", createdAt: SyncTestValues.date)
        let recorded = try #require(await journal.storedRecord(for: SyncTestValues.key))
        #expect(recorded.localEditIntent == .explicit)
        #expect(recorded.pendingRevisions == [recorded.localHead])
        #expect(recorded.reconciliationStatus == .pending)
        #expect(await server.currentHead(for: SyncTestValues.key) == nil)
    }

    @Test("a same-body Undo intent after confirmed observation remains a two-parent merge input")
    func confirmedSameBodyUndoIntentRemainsInRevisionGraph() async throws {
        // The App may coalesce A -> B -> Undo A before the package-to-journal boundary.
        // Calling recordLocalEdit still proves that a native mutation occurred even though
        // the resulting digest equals the already-confirmed observed baseline.
        let setup = try await makeDivergedPair(
            baseContent: "A",
            localContent: "A",
            remoteContent: "B"
        )
        let explicit = try #require(await setup.journal.storedRecord(for: SyncTestValues.key))
        let base = explicit.localHead
        #expect(explicit.localEditIntent == .explicit && explicit.remoteConfirmation == .unconfirmed)
        #expect(explicit.pendingRevisions == [base])
        let remoteEdit = try #require(await setup.server.currentHead(for: SyncTestValues.key))
        let epochBeforeTakeover = await setup.server.currentLeaseEpoch(for: SyncTestValues.key)

        let synchronized = try await setup.follower.synchronizeLocalFirst(
            expiresAt: SyncTestValues.expiry.addingTimeInterval(10),
            createdAt: SyncTestValues.date.addingTimeInterval(3)
        )
        let merged = try #require(await setup.server.currentHead(for: SyncTestValues.key))
        let materialization = try #require(syncContext(from: synchronized)?.pendingMaterialization)
        #expect(merged.content == "B")
        #expect(merged.parentRevisionIDs == [remoteEdit.revisionID, base.revisionID])
        #expect(materialization.workingRevisionID == base.revisionID && materialization.integratedRevision == merged)
        #expect(syncContext(from: synchronized)?.localHead == base)
        #expect(await setup.server.currentLeaseEpoch(for: SyncTestValues.key) > epochBeforeTakeover)
    }

    @Test("offline first edit survives restart without an explicit restore call")
    func offlineEditRestartAndReedit() async throws {
        let server = InMemoryEpisodeSyncServer()
        await server.setOnline(false)
        let journal = InMemoryEpisodeSyncJournal()
        let first = makeCoordinator(server: server, journal: journal, session: SyncTestValues.sessionA)

        let firstReceipt = try await first.recordLocalEdit(
            "オフライン1",
            createdAt: SyncTestValues.date
        )
        let firstRecord = try #require(await journal.storedRecord(for: SyncTestValues.key))
        #expect(firstReceipt.localWorkingCopyID == SyncTestValues.localWorkingCopyID)
        #expect(firstRecord.localHead.content == "オフライン1")
        #expect(firstRecord.localEditIntent == .explicit)
        #expect(firstRecord.remoteConfirmation == .unconfirmed)

        let restarted = makeCoordinator(
            server: server,
            journal: journal,
            session: SyncEditSessionID()
        )
        let secondReceipt = try await restarted.recordLocalEdit(
            "オフライン2",
            createdAt: SyncTestValues.date.addingTimeInterval(1)
        )
        let restored = try #require(await journal.storedRecord(for: SyncTestValues.key))
        #expect(restored.branchID == firstRecord.branchID)
        #expect(restored.localWorkingCopyID == SyncTestValues.localWorkingCopyID)
        #expect(restored.localHead.revisionID == secondReceipt.revisionID)
        #expect(restored.localHead.content == "オフライン2")
    }

    @Test("recordLocalEdit loads an existing journal before creating a detached genesis")
    func recordLoadsExistingJournalBeforeBootstrap() async throws {
        let server = InMemoryEpisodeSyncServer()
        let journal = InMemoryEpisodeSyncJournal()
        let existing = makeCoordinator(server: server, journal: journal, session: SyncTestValues.sessionA)
        _ = try await existing.recordLocalEdit("既存", createdAt: SyncTestValues.date)
        let before = try #require(await journal.storedRecord(for: SyncTestValues.key))

        let fresh = makeCoordinator(server: server, journal: journal, session: SyncEditSessionID())
        _ = try await fresh.recordLocalEdit(
            "既存の続き",
            createdAt: SyncTestValues.date.addingTimeInterval(1)
        )
        let after = try #require(await journal.storedRecord(for: SyncTestValues.key))
        #expect(after.branchID == before.branchID)
        #expect(after.localHead.content == "既存の続き")
    }

    @Test("an unknown first remote base preserves both observed bodies without publishing")
    func unknownObservationPreservesBothBodiesWithoutPublishing() async throws {
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
        let epoch = await server.currentLeaseEpoch(for: SyncTestValues.key)
        let head = try #require(await server.currentHead(for: SyncTestValues.key))

        let followerJournal = InMemoryEpisodeSyncJournal()
        let follower = makeCoordinator(
            server: server,
            journal: followerJournal,
            replica: SyncTestValues.replicaB,
            session: SyncTestValues.sessionB
        )
        _ = try await follower.observeRemoteBase(
            localContent: "local package differs",
            createdAt: SyncTestValues.date
        )
        _ = try await follower.synchronizeLocalFirst(
            expiresAt: SyncTestValues.expiry,
            createdAt: SyncTestValues.date
        )

        let observed = try #require(await followerJournal.storedRecord(for: SyncTestValues.key))
        #expect(observed.localEditIntent == .observed)
        #expect(observed.pendingRevisions.isEmpty)
        #expect(observed.conflict?.base == nil)
        #expect(observed.conflict?.local.content == "local package differs")
        #expect(observed.conflict?.remote == head)
        #expect(observed.reconciliationStatus == .reviewRequired)
        #expect(await server.currentLeaseEpoch(for: SyncTestValues.key) == epoch)
        #expect(await server.currentHead(for: SyncTestValues.key) == head)
    }

    @Test("a clean remote advance is crash-safe pending materialization and exact ack")
    func cleanRemoteAdvanceAwaitsMaterializationAcrossRestart() async throws {
        let server = InMemoryEpisodeSyncServer()
        let owner = makeCoordinator(
            server: server,
            journal: InMemoryEpisodeSyncJournal(),
            session: SyncTestValues.sessionA
        )
        _ = try await owner.link(
            localContent: "R0",
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
        _ = try await follower.observeRemoteBase(localContent: "R0", createdAt: SyncTestValues.date)
        _ = try await owner.recordLocalContent(
            "R1",
            createdAt: SyncTestValues.date.addingTimeInterval(1)
        )
        _ = try await owner.synchronize()

        let waiting = try await follower.observeRemoteBase(
            localContent: "R0",
            createdAt: SyncTestValues.date.addingTimeInterval(2)
        )
        let materialization = try #require(syncContext(from: waiting)?.pendingMaterialization)
        #expect(materialization.integratedRevision.content == "R1")
        #expect(syncContext(from: waiting)?.hasExplicitLocalChanges == false)

        let restarted = makeCoordinator(
            server: server,
            journal: journal,
            replica: SyncTestValues.replicaB,
            session: SyncEditSessionID()
        )
        _ = try await restarted.restore()
        #expect(await restarted.integrationAwaitingMaterialization == materialization)
        let installed = try await restarted.confirmIntegratedContentMaterialized(
            materialization,
            installedContentDigest: materialization.integratedRevision.contentDigest
        )
        #expect(syncContext(from: installed)?.localHead.content == "R1")
        #expect(syncContext(from: installed)?.remoteConfirmation == .confirmed)
    }

    @Test("an edit during clean remote materialization merges non-overlapping changes")
    func editDuringCleanRemoteMaterializationMerges() async throws {
        let setup = try await makeCleanRemoteAdvance(
            baseContent: "甲\n乙\n",
            remoteContent: "甲\n乙R\n"
        )
        _ = try await setup.follower.recordLocalEdit(
            "甲L\n乙\n",
            createdAt: SyncTestValues.date.addingTimeInterval(3)
        )
        let recorded = try #require(await setup.journal.storedRecord(for: SyncTestValues.key))
        #expect(recorded.localEditIntent == .explicit)
        #expect(recorded.pendingMaterialization?.integratedRevision.content == "甲L\n乙R\n")

        _ = try await setup.follower.synchronizeLocalFirst(
            expiresAt: SyncTestValues.expiry,
            createdAt: SyncTestValues.date.addingTimeInterval(4)
        )
        #expect(await setup.server.currentHead(for: SyncTestValues.key)?.content == "甲L\n乙R\n")
    }

    @Test("an overlapping edit during clean remote materialization preserves both bodies")
    func overlapDuringCleanRemoteMaterializationNeedsReview() async throws {
        let setup = try await makeCleanRemoteAdvance(
            baseContent: "abc",
            remoteContent: "aYc"
        )
        _ = try await setup.follower.recordLocalEdit(
            "aXc",
            createdAt: SyncTestValues.date.addingTimeInterval(3)
        )
        let recorded = try #require(await setup.journal.storedRecord(for: SyncTestValues.key))
        #expect(recorded.localEditIntent == .explicit)
        #expect(recorded.pendingMaterialization == nil)
        #expect(recorded.conflict?.base?.content == "abc")
        #expect(recorded.conflict?.local.content == "aXc")
        #expect(recorded.conflict?.remote.content == "aYc")
        #expect(recorded.reconciliationStatus == .reviewRequired)
    }
}

// One suite keeps the coordinator's observation-CAS scenarios together.
// swiftlint:disable:next blanket_disable_command
// swiftlint:disable file_length type_body_length
import Foundation
import NovelSync
import NovelSyncTesting
import Testing

@Suite("Offline-first whole-work coordinator")
struct WorkSyncCoordinatorTests {
    @Test("offline edit survives restart and reconnect as the exact whole-work snapshot")
    func offlineRestartReconnect() async throws {
        let server = InMemoryWorkSyncServer()
        await server.setOnline(false)
        let journal = InMemoryWorkSyncJournal()
        let first = WorkTestValues.coordinator(server: server, journal: journal)
        let base = try WorkTestValues.snapshot()
        _ = try await first.bootstrapLocalSnapshot(base, at: WorkTestValues.date)
        guard case .offline = try await first.synchronize(at: WorkTestValues.date) else {
            Issue.record("offline transport did not report offline")
            return
        }

        let edited = try WorkTestValues.snapshot {
            $0.title = "地下鉄で編集"
            $0.chapters[0].episodes[0].content = "offline whole body"
            $0.characters[0].memo = "offline character"
        }
        _ = try await stageAndConfirm(
            first,
            snapshot: edited,
            at: WorkTestValues.date.addingTimeInterval(1)
        )

        let restarted = WorkTestValues.coordinator(
            server: server,
            journal: journal,
            session: SyncEditSessionID()
        )
        _ = try await restarted.restore()
        var restartedState = try await restarted.currentState()
        #expect(restartedState.localHead.snapshot == edited)
        await server.setOnline(true)
        _ = try await restarted.synchronize(at: WorkTestValues.date.addingTimeInterval(2))
        #expect(await server.currentHead(for: WorkTestValues.workID)?.snapshot == edited)
        restartedState = try await restarted.currentState()
        #expect(restartedState.pendingRevisionCount == 0)
    }

    @Test("same package on a second device safely collapses a different root revision ID")
    func sameSnapshotDifferentRootCollapses() async throws {
        let server = InMemoryWorkSyncServer()
        let owner = WorkTestValues.coordinator(server: server, journal: InMemoryWorkSyncJournal())
        let snapshot = try WorkTestValues.snapshot()
        let ownerRoot = try await owner.bootstrapLocalSnapshot(snapshot, at: WorkTestValues.date)
        _ = try await owner.synchronize(at: WorkTestValues.date)

        let follower = WorkTestValues.coordinator(
            server: server,
            journal: InMemoryWorkSyncJournal(),
            copy: WorkTestValues.copyB,
            replica: WorkTestValues.replicaB,
            session: WorkTestValues.sessionB
        )
        let localRoot = try await follower.bootstrapLocalSnapshot(
            snapshot,
            at: WorkTestValues.date.addingTimeInterval(1)
        )
        #expect(localRoot.revisionID != ownerRoot.revisionID)
        guard case let .upToDate(collapsed) = try await follower.synchronize(
            at: WorkTestValues.date.addingTimeInterval(2)
        ) else {
            Issue.record("identical package required an unnecessary review")
            return
        }
        #expect(collapsed.revisionID == ownerRoot.revisionID)
        #expect(try await follower.currentState().pendingRevisionCount == 0)
    }

    @Test("paused first publish preserves multiple editor tails and sends the latest after ack")
    func pausedInitialPublishWithMultipleTails() async throws {
        let server = InMemoryWorkSyncServer()
        let journal = InMemoryWorkSyncJournal()
        let coordinator = WorkTestValues.coordinator(server: server, journal: journal)
        let first = try WorkTestValues.snapshot { $0.title = "L1" }
        _ = try await coordinator.bootstrapLocalSnapshot(first, at: WorkTestValues.date)

        await server.pauseNextPublish()
        let publishing = Task {
            try await coordinator.synchronize(at: WorkTestValues.date.addingTimeInterval(1))
        }
        #expect(await waitUntil { await server.publishIsPaused() })

        let second = try WorkTestValues.snapshot { $0.title = "L2" }
        _ = try await stageAndConfirm(
            coordinator,
            snapshot: second,
            at: WorkTestValues.date.addingTimeInterval(2)
        )
        let third = try WorkTestValues.snapshot { document in
            document.title = "L3"
            document.synopsis = "latest tail"
        }
        _ = try await stageAndConfirm(
            coordinator,
            snapshot: third,
            at: WorkTestValues.date.addingTimeInterval(3)
        )
        let during = try #require(await journal.storedRecord(for: WorkTestValues.workID))
        #expect(during.outbox.count <= WorkSyncJournalRecord.maximumOutboxRevisionCount)
        #expect(during.localHead.snapshot == third)

        await server.resumePausedPublish()
        _ = try await publishing.value
        let finalState = try await coordinator.currentState()
        #expect(await server.currentHead(for: WorkTestValues.workID)?.snapshot == third)
        #expect(finalState.localHead.snapshot == third)
        #expect(finalState.pendingRevisionCount == 0)
    }

    @Test("paused fetch cannot overwrite a local edit committed while the network awaited")
    func pausedFetchPreservesLocalEdit() async throws {
        let server = InMemoryWorkSyncServer()
        let owner = WorkTestValues.coordinator(server: server, journal: InMemoryWorkSyncJournal())
        let base = try WorkTestValues.snapshot()
        let remote = try await owner.bootstrapLocalSnapshot(base, at: WorkTestValues.date)
        _ = try await owner.synchronize(at: WorkTestValues.date)

        let journal = InMemoryWorkSyncJournal()
        let follower = WorkTestValues.coordinator(
            server: server,
            journal: journal,
            copy: WorkTestValues.copyB,
            replica: WorkTestValues.replicaB,
            session: WorkTestValues.sessionB
        )
        let pending = try await follower.bootstrapRemoteRevision(remote)
        try await follower.acknowledgeRemoteMaterialization(
            pending.revision.revisionID,
            packageSnapshot: base
        )

        await server.pauseNextFetchAfterCapture()
        let synchronizing = Task {
            try await follower.synchronize(at: WorkTestValues.date.addingTimeInterval(1))
        }
        #expect(await waitUntil { await server.fetchIsPaused() })
        let edited = try WorkTestValues.snapshot { $0.synopsis = "edit during fetch" }
        _ = try await stageAndConfirm(
            follower,
            snapshot: edited,
            at: WorkTestValues.date.addingTimeInterval(2)
        )
        await server.resumePausedFetch()
        _ = try await synchronizing.value

        #expect(await server.currentHead(for: WorkTestValues.workID)?.snapshot == edited)
        #expect(try await follower.currentState().localHead.snapshot == edited)
    }

    @Test("journal save lane serializes two stages and restart observes the latest exact snapshot")
    func pausedJournalSavePreservesLatest() async throws {
        let server = InMemoryWorkSyncServer()
        let journal = InMemoryWorkSyncJournal()
        let coordinator = WorkTestValues.coordinator(server: server, journal: journal)
        _ = try await coordinator.bootstrapLocalSnapshot(
            WorkTestValues.snapshot(),
            at: WorkTestValues.date
        )
        let first = try WorkTestValues.snapshot { $0.title = "first stage" }
        let latest = try WorkTestValues.snapshot { $0.title = "latest stage" }

        await journal.pauseNextSaveBeforeCommit()
        let stagingFirst = Task {
            try await coordinator.stageLocalSnapshot(
                first,
                at: WorkTestValues.date.addingTimeInterval(1)
            )
        }
        #expect(await waitUntil { await journal.saveIsPaused() })
        let stagingLatest = Task {
            try await coordinator.stageLocalSnapshot(
                latest,
                at: WorkTestValues.date.addingTimeInterval(2)
            )
        }
        await journal.resumePausedSave()
        _ = try await stagingFirst.value
        let latestRevision = try await stagingLatest.value

        let restarted = WorkTestValues.coordinator(
            server: server,
            journal: journal,
            session: SyncEditSessionID()
        )
        _ = try await restarted.restore()
        let restored = try await restarted.currentState()
        #expect(restored.stagedLocalRevision?.revisionID == latestRevision.revisionID)
        #expect(restored.stagedLocalRevision?.snapshot == latest)
    }

    @Test("stage marker failure followed by package success becomes an explicit revision on restart")
    func failedStageMarkerRecoversPackage() async throws {
        let server = InMemoryWorkSyncServer()
        let journal = InMemoryWorkSyncJournal()
        let original = WorkTestValues.coordinator(server: server, journal: journal)
        _ = try await original.bootstrapLocalSnapshot(
            WorkTestValues.snapshot(),
            at: WorkTestValues.date
        )
        let package = try WorkTestValues.snapshot { $0.title = "package won before kill" }
        await journal.failNextSave()
        await #expect(throws: InMemoryWorkSyncJournalError.self) {
            _ = try await original.stageLocalSnapshot(
                package,
                at: WorkTestValues.date.addingTimeInterval(1)
            )
        }

        let restarted = WorkTestValues.coordinator(
            server: server,
            journal: journal,
            session: SyncEditSessionID()
        )
        _ = try await restarted.restore()
        guard case let .capturedUnstagedPackage(revision) = try await restarted.reconcileLocalMaterialization(
            packageSnapshot: package,
            at: WorkTestValues.date.addingTimeInterval(2)
        ) else {
            Issue.record("unstaged package was not captured")
            return
        }
        #expect(revision.snapshot == package)
        #expect(try await restarted.currentState().localHead == revision)
    }

    @Test("explicit save back to local head durably cancels a stale staged revision")
    func revertedSaveClearsStaleStage() async throws {
        let server = InMemoryWorkSyncServer()
        let journal = InMemoryWorkSyncJournal()
        let coordinator = WorkTestValues.coordinator(server: server, journal: journal)
        let materializedSnapshot = try WorkTestValues.snapshot()
        let materialized = try await coordinator.bootstrapLocalSnapshot(
            materializedSnapshot,
            at: WorkTestValues.date
        )
        let stagedSnapshot = try WorkTestValues.snapshot { $0.title = "temporary edit" }
        let staged = try await coordinator.stageLocalSnapshot(
            stagedSnapshot,
            at: WorkTestValues.date.addingTimeInterval(1)
        )

        await journal.failNextSave()
        await #expect(throws: InMemoryWorkSyncJournalError.self) {
            try await coordinator.confirmLocalSnapshotMaterialized(
                staged.revisionID,
                packageSnapshot: stagedSnapshot
            )
        }
        #expect(try await coordinator.currentState().stagedLocalRevision == staged)

        let reverted = try await coordinator.stageLocalSnapshot(
            materializedSnapshot,
            at: WorkTestValues.date.addingTimeInterval(2)
        )
        #expect(reverted == materialized)
        #expect(try await coordinator.currentState().stagedLocalRevision == nil)
        #expect(await journal.storedRecord(for: WorkTestValues.workID)?.stagedLocalRevision == nil)

        let restarted = WorkTestValues.coordinator(
            server: server,
            journal: journal,
            session: SyncEditSessionID()
        )
        _ = try await restarted.restore()
        guard case let .consistent(restored) = try await restarted.reconcileLocalMaterialization(
            packageSnapshot: materializedSnapshot,
            at: WorkTestValues.date.addingTimeInterval(3)
        ) else {
            Issue.record("restart attempted to reinstall the cancelled staged snapshot")
            return
        }
        #expect(restored == materialized)
        #expect(try await restarted.currentState().stagedLocalRevision == nil)
    }

    @Test("remote bootstrap never overwrites a different existing package")
    func remoteBootstrapDifferentPackageRequiresRecoveryReview() async throws {
        let server = InMemoryWorkSyncServer()
        let remote = try WorkTestValues.revision(
            snapshot: WorkTestValues.snapshot { $0.title = "remote" },
            id: "70000000-0000-0000-0000-000000000010"
        )
        let journal = InMemoryWorkSyncJournal()
        let coordinator = WorkTestValues.coordinator(server: server, journal: journal)
        _ = try await coordinator.bootstrapRemoteRevision(remote)
        let package = try WorkTestValues.snapshot { $0.title = "existing local package" }

        guard case let .reviewRequired(review) = try await coordinator.reconcileLocalMaterialization(
            packageSnapshot: package,
            at: WorkTestValues.date
        ) else {
            Issue.record("different local package was overwritten")
            return
        }
        #expect(review.observedPackageSnapshot == package)
        #expect(review.pendingRemoteMaterialization?.revision == remote)
        #expect(try await coordinator.currentState().pendingRemoteMaterialization?.revision == remote)
    }

    @Test("unrelated roots preserve both exact revisions in unknown-ancestry review")
    func unknownAncestryReview() async throws {
        let server = InMemoryWorkSyncServer()
        let owner = WorkTestValues.coordinator(server: server, journal: InMemoryWorkSyncJournal())
        let remoteSnapshot = try WorkTestValues.snapshot { $0.title = "remote root" }
        let remote = try await owner.bootstrapLocalSnapshot(remoteSnapshot, at: WorkTestValues.date)
        _ = try await owner.synchronize(at: WorkTestValues.date)

        let local = WorkTestValues.coordinator(
            server: server,
            journal: InMemoryWorkSyncJournal(),
            copy: WorkTestValues.copyB,
            replica: WorkTestValues.replicaB,
            session: WorkTestValues.sessionB
        )
        let localSnapshot = try WorkTestValues.snapshot { $0.title = "local root" }
        let localRevision = try await local.bootstrapLocalSnapshot(
            localSnapshot,
            at: WorkTestValues.date.addingTimeInterval(1)
        )
        guard case let .reviewRequired(review) = try await local.synchronize(
            at: WorkTestValues.date.addingTimeInterval(2)
        ) else {
            Issue.record("unknown roots did not retain a review")
            return
        }
        #expect(review.base == nil)
        #expect(review.local == localRevision)
        #expect(review.remote == remote)
        #expect(review.conflicts.contains { $0.reason == .commonAncestorUnknown })
    }

    @Test("continuous edits exhaust observation retries as local pending, never false offline")
    func continuousEditsRemainPending() async throws {
        let server = InMemoryWorkSyncServer()
        let coordinator = WorkTestValues.coordinator(
            server: server,
            journal: InMemoryWorkSyncJournal()
        )
        _ = try await coordinator.bootstrapLocalSnapshot(
            WorkTestValues.snapshot { $0.title = "root" },
            at: WorkTestValues.date
        )
        await server.pauseNextPublish()
        let synchronizing = Task {
            try await coordinator.synchronize(at: WorkTestValues.date.addingTimeInterval(1))
        }
        for index in 1 ... 4 {
            #expect(await waitUntil { await server.publishIsPaused() })
            let tail = try WorkTestValues.snapshot { document in
                document.title = "tail-\(index)"
            }
            _ = try await stageAndConfirm(
                coordinator,
                snapshot: tail,
                at: WorkTestValues.date.addingTimeInterval(TimeInterval(index + 1))
            )
            if index < 4 {
                await server.pauseNextPublish()
            }
            await server.resumePausedPublish()
        }
        guard case let .localPending(latest) = try await synchronizing.value else {
            Issue.record("successful network with continuous edits was not reported as local pending")
            return
        }
        #expect(latest.snapshot.title == "tail-4")
        #expect(try await coordinator.currentState().reconciliationStatus == .pending)
        _ = try await coordinator.synchronize(at: WorkTestValues.date.addingTimeInterval(10))
        #expect(await server.currentHead(for: WorkTestValues.workID)?.snapshot.title == "tail-4")
    }

    @Test("lost publish response survives restart and converges without duplicating the revision")
    func lostPublishResponseRestart() async throws {
        let server = InMemoryWorkSyncServer()
        let journal = InMemoryWorkSyncJournal()
        let first = WorkTestValues.coordinator(server: server, journal: journal)
        let snapshot = try WorkTestValues.snapshot { $0.title = "commit before response loss" }
        let revision = try await first.bootstrapLocalSnapshot(snapshot, at: WorkTestValues.date)
        await server.loseNextPublishResponseAfterCommit()
        guard case .offline = try await first.synchronize(at: WorkTestValues.date) else {
            Issue.record("lost response did not leave a retryable offline observation")
            return
        }
        let beforeRestart = try #require(await journal.storedRecord(for: WorkTestValues.workID))
        #expect(beforeRestart.sealedPublish != nil)
        #expect(await server.currentHead(for: WorkTestValues.workID)?.revisionID == revision.revisionID)

        let restarted = WorkTestValues.coordinator(
            server: server,
            journal: journal,
            session: SyncEditSessionID()
        )
        _ = try await restarted.restore()
        _ = try await restarted.synchronize(at: WorkTestValues.date.addingTimeInterval(1))
        let durable = try #require(await journal.storedRecord(for: WorkTestValues.workID))
        #expect(durable.localHead.revisionID == revision.revisionID)
        #expect(durable.outbox.isEmpty)
        #expect(durable.sealedPublish == nil)
        #expect(await server.currentHead(for: WorkTestValues.workID)?.revisionID == revision.revisionID)
    }
}

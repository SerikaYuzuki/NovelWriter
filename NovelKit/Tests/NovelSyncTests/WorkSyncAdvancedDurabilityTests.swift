// One suite keeps the multi-step kill-boundary scenarios readable end-to-end.
// swiftlint:disable:next blanket_disable_command
// swiftlint:disable file_length type_body_length function_body_length
import Foundation
import NovelSync
import NovelSyncTesting
import Testing

@Suite("Whole-work pending materialization durability")
struct WorkSyncAdvancedDurabilityTests {
    @Test("automatic merge pending plus editor tail rebases to the actual remote, survives restart, and publishes")
    func automaticMergeTailHasNoMissingParent() async throws {
        let setup = try await synchronizedPair()
        let remoteSnapshot = try WorkTestValues.snapshot { $0.synopsis = "remote synopsis" }
        let remote = try await stageAndConfirm(
            setup.owner,
            snapshot: remoteSnapshot,
            at: WorkTestValues.date.addingTimeInterval(1)
        )
        _ = try await setup.owner.synchronize(at: WorkTestValues.date.addingTimeInterval(1))

        let localSnapshot = try WorkTestValues.snapshot { $0.title = "local title" }
        _ = try await stageAndConfirm(
            setup.follower,
            snapshot: localSnapshot,
            at: WorkTestValues.date.addingTimeInterval(2)
        )
        guard case let .automaticallyMerged(firstMerge) = try await setup.follower.synchronize(
            at: WorkTestValues.date.addingTimeInterval(3)
        ) else {
            Issue.record("disjoint divergence did not create pending merge")
            return
        }

        let tailSnapshot = try WorkTestValues.snapshot { document in
            document.title = "local title"
            document.characters[0].memo = "tail while merge waits"
        }
        _ = try await stageAndConfirm(
            setup.follower,
            snapshot: tailSnapshot,
            at: WorkTestValues.date.addingTimeInterval(4)
        )
        let beforeRestart = try await setup.follower.currentState()
        let rebased = try #require(beforeRestart.pendingRemoteMaterialization?.revision)
        #expect(!rebased.parentRevisionIDs.contains(firstMerge.revisionID))
        #expect(rebased.parentRevisionIDs.contains(remote.revisionID))

        let restarted = WorkTestValues.coordinator(
            server: setup.server,
            journal: setup.followerJournal,
            copy: WorkTestValues.copyB,
            replica: WorkTestValues.replicaB,
            session: SyncEditSessionID()
        )
        _ = try await restarted.restore()
        let restoredPending = try #require(
            try await restarted.currentState().pendingRemoteMaterialization
        )
        try await restarted.acknowledgeRemoteMaterialization(
            restoredPending.revision.revisionID,
            packageSnapshot: restoredPending.revision.snapshot
        )
        _ = try await restarted.synchronize(at: WorkTestValues.date.addingTimeInterval(5))

        let head = try #require(await setup.server.currentHead(for: WorkTestValues.workID))
        #expect(head.snapshot.title == "local title")
        #expect(head.snapshot.synopsis == "remote synopsis")
        #expect(head.snapshot.characters.first?.memo == "tail while merge waits")
    }

    @Test("remote fast-forward pending accepts local editor input without injecting remote into the package")
    func remoteFastForwardTail() async throws {
        let setup = try await synchronizedPair()
        let remoteSnapshot = try WorkTestValues.snapshot { $0.synopsis = "remote fast forward" }
        let remote = try await stageAndConfirm(
            setup.owner,
            snapshot: remoteSnapshot,
            at: WorkTestValues.date.addingTimeInterval(1)
        )
        _ = try await setup.owner.synchronize(at: WorkTestValues.date.addingTimeInterval(1))
        guard case .remoteFastForward = try await setup.follower.synchronize(
            at: WorkTestValues.date.addingTimeInterval(2)
        ) else {
            Issue.record("remote descendant was not staged for package materialization")
            return
        }

        let localPackage = try WorkTestValues.snapshot { $0.title = "typed before remote install" }
        _ = try await stageAndConfirm(
            setup.follower,
            snapshot: localPackage,
            at: WorkTestValues.date.addingTimeInterval(3)
        )
        let pending = try #require(
            try await setup.follower.currentState().pendingRemoteMaterialization
        )
        #expect(pending.revision.parentRevisionIDs.contains(remote.revisionID))
        try await setup.follower.acknowledgeRemoteMaterialization(
            pending.revision.revisionID,
            packageSnapshot: pending.revision.snapshot
        )
        _ = try await setup.follower.synchronize(at: WorkTestValues.date.addingTimeInterval(4))
        let head = try #require(await setup.server.currentHead(for: WorkTestValues.workID))
        #expect(head.snapshot.title == "typed before remote install")
        #expect(head.snapshot.synopsis == "remote fast forward")
    }

    @Test("conflict-resolution pending can be edited before package install and publishes a valid graph")
    func conflictResolutionTail() async throws {
        let setup = try await synchronizedPair()
        let remoteSnapshot = try WorkTestValues.snapshot { $0.title = "remote title" }
        _ = try await stageAndConfirm(
            setup.owner,
            snapshot: remoteSnapshot,
            at: WorkTestValues.date.addingTimeInterval(1)
        )
        _ = try await setup.owner.synchronize(at: WorkTestValues.date.addingTimeInterval(1))
        let localSnapshot = try WorkTestValues.snapshot { $0.title = "local title" }
        _ = try await stageAndConfirm(
            setup.follower,
            snapshot: localSnapshot,
            at: WorkTestValues.date.addingTimeInterval(2)
        )
        guard case .reviewRequired = try await setup.follower.synchronize(
            at: WorkTestValues.date.addingTimeInterval(3)
        ) else {
            Issue.record("same field divergence did not require review")
            return
        }
        _ = try await setup.follower.resolveConflict(
            .keepLocal,
            at: WorkTestValues.date.addingTimeInterval(4)
        )

        let tail = try WorkTestValues.snapshot { document in
            document.title = "local title"
            document.worldNotes[0].content = "tail after choice"
        }
        _ = try await stageAndConfirm(
            setup.follower,
            snapshot: tail,
            at: WorkTestValues.date.addingTimeInterval(5)
        )
        let pending = try #require(
            try await setup.follower.currentState().pendingRemoteMaterialization
        )
        try await setup.follower.acknowledgeRemoteMaterialization(
            pending.revision.revisionID,
            packageSnapshot: pending.revision.snapshot
        )
        _ = try await setup.follower.synchronize(at: WorkTestValues.date.addingTimeInterval(6))
        let head = try #require(await setup.server.currentHead(for: WorkTestValues.workID))
        #expect(head.snapshot.title == "local title")
        #expect(head.snapshot.worldNotes.first?.content == "tail after choice")
    }

    @Test("unselected staged recovery snapshot remains durable until selected merge is remotely acknowledged")
    func recoveryEvidenceRetainedUntilAck() async throws {
        let setup = try await synchronizedPair()
        let remoteSnapshot = try WorkTestValues.snapshot { $0.synopsis = "remote" }
        _ = try await stageAndConfirm(
            setup.owner,
            snapshot: remoteSnapshot,
            at: WorkTestValues.date.addingTimeInterval(1)
        )
        _ = try await setup.owner.synchronize(at: WorkTestValues.date.addingTimeInterval(1))
        let local = try WorkTestValues.snapshot { $0.title = "local" }
        _ = try await stageAndConfirm(
            setup.follower,
            snapshot: local,
            at: WorkTestValues.date.addingTimeInterval(2)
        )
        guard case .automaticallyMerged = try await setup.follower.synchronize(
            at: WorkTestValues.date.addingTimeInterval(3)
        ) else {
            Issue.record("expected pending merge")
            return
        }
        let unselected = try WorkTestValues.snapshot { $0.title = "staged recovery evidence" }
        let staged = try await setup.follower.stageLocalSnapshot(
            unselected,
            at: WorkTestValues.date.addingTimeInterval(4)
        )
        let observedThird = try WorkTestValues.snapshot { $0.title = "third package value" }
        guard case .reviewRequired = try await setup.follower.reconcileLocalMaterialization(
            packageSnapshot: observedThird,
            at: WorkTestValues.date.addingTimeInterval(5)
        ) else {
            Issue.record("third package value did not require local recovery review")
            return
        }
        guard case let .materializeRemote(selected) = try await setup.follower.resolveLocalRecovery(
            .materializePendingRemote,
            observedPackageSnapshot: observedThird,
            at: WorkTestValues.date.addingTimeInterval(6)
        ) else {
            Issue.record("pending merge was not selected")
            return
        }
        #expect(try await setup.follower.currentState().retainedLocalRecoveryRevision == staged)
        try await setup.follower.acknowledgeRemoteMaterialization(
            selected.revision.revisionID,
            packageSnapshot: selected.revision.snapshot
        )
        #expect(try await setup.follower.currentState().retainedLocalRecoveryRevision == staged)

        let restarted = WorkTestValues.coordinator(
            server: setup.server,
            journal: setup.followerJournal,
            copy: WorkTestValues.copyB,
            replica: WorkTestValues.replicaB,
            session: SyncEditSessionID()
        )
        _ = try await restarted.restore()
        #expect(try await restarted.currentState().retainedLocalRecoveryRevision == staged)
        _ = try await restarted.synchronize(at: WorkTestValues.date.addingTimeInterval(7))
        #expect(try await restarted.currentState().retainedLocalRecoveryRevision == nil)
    }

    @Test("observed-package recovery choice commits atomically and retains the original staged evidence")
    func observedRecoveryChoiceIsAtomic() async throws {
        let setup = try await synchronizedPair()
        let remoteSnapshot = try WorkTestValues.snapshot { $0.synopsis = "remote change" }
        _ = try await stageAndConfirm(
            setup.owner,
            snapshot: remoteSnapshot,
            at: WorkTestValues.date.addingTimeInterval(1)
        )
        _ = try await setup.owner.synchronize(at: WorkTestValues.date.addingTimeInterval(1))

        let local = try WorkTestValues.snapshot { $0.title = "local source" }
        _ = try await stageAndConfirm(
            setup.follower,
            snapshot: local,
            at: WorkTestValues.date.addingTimeInterval(2)
        )
        guard case .automaticallyMerged = try await setup.follower.synchronize(
            at: WorkTestValues.date.addingTimeInterval(3)
        ) else {
            Issue.record("expected pending automatic merge")
            return
        }

        let originalStagedSnapshot = try WorkTestValues.snapshot { $0.title = "staged A" }
        let originalStaged = try await setup.follower.stageLocalSnapshot(
            originalStagedSnapshot,
            at: WorkTestValues.date.addingTimeInterval(4)
        )
        let observedPackage = try WorkTestValues.snapshot { $0.title = "observed B" }
        guard case .reviewRequired = try await setup.follower.reconcileLocalMaterialization(
            packageSnapshot: observedPackage,
            at: WorkTestValues.date.addingTimeInterval(5)
        ) else {
            Issue.record("third package value did not require recovery review")
            return
        }
        let preResolutionRecord = try #require(
            await setup.followerJournal.storedRecord(for: WorkTestValues.workID)
        )

        // The previous implementation performed two saves here. Failing the
        // second left staged B in the journal while the visible review still
        // referred to staged A. A single atomic transition never reaches it.
        await setup.followerJournal.failSave(afterSuccessfulSaves: 1)
        guard case let .capturedUnstagedPackage(observedRevision) = try await setup.follower.resolveLocalRecovery(
            .keepObservedPackage,
            observedPackageSnapshot: observedPackage,
            at: WorkTestValues.date.addingTimeInterval(6)
        ) else {
            Issue.record("observed package was not captured atomically")
            return
        }
        let state = try await setup.follower.currentState()
        #expect(observedRevision.snapshot == observedPackage)
        #expect(state.localHead == observedRevision)
        #expect(state.stagedLocalRevision == nil)
        #expect(state.retainedLocalRecoveryRevision == originalStaged)
        #expect(state.pendingRemoteMaterialization != nil)
        let stored = try #require(await setup.followerJournal.storedRecord(for: WorkTestValues.workID))
        #expect(stored.localHead == observedRevision)
        #expect(stored.stagedLocalRevision == nil)
        #expect(stored.retainedLocalRecoveryRevision == originalStaged)

        // Harden retry from a journal written by the former two-save path:
        // retained=A, staged=observed B. Choosing remote must not replace A
        // with B either at selection or package acknowledgement.
        await setup.followerJournal.cancelScheduledSaveFailure()
        var legacyIntermediate = preResolutionRecord
        legacyIntermediate.retainedLocalRecoveryRevision = originalStaged
        legacyIntermediate.stagedLocalRevision = observedRevision
        legacyIntermediate.conflictReview = nil
        legacyIntermediate.reconciliationStatus = .materializationRequired
        try await setup.followerJournal.save(legacyIntermediate)
        let restarted = WorkTestValues.coordinator(
            server: setup.server,
            journal: setup.followerJournal,
            copy: WorkTestValues.copyB,
            replica: WorkTestValues.replicaB,
            session: SyncEditSessionID()
        )
        _ = try await restarted.restore()
        guard case let .materializeRemote(selectedRemote) = try await restarted.resolveLocalRecovery(
            .materializePendingRemote,
            observedPackageSnapshot: observedPackage,
            at: WorkTestValues.date.addingTimeInterval(7)
        ) else {
            Issue.record("retry did not preserve the selected remote materialization")
            return
        }
        #expect(try await restarted.currentState().retainedLocalRecoveryRevision == originalStaged)
        try await restarted.acknowledgeRemoteMaterialization(
            selectedRemote.revision.revisionID,
            packageSnapshot: selectedRemote.revision.snapshot
        )
        let retriedState = try await restarted.currentState()
        #expect(retriedState.stagedLocalRevision == nil)
        #expect(retriedState.retainedLocalRecoveryRevision == originalStaged)
    }

    @Test("unpublished conflict choice plus overlapping tail re-reviews then rebases choice to actual remote")
    func conflictChoiceOverlapTailRebasesToActualRemote() async throws {
        let setup = try await synchronizedPair()
        let remoteSnapshot = try WorkTestValues.snapshot { $0.title = "remote title" }
        let actualRemote = try await stageAndConfirm(
            setup.owner,
            snapshot: remoteSnapshot,
            at: WorkTestValues.date.addingTimeInterval(1)
        )
        _ = try await setup.owner.synchronize(at: WorkTestValues.date.addingTimeInterval(1))
        let localSnapshot = try WorkTestValues.snapshot { $0.title = "local title" }
        _ = try await stageAndConfirm(
            setup.follower,
            snapshot: localSnapshot,
            at: WorkTestValues.date.addingTimeInterval(2)
        )
        guard case .reviewRequired = try await setup.follower.synchronize(
            at: WorkTestValues.date.addingTimeInterval(3)
        ) else {
            Issue.record("initial title conflict missing")
            return
        }
        let unpublishedChoice = try await setup.follower.resolveConflict(
            .keepRemote,
            at: WorkTestValues.date.addingTimeInterval(4)
        )
        let overlappingTail = try WorkTestValues.snapshot { $0.title = "tail title" }
        _ = try await stageAndConfirm(
            setup.follower,
            snapshot: overlappingTail,
            at: WorkTestValues.date.addingTimeInterval(5)
        )
        let review = try #require(try await setup.follower.currentState().conflictReview)
        #expect(review.remote.revisionID == unpublishedChoice.revisionID)

        let restarted = WorkTestValues.coordinator(
            server: setup.server,
            journal: setup.followerJournal,
            copy: WorkTestValues.copyB,
            replica: WorkTestValues.replicaB,
            session: SyncEditSessionID()
        )
        _ = try await restarted.restore()
        let finalChoice = try await restarted.resolveConflict(
            .keepLocal,
            at: WorkTestValues.date.addingTimeInterval(6)
        )
        #expect(finalChoice.parentRevisionIDs.contains(actualRemote.revisionID))
        #expect(!finalChoice.parentRevisionIDs.contains(unpublishedChoice.revisionID))
        try await restarted.acknowledgeRemoteMaterialization(
            finalChoice.revisionID,
            packageSnapshot: finalChoice.snapshot
        )
        _ = try await restarted.synchronize(at: WorkTestValues.date.addingTimeInterval(7))
        #expect(await setup.server.currentHead(for: WorkTestValues.workID)?.snapshot.title == "tail title")
    }

    @Test("automatic pending overlap tail re-review publishes without the unpublished merge as a parent")
    func automaticPendingOverlapTailRebasesToActualRemote() async throws {
        let setup = try await synchronizedPair()
        let remoteSnapshot = try WorkTestValues.snapshot { $0.synopsis = "remote synopsis" }
        let actualRemote = try await stageAndConfirm(
            setup.owner,
            snapshot: remoteSnapshot,
            at: WorkTestValues.date.addingTimeInterval(1)
        )
        _ = try await setup.owner.synchronize(at: WorkTestValues.date.addingTimeInterval(1))
        let localSnapshot = try WorkTestValues.snapshot { $0.title = "local title" }
        _ = try await stageAndConfirm(
            setup.follower,
            snapshot: localSnapshot,
            at: WorkTestValues.date.addingTimeInterval(2)
        )
        guard case let .automaticallyMerged(unpublishedMerge) = try await setup.follower.synchronize(
            at: WorkTestValues.date.addingTimeInterval(3)
        ) else {
            Issue.record("automatic pending merge missing")
            return
        }
        let overlappingTail = try WorkTestValues.snapshot { document in
            document.title = "local title"
            document.synopsis = "tail synopsis"
        }
        _ = try await stageAndConfirm(
            setup.follower,
            snapshot: overlappingTail,
            at: WorkTestValues.date.addingTimeInterval(4)
        )
        #expect(try await setup.follower.currentState().conflictReview != nil)
        let finalChoice = try await setup.follower.resolveConflict(
            .keepLocal,
            at: WorkTestValues.date.addingTimeInterval(5)
        )
        #expect(finalChoice.parentRevisionIDs.contains(actualRemote.revisionID))
        #expect(!finalChoice.parentRevisionIDs.contains(unpublishedMerge.revisionID))
        try await setup.follower.acknowledgeRemoteMaterialization(
            finalChoice.revisionID,
            packageSnapshot: finalChoice.snapshot
        )
        _ = try await setup.follower.synchronize(at: WorkTestValues.date.addingTimeInterval(6))
        let head = try #require(await setup.server.currentHead(for: WorkTestValues.workID))
        #expect(head.snapshot.title == "local title")
        #expect(head.snapshot.synopsis == "tail synopsis")
    }

    @Test("two subway editors reconnect and retain independent whole-work metadata edits")
    func twoReplicaSubwayReconnect() async throws {
        let setup = try await synchronizedPair()
        await setup.server.setOnline(false)
        let ownerEdit = try WorkTestValues.snapshot { $0.title = "owner subway title" }
        _ = try await stageAndConfirm(
            setup.owner,
            snapshot: ownerEdit,
            at: WorkTestValues.date.addingTimeInterval(1)
        )
        let followerEdit = try WorkTestValues.snapshot { $0.characters[0].memo = "follower subway memo" }
        _ = try await stageAndConfirm(
            setup.follower,
            snapshot: followerEdit,
            at: WorkTestValues.date.addingTimeInterval(2)
        )
        guard case .offline = try await setup.owner.synchronize(at: WorkTestValues.date) else {
            Issue.record("owner was not offline")
            return
        }
        guard case .offline = try await setup.follower.synchronize(at: WorkTestValues.date) else {
            Issue.record("follower was not offline")
            return
        }

        await setup.server.setOnline(true)
        _ = try await setup.owner.synchronize(at: WorkTestValues.date.addingTimeInterval(3))
        guard case .automaticallyMerged = try await setup.follower.synchronize(
            at: WorkTestValues.date.addingTimeInterval(4)
        ) else {
            Issue.record("independent subway edits did not auto-merge")
            return
        }
        let pending = try #require(
            try await setup.follower.currentState().pendingRemoteMaterialization
        )
        try await setup.follower.acknowledgeRemoteMaterialization(
            pending.revision.revisionID,
            packageSnapshot: pending.revision.snapshot
        )
        _ = try await setup.follower.synchronize(at: WorkTestValues.date.addingTimeInterval(5))
        let head = try #require(await setup.server.currentHead(for: WorkTestValues.workID))
        #expect(head.snapshot.title == "owner subway title")
        #expect(head.snapshot.characters.first?.memo == "follower subway memo")
    }

    @Test("sealed two-parent batch plus editor tail rebases when remote advances during publish")
    func sealedMergeBatchTailRemoteAdvance() async throws {
        let setup = try await synchronizedPair()
        let remoteOneSnapshot = try WorkTestValues.snapshot { $0.synopsis = "remote one" }
        _ = try await stageAndConfirm(
            setup.owner,
            snapshot: remoteOneSnapshot,
            at: WorkTestValues.date.addingTimeInterval(1)
        )
        _ = try await setup.owner.synchronize(at: WorkTestValues.date.addingTimeInterval(1))
        let localSnapshot = try WorkTestValues.snapshot { $0.title = "local source" }
        _ = try await stageAndConfirm(
            setup.follower,
            snapshot: localSnapshot,
            at: WorkTestValues.date.addingTimeInterval(2)
        )
        guard case .automaticallyMerged = try await setup.follower.synchronize(
            at: WorkTestValues.date.addingTimeInterval(3)
        ) else {
            Issue.record("expected first merge")
            return
        }
        let firstPending = try #require(
            try await setup.follower.currentState().pendingRemoteMaterialization
        )
        try await setup.follower.acknowledgeRemoteMaterialization(
            firstPending.revision.revisionID,
            packageSnapshot: firstPending.revision.snapshot
        )
        #expect(try await setup.follower.currentState().pendingRevisionCount == 2)

        await setup.server.pauseNextPublish()
        let publishing = Task {
            try await setup.follower.synchronize(at: WorkTestValues.date.addingTimeInterval(4))
        }
        #expect(await waitUntil { await setup.server.publishIsPaused() })
        var tailDocument = try firstPending.revision.snapshot.materializedDocument()
        tailDocument.characters[0].memo = "tail during sealed merge"
        let tailSnapshot = try WorkSnapshot(document: tailDocument)
        _ = try await stageAndConfirm(
            setup.follower,
            snapshot: tailSnapshot,
            at: WorkTestValues.date.addingTimeInterval(5)
        )
        #expect(try await setup.follower.currentState().pendingRevisionCount == 3)

        var remoteTwoDocument = try remoteOneSnapshot.materializedDocument()
        remoteTwoDocument.worldNotes[0].content = "remote two advance"
        let remoteTwoSnapshot = try WorkSnapshot(document: remoteTwoDocument)
        _ = try await stageAndConfirm(
            setup.owner,
            snapshot: remoteTwoSnapshot,
            at: WorkTestValues.date.addingTimeInterval(6)
        )
        _ = try await setup.owner.synchronize(at: WorkTestValues.date.addingTimeInterval(6))
        await setup.server.resumePausedPublish()
        guard case .automaticallyMerged = try await publishing.value else {
            Issue.record("advanced remote did not rebase sealed local tail")
            return
        }
        let rebasedState = try await setup.follower.currentState()
        #expect(rebasedState.pendingRevisionCount == 1)
        let rebased = try #require(rebasedState.pendingRemoteMaterialization)
        try await setup.follower.acknowledgeRemoteMaterialization(
            rebased.revision.revisionID,
            packageSnapshot: rebased.revision.snapshot
        )
        _ = try await setup.follower.synchronize(at: WorkTestValues.date.addingTimeInterval(7))
        let head = try #require(await setup.server.currentHead(for: WorkTestValues.workID))
        #expect(head.snapshot.title == "local source")
        #expect(head.snapshot.synopsis == "remote one")
        #expect(head.snapshot.characters.first?.memo == "tail during sealed merge")
        #expect(head.snapshot.worldNotes.first?.content == "remote two advance")
    }

    @Test("conflict review recovers a package committed after stage-marker failure")
    func conflictReviewStageFailureRecoversPackage() async throws {
        let setup = try await synchronizedPair()
        let remoteSnapshot = try WorkTestValues.snapshot { $0.title = "remote conflict" }
        _ = try await stageAndConfirm(
            setup.owner,
            snapshot: remoteSnapshot,
            at: WorkTestValues.date.addingTimeInterval(1)
        )
        _ = try await setup.owner.synchronize(at: WorkTestValues.date.addingTimeInterval(1))
        let localSnapshot = try WorkTestValues.snapshot { $0.title = "local conflict" }
        _ = try await stageAndConfirm(
            setup.follower,
            snapshot: localSnapshot,
            at: WorkTestValues.date.addingTimeInterval(2)
        )
        guard case .reviewRequired = try await setup.follower.synchronize(
            at: WorkTestValues.date.addingTimeInterval(3)
        ) else {
            Issue.record("expected review")
            return
        }

        let packageAfterFailedMarker = try WorkTestValues.snapshot { $0.title = "package after failed marker" }
        await setup.followerJournal.failNextSave()
        await #expect(throws: InMemoryWorkSyncJournalError.self) {
            _ = try await setup.follower.stageLocalSnapshot(
                packageAfterFailedMarker,
                at: WorkTestValues.date.addingTimeInterval(4)
            )
        }
        let restarted = WorkTestValues.coordinator(
            server: setup.server,
            journal: setup.followerJournal,
            copy: WorkTestValues.copyB,
            replica: WorkTestValues.replicaB,
            session: SyncEditSessionID()
        )
        _ = try await restarted.restore()
        guard case let .capturedUnstagedPackage(captured) = try await restarted.reconcileLocalMaterialization(
            packageSnapshot: packageAfterFailedMarker,
            at: WorkTestValues.date.addingTimeInterval(5)
        ) else {
            Issue.record("package was not captured into the active review")
            return
        }
        let state = try await restarted.currentState()
        #expect(captured.snapshot == packageAfterFailedMarker)
        #expect(state.localHead == captured)
        #expect(state.conflictReview?.local == captured)
        #expect(state.conflictReview?.remote.snapshot == remoteSnapshot)
    }
}

private struct SynchronizedWorkPair {
    let server: InMemoryWorkSyncServer
    let owner: WorkSyncCoordinator
    let follower: WorkSyncCoordinator
    let followerJournal: InMemoryWorkSyncJournal
}

private func synchronizedPair() async throws -> SynchronizedWorkPair {
    let server = InMemoryWorkSyncServer()
    let owner = WorkTestValues.coordinator(server: server, journal: InMemoryWorkSyncJournal())
    let baseSnapshot = try WorkTestValues.snapshot()
    let base = try await owner.bootstrapLocalSnapshot(baseSnapshot, at: WorkTestValues.date)
    _ = try await owner.synchronize(at: WorkTestValues.date)

    let followerJournal = InMemoryWorkSyncJournal()
    let follower = WorkTestValues.coordinator(
        server: server,
        journal: followerJournal,
        copy: WorkTestValues.copyB,
        replica: WorkTestValues.replicaB,
        session: WorkTestValues.sessionB
    )
    let pending = try await follower.bootstrapRemoteRevision(base)
    try await follower.acknowledgeRemoteMaterialization(
        pending.revision.revisionID,
        packageSnapshot: baseSnapshot
    )
    return SynchronizedWorkPair(
        server: server,
        owner: owner,
        follower: follower,
        followerJournal: followerJournal
    )
}

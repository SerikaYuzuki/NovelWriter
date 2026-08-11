import Foundation

public extension EpisodeSyncCoordinator {
    /// 利用者が選んだ本文とexactな2-parent ancestryをjournalへ固定する。
    /// networkへは触れず、返却時点ではnative/packageへの反映もremote publishも未完了。
    @discardableResult
    func stageConflictResolutionLocalFirst(
        expectedConflict: EpisodeConflict,
        choice: EpisodeIntegrationChoice,
        createdAt: Date
    ) async throws -> EpisodeConflictResolutionMaterialization {
        await acquireLocalJournalOperation()
        defer { releaseLocalJournalOperation() }
        guard var current = try await loadLocalRecordIfNecessary() else {
            throw EpisodeSyncCoordinatorError.notLinked
        }
        guard current.conflict == expectedConflict else {
            throw EpisodeSyncCoordinatorError.conflictSuperseded
        }
        let chosen = try makeRevision(
            content: choice.resolvedContent(for: expectedConflict),
            parents: [
                expectedConflict.remote.revisionID,
                expectedConflict.local.revisionID
            ],
            branchID: current.branchID,
            createdAt: createdAt
        )
        current.stagedConflictResolution = chosen
        current.remoteConfirmation = .unconfirmed
        current.localEditIntent = .explicit
        current.reconciliationStatus = .reviewRequired
        current.mode = .forcedFork
        record = current
        try await journal.save(current)
        state = stateForRecord(current)
        return conflictResolutionMaterialization(conflict: expectedConflict, chosen: chosen)
    }

    /// Appがchosen本文をnative/packageへexactに反映した後のlocal durability ack。
    /// remote publishは行わず、元の両本文とchosenはremote ackまでjournalへ保持する。
    @discardableResult
    func confirmStagedConflictResolutionMaterialized(
        _ expected: EpisodeConflictResolutionMaterialization,
        installedContentDigest: SyncContentDigest
    ) async throws -> EpisodeSyncState {
        await acquireLocalJournalOperation()
        defer { releaseLocalJournalOperation() }
        guard var current = try await loadLocalRecordIfNecessary() else {
            throw EpisodeSyncCoordinatorError.notLinked
        }
        try validateConflictResolutionMaterialization(expected, record: current)
        guard installedContentDigest == expected.chosenRevision.contentDigest else {
            throw EpisodeSyncCoordinatorError.installedDigestMismatch
        }
        materializeStagedConflictResolution(expected, record: &current)
        record = current
        try await journal.save(current)
        state = stateForRecord(current)
        return state
    }

    /// source互換用。networkへは進まず、二段階APIのstageだけを行う。
    @available(*, deprecated, message: "Use stageConflictResolutionLocalFirst, materialize, then synchronizeLocalFirst")
    @discardableResult
    func resolveConflictLocalFirst(
        expectedConflict: EpisodeConflict,
        choice: EpisodeIntegrationChoice,
        expiresAt _: Date,
        createdAt: Date
    ) async throws -> EpisodeSyncState {
        _ = try await stageConflictResolutionLocalFirst(
            expectedConflict: expectedConflict,
            choice: choice,
            createdAt: createdAt
        )
        return state
    }
}

extension EpisodeSyncCoordinator {
    struct LocalFirstConflictResolutionStage: Equatable {
        let sourceConflict: EpisodeConflict
        let expectedRemoteHead: EpisodeRevision
        let chosenRevision: EpisodeRevision
    }

    func conflictResolutionMaterialization(
        conflict: EpisodeConflict,
        chosen: EpisodeRevision
    ) -> EpisodeConflictResolutionMaterialization {
        EpisodeConflictResolutionMaterialization(
            localWorkingCopyID: localWorkingCopyID,
            sourceConflict: conflict,
            chosenRevision: chosen
        )
    }

    func validateConflictResolutionMaterialization(
        _ expected: EpisodeConflictResolutionMaterialization,
        record: EpisodeSyncJournalRecord
    ) throws {
        guard expected.localWorkingCopyID == localWorkingCopyID,
              record.localWorkingCopyID == localWorkingCopyID,
              record.conflict == expected.sourceConflict,
              record.stagedConflictResolution == expected.chosenRevision else {
            throw EpisodeSyncCoordinatorError.materializationNotPending
        }
    }

    func materializeStagedConflictResolution(
        _ expected: EpisodeConflictResolutionMaterialization,
        record: inout EpisodeSyncJournalRecord
    ) {
        let conflict = expected.sourceConflict
        let chosen = expected.chosenRevision
        let priorRecovery = record.conflictResolutionRecovery
        let expectedRemoteHead = expectedRemoteHeadForResolution(
            conflict: conflict,
            record: record
        )
        if let priorRecovery {
            record.pendingRevisions = rebuiltResolutionAncestry(
                conflict: conflict,
                recovery: priorRecovery
            )
        }
        let remoteIsAlreadyPublished = conflict.remote.revisionID
            == expectedRemoteHead.revisionID
        if !remoteIsAlreadyPublished,
           !record.pendingRevisions.contains(conflict.remote) {
            record.pendingRevisions.append(conflict.remote)
        }
        if conflict.local.revisionID != record.lastKnownRemoteHead?.revisionID,
           !record.pendingRevisions.contains(conflict.local) {
            record.pendingRevisions.append(conflict.local)
        }
        if !record.pendingRevisions.contains(chosen) {
            record.pendingRevisions.append(chosen)
        }
        record.localHead = chosen
        record.conflictResolutionRecovery = EpisodeConflictResolutionRecovery(
            sourceLocalRevision: priorRecovery?.sourceLocalRevision ?? conflict.local,
            sourceRemoteRevision: priorRecovery?.sourceRemoteRevision ?? conflict.remote,
            chosenRevision: chosen,
            supersededChosenRevision: priorRecovery?.chosenRevision
        )
        record.conflict = nil
        record.integrationReviewDraft = nil
        record.pendingMaterialization = nil
        record.lastKnownRemoteHead = expectedRemoteHead
        record.remoteConfirmation = .unconfirmed
        record.localEditIntent = .explicit
        record.reconciliationStatus = .pending
        record.mode = .forcedFork
    }

    func rebuiltResolutionAncestry(
        conflict: EpisodeConflict,
        recovery: EpisodeConflictResolutionRecovery
    ) -> [EpisodeRevision] {
        var ancestry = [recovery.sourceLocalRevision]
        if conflict.local != recovery.sourceLocalRevision {
            if conflict.local != recovery.chosenRevision,
               conflict.local.parentRevisionIDs.contains(recovery.chosenRevision.revisionID) {
                ancestry.append(recovery.chosenRevision)
            }
            ancestry.append(conflict.local)
        }
        return ancestry
    }

    func expectedRemoteHeadForResolution(
        conflict: EpisodeConflict,
        record: EpisodeSyncJournalRecord
    ) -> EpisodeRevision {
        let remoteIsPending = record.pendingRevisions.contains {
            $0.revisionID == conflict.remote.revisionID
        }
        if remoteIsPending, let lastKnownRemoteHead = record.lastKnownRemoteHead {
            return lastKnownRemoteHead
        }
        return conflict.remote
    }

    func pendingLocalFirstConflictResolutionStage(
        in record: EpisodeSyncJournalRecord
    ) throws -> LocalFirstConflictResolutionStage? {
        guard record.conflict == nil,
              let chosen = record.stagedConflictResolution,
              let recovery = record.conflictResolutionRecovery else {
            return nil
        }
        guard chosen == recovery.chosenRevision,
              chosen.parentRevisionIDs.count == 2,
              let remoteParent = storedResolutionRevision(
                  chosen.parentRevisionIDs[0],
                  record: record
              ),
              let localParent = storedResolutionRevision(
                  chosen.parentRevisionIDs[1],
                  record: record
              ) else {
            throw EpisodeSyncJournalError.reviewDraftMismatch
        }
        let sourceConflict = EpisodeConflict(
            base: nil,
            local: localParent,
            remote: remoteParent
        )
        return LocalFirstConflictResolutionStage(
            sourceConflict: sourceConflict,
            expectedRemoteHead: record.lastKnownRemoteHead ?? remoteParent,
            chosenRevision: chosen
        )
    }

    func storedResolutionRevision(
        _ revisionID: SyncRevisionID,
        record: EpisodeSyncJournalRecord
    ) -> EpisodeRevision? {
        record.pendingRevisions.first { $0.revisionID == revisionID }
            ?? [
                record.lastKnownRemoteHead,
                record.conflictResolutionRecovery?.sourceLocalRevision,
                record.conflictResolutionRecovery?.sourceRemoteRevision,
                record.conflictResolutionRecovery?.chosenRevision,
                record.conflictResolutionRecovery?.supersededChosenRevision
            ]
            .compactMap(\.self)
            .first { $0.revisionID == revisionID }
    }
}

extension EpisodeSyncCoordinator {
    func publishMaterializedConflictResolution(
        _ staged: LocalFirstConflictResolutionStage,
        expiresAt: Date
    ) async throws -> EpisodeSyncState {
        let snapshot: EpisodeRemoteSnapshot
        do {
            snapshot = try await transport.fetchSnapshot(for: key)
            try validateLocalFirstSnapshot(snapshot)
            try await markLocalFirstReconnected()
        } catch EpisodeSyncTransportError.unavailable {
            return try await preserveOfflineState()
        }
        guard snapshot.head == staged.expectedRemoteHead else {
            return try await preserveSupersededConflictResolution(staged, snapshot: snapshot)
        }
        guard let granted = try await acquireLocalFirstAuthority(
            matching: snapshot,
            expiresAt: expiresAt
        ) else {
            return try await stateAfterRejectedConflictResolution(staged)
        }
        return try await activateAndPublishConflictResolution(staged, granted: granted)
    }

    func activateAndPublishConflictResolution(
        _ staged: LocalFirstConflictResolutionStage,
        granted: EpisodeRemoteSnapshot
    ) async throws -> EpisodeSyncState {
        await acquireLocalJournalOperation()
        guard var current = try await loadLocalRecordIfNecessary() else {
            releaseLocalJournalOperation()
            throw EpisodeSyncCoordinatorError.notLinked
        }
        guard let latest = try pendingLocalFirstConflictResolutionStage(in: current),
              latest == staged else {
            releaseLocalJournalOperation()
            try await releaseUnusedLocalFirstGrant(granted)
            return stateForRecord(current)
        }
        do {
            try appendCurrentSessionRelayIfNeeded(record: &current)
            try activateLocalFirstAuthority(granted, record: &current)
            record = current
            try await journal.save(current)
            releaseLocalJournalOperation()
        } catch {
            releaseLocalJournalOperation()
            throw error
        }
        return try await drainLocalFirstPublishTail()
    }

    func appendCurrentSessionRelayIfNeeded(
        record: inout EpisodeSyncJournalRecord
    ) throws {
        let head = record.localHead
        guard head.authorReplicaID != replicaID || head.authorSessionID != sessionID else { return }
        let relay = try makeRevision(
            content: head.content,
            parents: [head.revisionID],
            branchID: record.branchID,
            createdAt: head.clientCreatedAt
        )
        record.pendingRevisions.append(relay)
        record.localHead = relay
    }

    func stateAfterRejectedConflictResolution(
        _ staged: LocalFirstConflictResolutionStage
    ) async throws -> EpisodeSyncState {
        do {
            let latest = try await transport.fetchSnapshot(for: key)
            try validateLocalFirstSnapshot(latest)
            if latest.head != staged.expectedRemoteHead {
                return try await preserveSupersededConflictResolution(staged, snapshot: latest)
            }
        } catch EpisodeSyncTransportError.unavailable {
            return try await preserveOfflineState()
        }
        guard let current = record else { throw EpisodeSyncCoordinatorError.notLinked }
        state = stateForRecord(current)
        return state
    }

    func preserveSupersededConflictResolution(
        _ staged: LocalFirstConflictResolutionStage,
        snapshot: EpisodeRemoteSnapshot
    ) async throws -> EpisodeSyncState {
        guard let remote = snapshot.head else {
            throw EpisodeSyncCoordinatorError.malformedRemoteSnapshot
        }
        await acquireLocalJournalOperation()
        defer { releaseLocalJournalOperation() }
        guard var current = try await loadLocalRecordIfNecessary(),
              current.stagedConflictResolution == staged.chosenRevision else {
            let currentState = record.map(stateForRecord) ?? .unlinked
            state = currentState
            return currentState
        }
        transitionConflictResolutionToReview(
            remote: remote,
            lease: snapshot.lease,
            record: &current
        )
        record = current
        try await journal.save(current)
        state = stateForRecord(current)
        return state
    }

    func releaseUnusedLocalFirstGrant(_ granted: EpisodeRemoteSnapshot) async throws {
        guard let authority = granted.lease?.authority else { return }
        _ = try await transport.releaseLease(key: key, expectedAuthority: authority)
    }
}

extension EpisodeSyncCoordinator {
    func preserveStagedConflictResolutionBeforeEdit(
        record: inout EpisodeSyncJournalRecord
    ) {
        guard let conflict = record.conflict,
              let chosen = record.stagedConflictResolution else {
            return
        }
        record.conflictResolutionRecovery = EpisodeConflictResolutionRecovery(
            sourceLocalRevision: conflict.local,
            sourceRemoteRevision: conflict.remote,
            chosenRevision: chosen
        )
        record.stagedConflictResolution = nil
    }

    func transitionConflictResolutionToReview(
        remote: EpisodeRevision,
        lease: EpisodeLease?,
        record: inout EpisodeSyncJournalRecord
    ) {
        guard let recovery = record.conflictResolutionRecovery else { return }
        let conflict = EpisodeConflict(
            base: nil,
            local: record.localHead,
            remote: remote
        )
        record.pendingRevisions.removeAll()
        record.sealedPublish = nil
        record.pendingMaterialization = nil
        record.stagedConflictResolution = nil
        record.lastKnownRemoteHead = nil
        record.lease = lease
        record.conflict = conflict
        record.integrationReviewDraft = makeReviewDraft(
            for: conflict,
            reason: .ambiguousChanges,
            proposedContent: recovery.chosenRevision.content
        )
        record.remoteConfirmation = .unconfirmed
        record.localEditIntent = .explicit
        record.reconciliationStatus = .reviewRequired
        record.mode = .forcedFork
        authorityVerifiedInProcess = false
    }
}

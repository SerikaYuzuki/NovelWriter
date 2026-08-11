import Foundation

extension EpisodeSyncCoordinator {
    func applyDivergence(
        _ current: EpisodeRemoteSnapshot,
        authority: EpisodeLeaseAuthority
    ) async throws {
        await acquireLocalJournalOperation()
        defer { releaseLocalJournalOperation() }
        guard let remote = current.head,
              var latest = record else {
            throw EpisodeSyncCoordinatorError.malformedRemoteSnapshot
        }
        if latest.conflictResolutionRecovery != nil {
            try await saveResolutionConflict(remote: remote, snapshot: current, record: &latest)
            return
        }
        let conflict = EpisodeConflict(
            base: latest.lastKnownRemoteHead,
            local: latest.localHead,
            remote: remote
        )
        latest.sealedPublish = nil
        latest.lease = current.lease
        latest.conflict = conflict
        latest.integrationReviewDraft = makeReviewDraft(
            for: conflict,
            reason: conflict.base == nil ? .commonAncestorUnknown : .ambiguousChanges,
            proposedContent: conflict.local.content
        )
        latest.pendingMaterialization = nil
        latest.remoteConfirmation = .unconfirmed
        latest.reconciliationStatus = .reviewRequired
        record = latest
        if restoredAuthorityRequiresClaim {
            try await applyFenceInLocalJournalLane(current, expectedAuthority: authority)
        } else {
            try await journal.save(latest)
            state = .conflicted(context(for: latest), conflict)
        }
    }

    func applyStaleLease(
        _ current: EpisodeRemoteSnapshot,
        sealed: EpisodeSealedPublish,
        authority: EpisodeLeaseAuthority
    ) async throws {
        await acquireLocalJournalOperation()
        defer { releaseLocalJournalOperation() }
        guard var latest = record else { throw EpisodeSyncCoordinatorError.notLinked }
        if let remote = current.head,
           latest.conflictResolutionRecovery != nil {
            try await saveResolutionConflict(remote: remote, snapshot: current, record: &latest)
            return
        }
        if latest.sealedPublish == sealed {
            latest.sealedPublish = nil
        }
        record = latest
        try await applyFenceInLocalJournalLane(current, expectedAuthority: authority)
    }

    private func saveResolutionConflict(
        remote: EpisodeRevision,
        snapshot: EpisodeRemoteSnapshot,
        record latest: inout EpisodeSyncJournalRecord
    ) async throws {
        transitionConflictResolutionToReview(
            remote: remote,
            lease: snapshot.lease,
            record: &latest
        )
        record = latest
        try await journal.save(latest)
        guard let conflict = latest.conflict else {
            throw EpisodeSyncCoordinatorError.noConflict
        }
        state = .conflicted(context(for: latest), conflict)
    }
}

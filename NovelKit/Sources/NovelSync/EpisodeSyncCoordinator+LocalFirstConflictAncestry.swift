import Foundation

extension EpisodeSyncCoordinator {
    func rebuiltResolutionAncestry(
        conflict: EpisodeConflict,
        recovery: EpisodeConflictResolutionRecovery,
        pendingRevisions: [EpisodeRevision]
    ) throws -> [EpisodeRevision] {
        try orderedKnownResolutionAncestry(
            endingAt: conflict.local,
            pendingRevisions: pendingRevisions,
            supplementalRevisions: [
                recovery.sourceLocalRevision,
                recovery.chosenRevision,
                recovery.supersededChosenRevision,
                conflict.local
            ].compactMap(\.self)
        )
    }

    func orderedKnownResolutionAncestry(
        endingAt head: EpisodeRevision,
        pendingRevisions: [EpisodeRevision],
        supplementalRevisions: [EpisodeRevision]
    ) throws -> [EpisodeRevision] {
        var revisionsByID: [SyncRevisionID: EpisodeRevision] = [:]
        for revision in pendingRevisions + supplementalRevisions + [head] {
            if let existing = revisionsByID[revision.revisionID] {
                guard existing == revision else {
                    throw EpisodeSyncJournalError.pendingChainBroken
                }
            } else {
                revisionsByID[revision.revisionID] = revision
            }
        }

        var ordered: [EpisodeRevision] = []
        var visiting: Set<SyncRevisionID> = []
        var visited: Set<SyncRevisionID> = []
        func appendAncestry(_ revisionID: SyncRevisionID) throws {
            guard let revision = revisionsByID[revisionID] else {
                // A parent absent from the local journal is a remote-known boundary.
                return
            }
            guard !visiting.contains(revisionID) else {
                throw EpisodeSyncJournalError.pendingChainBroken
            }
            guard visited.insert(revisionID).inserted else { return }
            visiting.insert(revisionID)
            for parentRevisionID in revision.parentRevisionIDs {
                try appendAncestry(parentRevisionID)
            }
            visiting.remove(revisionID)
            ordered.append(revision)
        }
        try appendAncestry(head.revisionID)
        return ordered
    }

    func appendResolutionRevision(
        _ revision: EpisodeRevision,
        to revisions: inout [EpisodeRevision]
    ) throws {
        if let existing = revisions.first(where: { $0.revisionID == revision.revisionID }) {
            guard existing == revision else {
                throw EpisodeSyncJournalError.pendingChainBroken
            }
            return
        }
        revisions.append(revision)
    }

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
    ) throws {
        guard let recovery = record.conflictResolutionRecovery else { return }
        let conflict = EpisodeConflict(
            base: nil,
            local: record.localHead,
            remote: remote
        )
        let retainedAncestry = try orderedKnownResolutionAncestry(
            endingAt: record.localHead,
            pendingRevisions: record.pendingRevisions,
            supplementalRevisions: [
                recovery.sourceLocalRevision,
                recovery.chosenRevision,
                recovery.supersededChosenRevision
            ].compactMap(\.self)
        )
        guard retainedAncestry.count <= EpisodeSyncJournalRecord.maximumConflictPendingRevisionCount else {
            throw EpisodeSyncJournalError.tooManyPendingRevisions
        }
        record.pendingRevisions = retainedAncestry
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

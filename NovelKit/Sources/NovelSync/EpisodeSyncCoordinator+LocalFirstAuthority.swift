import Foundation

extension EpisodeSyncCoordinator {
    func acquireLocalFirstAuthority(
        matching snapshot: EpisodeRemoteSnapshot,
        expiresAt: Date
    ) async throws -> EpisodeRemoteSnapshot? {
        let isOwned = snapshot.lease?.authority.holderReplicaID == replicaID
            && snapshot.lease?.authority.holderSessionID == sessionID
        let kind: EpisodeLeaseClaimKind = snapshot.lease == nil || isOwned
            ? .acquireOrRenew
            : .forceTakeover
        let request = try EpisodeLeaseClaimRequest(
            key: key,
            requesterReplicaID: replicaID,
            requesterSessionID: sessionID,
            expectedEpoch: snapshot.leaseEpoch,
            expectedHeadRevisionID: kind == .forceTakeover ? snapshot.head?.revisionID : nil,
            expectedHeadContentDigest: kind == .forceTakeover ? snapshot.head?.contentDigest : nil,
            expiresAt: expiresAt,
            kind: kind
        )
        do {
            switch try await transport.claimLease(request) {
            case let .granted(granted):
                try validateLocalFirstSnapshot(granted)
                return granted
            case .denied, .changed:
                return nil
            }
        } catch EpisodeSyncTransportError.unavailable {
            _ = try await preserveOfflineState()
            return nil
        }
    }

    func activateLocalFirstAuthority(
        _ snapshot: EpisodeRemoteSnapshot,
        record: inout EpisodeSyncJournalRecord,
        updateRemoteHead: Bool = true
    ) throws {
        guard let lease = snapshot.lease,
              lease.authority.holderReplicaID == replicaID,
              lease.authority.holderSessionID == sessionID else {
            throw EpisodeSyncCoordinatorError.malformedRemoteSnapshot
        }
        record.lease = lease
        if updateRemoteHead {
            record.lastKnownRemoteHead = snapshot.head
        }
        record.mode = .tracking
        record.remoteConfirmation = .unconfirmed
        record.reconciliationStatus = .pending
        authorityVerifiedInProcess = true
        restoredAuthorityRequiresClaim = false
        pendingAuthorityGrant = nil
        pendingFenceObservation = nil
    }

    func prepareAutomaticMerge(
        mergedContent: String,
        remote: EpisodeRevision,
        createdAt: Date,
        record: inout EpisodeSyncJournalRecord
    ) throws {
        if !record.pendingRevisions.contains(where: {
            $0.revisionID == record.localHead.revisionID
        }) {
            record.pendingRevisions.append(record.localHead)
        }
        let working = record.localHead
        let merge = try makeRevision(
            content: mergedContent,
            parents: [remote.revisionID, working.revisionID],
            branchID: record.branchID,
            createdAt: createdAt
        )
        record.pendingRevisions.append(merge)
        record.lastKnownRemoteHead = remote
        record.conflict = nil
        record.integrationReviewDraft = nil
        record.remoteConfirmation = .unconfirmed
        record.reconciliationStatus = .pending
        if merge.contentDigest == working.contentDigest {
            record.localHead = merge
            record.pendingMaterialization = nil
        } else {
            record.pendingMaterialization = EpisodePendingMaterialization(
                workingRevisionID: working.revisionID,
                integratedRevision: merge
            )
        }
    }

    func drainLocalFirstPublishTail() async throws -> EpisodeSyncState {
        while let current = record, !current.pendingRevisions.isEmpty {
            if current.conflict != nil, current.sealedPublish == nil {
                state = stateForRecord(current)
                return state
            }
            let beforeIDs = current.pendingRevisions.map(\.revisionID)
            _ = try await synchronizeSerially()
            guard let after = record else { throw EpisodeSyncCoordinatorError.notLinked }
            if case .offlineFork = state {
                return state
            }
            if after.conflict != nil, after.sealedPublish == nil {
                return state
            }
            if after.pendingRevisions.map(\.revisionID) == beforeIDs {
                return state
            }
        }
        guard let final = record else { throw EpisodeSyncCoordinatorError.notLinked }
        state = stateForRecord(final)
        return state
    }

    func preserveOfflineState() async throws -> EpisodeSyncState {
        await acquireLocalJournalOperation()
        defer { releaseLocalJournalOperation() }
        guard var current = record else { throw EpisodeSyncCoordinatorError.notLinked }
        current.lease = nil
        current.mode = .forcedFork
        current.remoteConfirmation = .unconfirmed
        current.reconciliationStatus = current.conflict == nil ? .offline : .reviewRequired
        authorityVerifiedInProcess = false
        record = current
        try await journal.save(current)
        state = current.conflict.map { .conflicted(context(for: current), $0) }
            ?? .offlineFork(context(for: current))
        return state
    }

    func saveLocalFirstPreparedRecord(
        _ prepared: EpisodeSyncJournalRecord,
        replacing expected: LocalFirstRecordObservation
    ) async throws -> EpisodeSyncState? {
        await acquireLocalJournalOperation()
        defer { releaseLocalJournalOperation() }
        guard let latest = record,
              localFirstObservation(of: latest) == expected else {
            let latestState = record.map(stateForRecord) ?? .unlinked
            state = latestState
            return nil
        }
        var prepared = prepared
        refreshRemoteConfirmation(in: &prepared)
        record = prepared
        try await journal.save(prepared)
        state = stateForRecord(prepared)
        return state
    }

    func collapseLocalFirstEquivalent(
        into remote: EpisodeRevision,
        snapshot: EpisodeRemoteSnapshot,
        record: inout EpisodeSyncJournalRecord
    ) {
        record.localHead = remote
        record.lastKnownRemoteHead = remote
        record.pendingRevisions.removeAll()
        record.sealedPublish = nil
        record.lease = ownedLease(from: snapshot)
        record.conflict = nil
        record.integrationReviewDraft = nil
        record.pendingMaterialization = nil
        record.stagedConflictResolution = nil
        record.conflictResolutionRecovery = nil
        record.remoteConfirmation = .confirmed
        record.reconciliationStatus = .idle
        record.mode = .tracking
        authorityVerifiedInProcess = record.lease != nil
        restoredAuthorityRequiresClaim = false
    }

    func setLocalFirstConflict(
        in record: inout EpisodeSyncJournalRecord,
        base: EpisodeRevision?,
        remote: EpisodeRevision,
        reason: EpisodeIntegrationReviewDraft.Reason,
        proposedContent: String? = nil
    ) {
        let conflict = EpisodeConflict(base: base, local: record.localHead, remote: remote)
        record.lastKnownRemoteHead = base
        record.lease = nil
        record.conflict = conflict
        record.integrationReviewDraft = makeReviewDraft(
            for: conflict,
            reason: reason,
            proposedContent: proposedContent ?? conflict.local.content
        )
        record.pendingMaterialization = nil
        record.remoteConfirmation = .unconfirmed
        record.reconciliationStatus = .reviewRequired
        record.mode = .forcedFork
        authorityVerifiedInProcess = false
    }
}

import Foundation

extension EpisodeSyncCoordinator {
    enum LocalFirstRemoteObservationPreparation {
        case finished(EpisodeSyncState)
        case verify(
            base: EpisodeRevision,
            remote: EpisodeRevision,
            observation: LocalFirstRecordObservation
        )
    }

    func observeFetchedRemoteBase(
        localContent: String,
        snapshot: EpisodeRemoteSnapshot,
        createdAt: Date
    ) async throws -> EpisodeSyncState {
        await acquireLocalJournalOperation()
        let preparation: LocalFirstRemoteObservationPreparation
        do {
            preparation = try await prepareRemoteObservation(
                localContent: localContent,
                snapshot: snapshot,
                createdAt: createdAt
            )
            releaseLocalJournalOperation()
        } catch {
            releaseLocalJournalOperation()
            throw error
        }

        switch preparation {
        case let .finished(finished):
            return finished
        case let .verify(base, remote, observation):
            let descendsFromKnownBase = try await remoteRevision(remote, descendsFrom: base)
            return try await finishVerifiedRemoteObservation(
                snapshot: snapshot,
                remote: remote,
                observation: observation,
                descendsFromKnownBase: descendsFromKnownBase
            )
        }
    }

    func prepareRemoteObservation(
        localContent: String,
        snapshot: EpisodeRemoteSnapshot,
        createdAt: Date
    ) async throws -> LocalFirstRemoteObservationPreparation {
        guard var current = try await loadLocalRecordIfNecessary() else {
            let initial = try makeInitialObservedRecord(
                localContent: localContent,
                snapshot: snapshot,
                createdAt: createdAt
            )
            return try await .finished(persistObservedRecord(initial))
        }
        guard current.localEditIntent == .observed else {
            return .finished(stateForRecord(current))
        }
        if SyncContentDigest(content: localContent) != current.localHead.contentDigest {
            return try await .finished(
                persistObservedPackageChange(localContent, createdAt: createdAt, record: &current)
            )
        }
        guard let remote = snapshot.head else {
            return .finished(stateForRecord(current))
        }
        if remote.contentDigest == current.localHead.contentDigest {
            collapseLocalFirstEquivalent(into: remote, snapshot: snapshot, record: &current)
            return try await .finished(persistObservedRecord(current))
        }
        if current.conflict != nil || current.pendingMaterialization?.integratedRevision == remote {
            return .finished(stateForRecord(current))
        }
        guard let base = observedRemoteBase(for: current) else {
            setLocalFirstConflict(
                in: &current,
                base: nil,
                remote: remote,
                reason: .commonAncestorUnknown
            )
            return try await .finished(persistObservedRecord(current))
        }
        return .verify(
            base: base,
            remote: remote,
            observation: localFirstObservation(of: current)
        )
    }

    func finishVerifiedRemoteObservation(
        snapshot: EpisodeRemoteSnapshot,
        remote: EpisodeRevision,
        observation: LocalFirstRecordObservation,
        descendsFromKnownBase: Bool
    ) async throws -> EpisodeSyncState {
        await acquireLocalJournalOperation()
        defer { releaseLocalJournalOperation() }
        guard var latest = try await loadLocalRecordIfNecessary(),
              latest.localEditIntent == .observed,
              localFirstObservation(of: latest) == observation else {
            let latestState = record.map(stateForRecord) ?? .unlinked
            state = latestState
            return latestState
        }
        if descendsFromKnownBase {
            stageObservedRemoteMaterialization(remote, snapshot: snapshot, record: &latest)
        } else {
            setLocalFirstConflict(
                in: &latest,
                base: nil,
                remote: remote,
                reason: .commonAncestorUnknown
            )
        }
        return try await persistObservedRecord(latest)
    }

    func persistObservedPackageChange(
        _ localContent: String,
        createdAt: Date,
        record: inout EpisodeSyncJournalRecord
    ) async throws -> EpisodeSyncState {
        if record.pendingMaterialization != nil {
            try appendEditWhileAwaitingMaterialization(
                content: localContent,
                createdAt: createdAt,
                to: &record
            )
        } else if record.conflict != nil {
            preserveStagedConflictResolutionBeforeEdit(record: &record)
            if record.pendingRevisions.isEmpty {
                record.pendingRevisions = [record.localHead]
            }
            try appendConflictLocalRevision(content: localContent, createdAt: createdAt, to: &record)
        } else {
            try appendFirstExplicitEdit(content: localContent, createdAt: createdAt, to: &record)
        }
        record.mode = .forcedFork
        return try await persistObservedRecord(record)
    }

    func persistObservedRecord(
        _ observed: EpisodeSyncJournalRecord
    ) async throws -> EpisodeSyncState {
        record = observed
        try await journal.save(observed)
        state = stateForRecord(observed)
        return state
    }

    func makeInitialObservedRecord(
        localContent: String,
        snapshot: EpisodeRemoteSnapshot,
        createdAt: Date
    ) throws -> EpisodeSyncJournalRecord {
        let branchID = SyncBranchID()
        if let remote = snapshot.head,
           remote.contentDigest == SyncContentDigest(content: localContent) {
            return try makeCleanObservedRecord(remote: remote, branchID: branchID)
        }
        return try makeUnconfirmedObservedRecord(
            localContent: localContent,
            remote: snapshot.head,
            branchID: branchID,
            createdAt: createdAt
        )
    }

    func makeCleanObservedRecord(
        remote: EpisodeRevision,
        branchID: SyncBranchID
    ) throws -> EpisodeSyncJournalRecord {
        try EpisodeSyncJournalRecord(
            key: key,
            localWorkingCopyID: localWorkingCopyID,
            replicaID: replicaID,
            branchID: branchID,
            lastKnownRemoteHead: remote,
            localHead: remote,
            lease: nil,
            remoteConfirmation: .confirmed,
            localEditIntent: .observed,
            reconciliationStatus: .idle,
            mode: .tracking
        )
    }

    func makeUnconfirmedObservedRecord(
        localContent: String,
        remote: EpisodeRevision?,
        branchID: SyncBranchID,
        createdAt: Date
    ) throws -> EpisodeSyncJournalRecord {
        let localHead = try makeRevision(
            content: localContent,
            parents: [],
            branchID: branchID,
            createdAt: createdAt
        )
        let conflict = remote.map { EpisodeConflict(base: nil, local: localHead, remote: $0) }
        return try EpisodeSyncJournalRecord(
            key: key,
            localWorkingCopyID: localWorkingCopyID,
            replicaID: replicaID,
            branchID: branchID,
            lastKnownRemoteHead: nil,
            localHead: localHead,
            pendingRevisions: [],
            lease: nil,
            conflict: conflict,
            integrationReviewDraft: conflict.map {
                makeReviewDraft(
                    for: $0,
                    reason: .commonAncestorUnknown,
                    proposedContent: localContent
                )
            },
            remoteConfirmation: .unconfirmed,
            localEditIntent: .observed,
            reconciliationStatus: conflict == nil ? .idle : .reviewRequired,
            mode: conflict == nil ? .tracking : .forcedFork
        )
    }

    func observedRemoteBase(for record: EpisodeSyncJournalRecord) -> EpisodeRevision? {
        if let materialization = record.pendingMaterialization,
           materialization.integratedRevision == record.lastKnownRemoteHead {
            return materialization.integratedRevision
        }
        guard record.remoteConfirmation == .confirmed,
              record.localHead == record.lastKnownRemoteHead else {
            return nil
        }
        return record.lastKnownRemoteHead
    }

    func stageObservedRemoteMaterialization(
        _ remote: EpisodeRevision,
        snapshot: EpisodeRemoteSnapshot,
        record: inout EpisodeSyncJournalRecord
    ) {
        record.lastKnownRemoteHead = remote
        record.pendingRevisions.removeAll()
        record.sealedPublish = nil
        record.lease = ownedLease(from: snapshot)
        record.conflict = nil
        record.integrationReviewDraft = nil
        record.pendingMaterialization = EpisodePendingMaterialization(
            workingRevisionID: record.localHead.revisionID,
            integratedRevision: remote
        )
        record.remoteConfirmation = .unconfirmed
        record.localEditIntent = .observed
        record.reconciliationStatus = .pending
        record.mode = .tracking
        authorityVerifiedInProcess = record.lease != nil
        restoredAuthorityRequiresClaim = false
    }
}

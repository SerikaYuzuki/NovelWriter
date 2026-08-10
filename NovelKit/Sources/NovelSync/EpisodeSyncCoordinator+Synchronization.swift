import Foundation

public extension EpisodeSyncCoordinator {
    @discardableResult
    func synchronize() async throws -> EpisodeSyncState {
        guard let initialRecord = record else { throw EpisodeSyncCoordinatorError.notLinked }
        let initialAuthority = initialRecord.lease?.authority
        let isRestoredReplay = restoredAuthorityRequiresClaim
            && initialRecord.sealedPublish != nil
        state = .synchronizing(context(for: initialRecord))

        guard let snapshot = try await fetchSnapshotForSynchronization() else { return state }
        guard let authority = try await synchronizationAuthority(
            initialAuthority: initialAuthority,
            isRestoredReplay: isRestoredReplay,
            snapshot: snapshot
        ) else { return state }
        guard var current = record else { throw EpisodeSyncCoordinatorError.notLinked }
        guard !current.pendingRevisions.isEmpty else {
            return try await reconcileCleanRecord(current, snapshot: snapshot)
        }

        let command = try await makePublishCommand(record: &current, authority: authority)
        guard let result = try await publishForSynchronization(command.request) else { return state }
        return try await applyPublishResult(
            result,
            sealed: command.sealed,
            authority: authority
        )
    }
}

private extension EpisodeSyncCoordinator {
    struct PublishCommand {
        let sealed: EpisodeSealedPublish
        let request: EpisodePublishRequest
    }

    func fetchSnapshotForSynchronization() async throws -> EpisodeRemoteSnapshot? {
        do {
            return try await transport.fetchSnapshot(for: key)
        } catch EpisodeSyncTransportError.unavailable {
            try markTransportUnavailable()
            return nil
        }
    }

    func markTransportUnavailable() throws {
        guard let latest = record else { throw EpisodeSyncCoordinatorError.notLinked }
        state = authorityVerifiedInProcess
            ? .offlineFork(context(for: latest))
            : .restoredUnverified(context(for: latest))
    }

    func synchronizationAuthority(
        initialAuthority: EpisodeLeaseAuthority?,
        isRestoredReplay: Bool,
        snapshot: EpisodeRemoteSnapshot
    ) async throws -> EpisodeLeaseAuthority? {
        guard let current = record else { throw EpisodeSyncCoordinatorError.notLinked }
        guard current.lease?.authority == initialAuthority else { return nil }
        guard let authority = initialAuthority,
              isRestoredReplay || authorityBelongsToThisSession(authority) else {
            try await applyFence(snapshot, expectedAuthority: initialAuthority)
            return nil
        }
        if restoredAuthorityRequiresClaim, current.sealedPublish == nil {
            try await keepRestoredRecordReadOnly(
                current,
                authority: authority,
                snapshot: snapshot
            )
            return nil
        }
        if snapshot.lease?.authority == authority {
            authorityVerifiedInProcess = !restoredAuthorityRequiresClaim
            return authority
        }
        guard current.sealedPublish != nil else {
            try await applyFence(snapshot, expectedAuthority: authority)
            return nil
        }
        authorityVerifiedInProcess = false
        return authority
    }

    func authorityBelongsToThisSession(_ authority: EpisodeLeaseAuthority) -> Bool {
        authority.holderReplicaID == replicaID
            && authority.holderSessionID == sessionID
    }

    func keepRestoredRecordReadOnly(
        _ current: EpisodeSyncJournalRecord,
        authority: EpisodeLeaseAuthority,
        snapshot: EpisodeRemoteSnapshot
    ) async throws {
        if snapshot.lease?.authority == authority {
            state = .restoredUnverified(context(for: current))
        } else {
            try await applyFence(snapshot, expectedAuthority: authority)
        }
    }

    func reconcileCleanRecord(
        _ current: EpisodeSyncJournalRecord,
        snapshot: EpisodeRemoteSnapshot
    ) async throws -> EpisodeSyncState {
        var updated = current
        if snapshot.head?.revisionID == current.localHead.revisionID {
            updated.lastKnownRemoteHead = snapshot.head
            updated.lease = snapshot.lease
            record = updated
            try await persistAndUpdateState()
        } else if let remote = snapshot.head {
            updated.lease = snapshot.lease
            record = updated
            try await journal.save(updated)
            state = .remoteUpdateAvailable(context(for: updated), remote: remote)
        } else {
            throw EpisodeSyncCoordinatorError.malformedRemoteSnapshot
        }
        return state
    }

    func makePublishCommand(
        record: inout EpisodeSyncJournalRecord,
        authority: EpisodeLeaseAuthority
    ) async throws -> PublishCommand {
        let sealed = record.sealedPublish ?? EpisodeSealedPublish(
            mutationID: SyncMutationID(),
            revisionIDs: record.pendingRevisions.map(\.revisionID),
            candidateHeadRevisionID: record.localHead.revisionID,
            expectedHeadRevisionID: record.lastKnownRemoteHead?.revisionID
        )
        if record.sealedPublish == nil {
            record.sealedPublish = sealed
            self.record = record
            try await journal.save(record)
        }
        let pendingByID = Dictionary(
            uniqueKeysWithValues: record.pendingRevisions.map { ($0.revisionID, $0) }
        )
        let sealedRevisions = try sealed.revisionIDs.map { revisionID in
            guard let revision = pendingByID[revisionID] else {
                throw EpisodeSyncJournalError.sealedPublishMismatch
            }
            return revision
        }
        let request = try EpisodePublishRequest(
            mutationID: sealed.mutationID,
            key: key,
            revisions: sealedRevisions,
            candidateHeadRevisionID: sealed.candidateHeadRevisionID,
            expectedHeadRevisionID: sealed.expectedHeadRevisionID,
            expectedLeaseAuthority: authority
        )
        return PublishCommand(sealed: sealed, request: request)
    }

    func publishForSynchronization(
        _ request: EpisodePublishRequest
    ) async throws -> EpisodePublishResult? {
        do {
            return try await transport.publish(request)
        } catch EpisodeSyncTransportError.unavailable {
            try markTransportUnavailable()
            return nil
        }
    }

    func applyPublishResult(
        _ result: EpisodePublishResult,
        sealed: EpisodeSealedPublish,
        authority: EpisodeLeaseAuthority
    ) async throws -> EpisodeSyncState {
        switch result {
        case let .acknowledged(committedHead, current):
            try await applyAcknowledgement(
                committedHead: committedHead,
                current: current,
                sealed: sealed,
                authority: authority
            )
        case let .diverged(current):
            try await applyDivergence(current, authority: authority)
        case let .staleLease(current):
            try await applyStaleLease(current, sealed: sealed, authority: authority)
        }
        return state
    }

    func applyAcknowledgement(
        committedHead: EpisodeRevision,
        current: EpisodeRemoteSnapshot,
        sealed: EpisodeSealedPublish,
        authority: EpisodeLeaseAuthority
    ) async throws {
        guard committedHead.revisionID == sealed.candidateHeadRevisionID else {
            throw EpisodeSyncCoordinatorError.malformedRemoteSnapshot
        }
        guard var latest = record else { throw EpisodeSyncCoordinatorError.notLinked }
        guard updateAcknowledgedRecord(
            &latest,
            committedHead: committedHead,
            current: current,
            sealed: sealed,
            authority: authority
        ) else { return }
        record = latest

        if restoredAuthorityRequiresClaim {
            try await applyFence(current, expectedAuthority: authority)
        } else if receiptIsCurrentCommit(
            committedHead,
            current: current,
            authority: authority
        ) {
            try await persistAndUpdateState()
        } else {
            try await journal.save(latest)
            state = stateAfterAcknowledgement(
                latest,
                current: current,
                authority: authority
            )
        }
    }

    func updateAcknowledgedRecord(
        _ latest: inout EpisodeSyncJournalRecord,
        committedHead: EpisodeRevision,
        current: EpisodeRemoteSnapshot,
        sealed: EpisodeSealedPublish,
        authority: EpisodeLeaseAuthority
    ) -> Bool {
        let sealedIDs = Set(sealed.revisionIDs)
        let sealIsCurrent = latest.sealedPublish == sealed
        let containsCommit = latest.pendingRevisions.contains {
            sealedIDs.contains($0.revisionID)
        }
        guard sealIsCurrent || containsCommit else { return false }
        latest.pendingRevisions.removeAll { sealedIDs.contains($0.revisionID) }
        if sealIsCurrent {
            latest.sealedPublish = nil
        }
        updateAcknowledgedBase(&latest, committedHead: committedHead, sealed: sealed)
        updateAcknowledgedAuthority(&latest, current: current, authority: authority)
        updateAcknowledgedConflict(&latest, committedHead: committedHead, current: current)
        return true
    }

    func updateAcknowledgedBase(
        _ latest: inout EpisodeSyncJournalRecord,
        committedHead: EpisodeRevision,
        sealed: EpisodeSealedPublish
    ) {
        if latest.lastKnownRemoteHead?.revisionID == sealed.expectedHeadRevisionID
            || latest.lastKnownRemoteHead == nil {
            latest.lastKnownRemoteHead = committedHead
        }
        if latest.pendingRevisions.isEmpty {
            latest.localHead = committedHead
        }
    }

    func updateAcknowledgedAuthority(
        _ latest: inout EpisodeSyncJournalRecord,
        current: EpisodeRemoteSnapshot,
        authority: EpisodeLeaseAuthority
    ) {
        if current.lease?.authority == authority {
            latest.lease = current.lease
            authorityVerifiedInProcess = !restoredAuthorityRequiresClaim
        } else if latest.lease?.authority == authority {
            latest.lease = nil
            authorityVerifiedInProcess = false
        }
    }

    func updateAcknowledgedConflict(
        _ latest: inout EpisodeSyncJournalRecord,
        committedHead: EpisodeRevision,
        current: EpisodeRemoteSnapshot
    ) {
        let headDiffers = current.head?.revisionID != committedHead.revisionID
        if headDiffers, !latest.pendingRevisions.isEmpty, let remote = current.head,
           latest.localHead.contentDigest != remote.contentDigest {
            latest.conflict = EpisodeConflict(
                base: committedHead,
                local: latest.localHead,
                remote: remote
            )
            latest.mode = .forcedFork
        } else if latest.pendingRevisions.isEmpty, latest.conflict == nil {
            latest.mode = .tracking
        }
    }

    func receiptIsCurrentCommit(
        _ committedHead: EpisodeRevision,
        current: EpisodeRemoteSnapshot,
        authority: EpisodeLeaseAuthority
    ) -> Bool {
        current.head?.revisionID == committedHead.revisionID
            && current.lease?.authority == authority
    }

    func stateAfterAcknowledgement(
        _ latest: EpisodeSyncJournalRecord,
        current: EpisodeRemoteSnapshot,
        authority: EpisodeLeaseAuthority
    ) -> EpisodeSyncState {
        if let conflict = latest.conflict {
            return .conflicted(context(for: latest), conflict)
        }
        if current.lease?.authority == authority, let remote = current.head {
            return .remoteUpdateAvailable(context(for: latest), remote: remote)
        }
        return .authorityLost(context(for: latest), current: current)
    }

    func applyDivergence(
        _ current: EpisodeRemoteSnapshot,
        authority: EpisodeLeaseAuthority
    ) async throws {
        guard let remote = current.head,
              var latest = record else {
            throw EpisodeSyncCoordinatorError.malformedRemoteSnapshot
        }
        let conflict = EpisodeConflict(
            base: latest.lastKnownRemoteHead,
            local: latest.localHead,
            remote: remote
        )
        latest.sealedPublish = nil
        latest.lease = current.lease
        latest.conflict = conflict
        record = latest
        if restoredAuthorityRequiresClaim {
            try await applyFence(current, expectedAuthority: authority)
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
        guard var latest = record else { throw EpisodeSyncCoordinatorError.notLinked }
        if latest.sealedPublish == sealed {
            latest.sealedPublish = nil
        }
        record = latest
        try await applyFence(current, expectedAuthority: authority)
    }
}

import Foundation

public extension EpisodeSyncCoordinator {
    internal func claimEditingAuthoritySerially(expiresAt: Date) async throws -> EpisodeSyncState {
        guard let current = record else { throw EpisodeSyncCoordinatorError.notLinked }
        let initialAuthority = current.lease?.authority
        let snapshot = try await transport.fetchSnapshot(for: key)
        let result = try await requestLease(
            kind: .acquireOrRenew,
            snapshot: snapshot,
            expiresAt: expiresAt
        )
        guard let latest = record else { throw EpisodeSyncCoordinatorError.notLinked }
        switch result {
        case let .granted(postClaimSnapshot):
            try await handleGrantedClaim(postClaimSnapshot, latest: latest)
        case let .denied(postClaimSnapshot):
            try await handleDeniedClaim(postClaimSnapshot, expectedAuthority: initialAuthority)
        case let .changed(postClaimSnapshot):
            try await applyFence(postClaimSnapshot, expectedAuthority: initialAuthority)
        }
        return state
    }

    internal func prepareForcedContinuationSerially(
        expiresAt: Date,
        expectedHead: EpisodeRevision? = nil
    ) async throws -> EpisodeAuthorityGrant {
        guard let record else { throw EpisodeSyncCoordinatorError.notLinked }
        guard record.conflict == nil else {
            throw EpisodeSyncCoordinatorError.unresolvedConflict
        }
        return try await prepareForcedContinuationUncheckedSerially(
            expiresAt: expiresAt,
            expectedHead: expectedHead
        )
    }

    internal func prepareConflictResolutionAuthoritySerially(
        expectedConflict: EpisodeConflict,
        expiresAt: Date
    ) async throws -> EpisodeAuthorityGrant {
        guard let record else { throw EpisodeSyncCoordinatorError.notLinked }
        guard record.conflict == expectedConflict else {
            throw EpisodeSyncCoordinatorError.conflictSuperseded
        }
        let grant = try await prepareForcedContinuationUncheckedSerially(
            expiresAt: expiresAt,
            expectedHead: expectedConflict.remote
        )
        guard grant.snapshot.head?.revisionID == expectedConflict.remote.revisionID,
              grant.snapshot.head?.contentDigest == expectedConflict.remote.contentDigest else {
            _ = try await abandonAuthorityGrantSerially(grant)
            throw EpisodeSyncCoordinatorError.conflictSuperseded
        }
        return grant
    }

    internal func prepareForcedContinuationUncheckedSerially(
        expiresAt: Date,
        expectedHead: EpisodeRevision? = nil
    ) async throws -> EpisodeAuthorityGrant {
        let snapshot = try await transport.fetchSnapshot(for: key)
        if let expectedHead,
           snapshot.head?.revisionID != expectedHead.revisionID
           || snapshot.head?.contentDigest != expectedHead.contentDigest {
            try await applyFence(snapshot, expectedAuthority: nil)
            throw EpisodeSyncCoordinatorError.conflictSuperseded
        }
        let result = try await requestLease(
            kind: .forceTakeover,
            snapshot: snapshot,
            expectedHead: expectedHead,
            expiresAt: expiresAt
        )
        guard let latest = record else { throw EpisodeSyncCoordinatorError.notLinked }
        guard case let .granted(postClaimSnapshot) = result,
              let lease = postClaimSnapshot.lease else {
            if expectedHead != nil {
                try await applyRejectedConflictClaim(result)
                throw EpisodeSyncCoordinatorError.conflictSuperseded
            }
            applyRejectedForceResult(result, latest: latest)
            throw EpisodeSyncCoordinatorError.leaseClaimRejected
        }
        let grant = try EpisodeAuthorityGrant(snapshot: postClaimSnapshot, lease: lease)
        pendingFenceObservation = nil
        pendingAuthorityGrant = grant
        authorityVerifiedInProcess = false
        state = .authorityGrantedAwaitingInstall(context(for: latest), grant)
        return grant
    }

    /// CAS後・remote install前に、Appが保存済みの旧local本文をforkとしてdurable化する。
    @discardableResult
    func preserveLocalFork(
        content: String,
        createdAt: Date,
        for grant: EpisodeAuthorityGrant
    ) async throws -> EpisodeSyncState {
        await acquireLocalJournalOperation()
        defer { releaseLocalJournalOperation() }
        guard pendingAuthorityGrant == grant else {
            throw EpisodeSyncCoordinatorError.authorityGrantNotPending
        }
        guard var record else { throw EpisodeSyncCoordinatorError.notLinked }
        try appendLocalRevision(content: content, createdAt: createdAt, to: &record)
        record.mode = .forcedFork
        self.record = record
        try await journal.save(record)
        state = .authorityGrantedAwaitingInstall(context(for: record), grant)
        return state
    }

    /// fence検出後、remote install前に旧editor本文をexact observationへ紐づけて保全する。
    @discardableResult
    func preserveLocalFork(
        content: String,
        createdAt: Date,
        for observation: EpisodeFenceObservation
    ) async throws -> EpisodeSyncState {
        await acquireLocalJournalOperation()
        defer { releaseLocalJournalOperation() }
        guard pendingFenceObservation == observation else {
            throw EpisodeSyncCoordinatorError.fenceObservationNotPending
        }
        let snapshot = try observedFenceSnapshot(observation)
        guard var record else { throw EpisodeSyncCoordinatorError.notLinked }
        try appendLocalRevision(content: content, createdAt: createdAt, to: &record)
        record.mode = .forcedFork
        updateConflict(in: &record, remote: snapshot.head)
        self.record = record
        try await journal.save(record)
        state = record.conflict.map { .conflicted(context(for: record), $0) }
            ?? .authorityLost(context(for: record), current: snapshot)
        return state
    }

    internal func confirmObservedRemoteInstallSerially(
        _ observation: EpisodeFenceObservation,
        installedRemoteDigest: SyncContentDigest?
    ) async throws -> EpisodeSyncState {
        try validatePending(observation, installedRemoteDigest: installedRemoteDigest)
        let current = try await transport.fetchSnapshot(for: key)
        guard pendingFenceObservation == observation else {
            throw EpisodeSyncCoordinatorError.fenceObservationNotPending
        }
        guard snapshot(current, stillMatches: observation) else {
            pendingFenceObservation = .authorityLost(current)
            try await applyFence(current, expectedAuthority: nil)
            throw EpisodeSyncCoordinatorError.remoteObservationSuperseded
        }

        await acquireLocalJournalOperation()
        defer { releaseLocalJournalOperation() }
        pendingFenceObservation = nil
        guard var record else { throw EpisodeSyncCoordinatorError.notLinked }
        installCleanRemote(current.head, into: &record)
        self.record = record
        try await journal.save(record)
        if case .authorityLost = observation, record.conflict == nil {
            state = .authorityLost(context(for: record), current: current)
        } else {
            state = stateForRecord(record)
        }
        return state
    }

    internal func confirmAuthorityInstallSerially(
        _ grant: EpisodeAuthorityGrant,
        installedRemoteDigest: SyncContentDigest?
    ) async throws -> EpisodeSyncState {
        guard pendingAuthorityGrant == grant else {
            throw EpisodeSyncCoordinatorError.authorityGrantNotPending
        }
        guard installedRemoteDigest == grant.snapshot.head?.contentDigest else {
            throw EpisodeSyncCoordinatorError.installedDigestMismatch
        }

        let current = try await transport.fetchSnapshot(for: key)
        guard pendingAuthorityGrant == grant else {
            throw EpisodeSyncCoordinatorError.authorityGrantNotPending
        }
        guard snapshot(current, stillMatches: grant) else {
            pendingAuthorityGrant = nil
            try await applyFence(current, expectedAuthority: nil)
            throw EpisodeSyncCoordinatorError.authorityGrantSuperseded
        }
        pendingAuthorityGrant = nil
        try await activate(lease: grant.lease, snapshot: grant.snapshot)
        return state
    }

    internal func abandonAuthorityGrantSerially(
        _ grant: EpisodeAuthorityGrant
    ) async throws -> EpisodeSyncState {
        guard pendingAuthorityGrant == grant else {
            throw EpisodeSyncCoordinatorError.authorityGrantNotPending
        }
        let current = try await transport.releaseLease(
            key: key,
            expectedAuthority: grant.lease.authority
        )
        guard pendingAuthorityGrant == grant else {
            throw EpisodeSyncCoordinatorError.authorityGrantNotPending
        }
        pendingAuthorityGrant = nil
        try await applyFence(current, expectedAuthority: nil)
        return state
    }

    internal func inspectFenceSerially() async throws -> EpisodeFenceObservation {
        guard let initial = record else { throw EpisodeSyncCoordinatorError.notLinked }
        let expectedAuthority = initial.lease?.authority
        let snapshot = try await transport.fetchSnapshot(for: key)
        guard let latest = record else { throw EpisodeSyncCoordinatorError.notLinked }

        guard let currentAuthority = verifiedAuthority(
            in: latest,
            expected: expectedAuthority,
            snapshot: snapshot
        ) else {
            pendingFenceObservation = .authorityLost(snapshot)
            try await applyFence(snapshot, expectedAuthority: expectedAuthority)
            return .authorityLost(snapshot)
        }

        authorityVerifiedInProcess = true
        guard snapshot.head?.revisionID != latest.lastKnownRemoteHead?.revisionID else {
            pendingFenceObservation = nil
            return .authorityValid(snapshot)
        }
        pendingFenceObservation = .remoteAdvanced(snapshot)
        try await applyRemoteAdvance(snapshot, authority: currentAuthority)
        return .remoteAdvanced(snapshot)
    }

    internal func releaseEditingAuthoritySerially() async throws -> EpisodeSyncState {
        if let grant = pendingAuthorityGrant {
            return try await abandonAuthorityGrantSerially(grant)
        }
        guard let initialRecord = record else { throw EpisodeSyncCoordinatorError.notLinked }
        guard let authority = initialRecord.lease?.authority else { return state }
        let snapshot = try await transport.releaseLease(key: key, expectedAuthority: authority)
        try await applyFence(snapshot, expectedAuthority: authority)
        return state
    }
}

private extension EpisodeSyncCoordinator {
    func handleGrantedClaim(
        _ snapshot: EpisodeRemoteSnapshot,
        latest: EpisodeSyncJournalRecord
    ) async throws {
        guard let lease = snapshot.lease else {
            throw EpisodeSyncCoordinatorError.malformedRemoteSnapshot
        }
        let remoteDiffers = snapshot.head.map {
            $0.contentDigest != latest.localHead.contentDigest
        } ?? false
        guard remoteDiffers else {
            try await activate(lease: lease, snapshot: snapshot)
            return
        }
        let grant = try EpisodeAuthorityGrant(snapshot: snapshot, lease: lease)
        pendingAuthorityGrant = grant
        authorityVerifiedInProcess = false
        state = .authorityGrantedAwaitingInstall(context(for: latest), grant)
    }

    func handleDeniedClaim(
        _ snapshot: EpisodeRemoteSnapshot,
        expectedAuthority: EpisodeLeaseAuthority?
    ) async throws {
        guard let lease = snapshot.lease else {
            throw EpisodeSyncCoordinatorError.malformedRemoteSnapshot
        }
        try await applyFence(snapshot, expectedAuthority: expectedAuthority)
        if case .authorityLost = state, let latest = record {
            state = .readOnly(context(for: latest), heldBy: lease)
        }
    }

    func applyRejectedForceResult(
        _ result: EpisodeLeaseClaimResult,
        latest: EpisodeSyncJournalRecord
    ) {
        switch result {
        case let .denied(snapshot):
            state = snapshot.lease.map { .readOnly(context(for: latest), heldBy: $0) }
                ?? .authorityLost(context(for: latest), current: snapshot)
        case let .changed(snapshot):
            state = .authorityLost(context(for: latest), current: snapshot)
        case .granted:
            break
        }
    }

    func activate(lease: EpisodeLease, snapshot: EpisodeRemoteSnapshot) async throws {
        await acquireLocalJournalOperation()
        defer { releaseLocalJournalOperation() }
        guard var record else { throw EpisodeSyncCoordinatorError.notLinked }
        record.lease = lease
        authorityVerifiedInProcess = true
        restoredAuthorityRequiresClaim = false
        if let remote = snapshot.head {
            if record.localHead.contentDigest == remote.contentDigest {
                collapseEquivalentLocal(into: remote, record: &record)
            } else if record.pendingRevisions.isEmpty, record.conflict == nil {
                record.localHead = remote
                record.lastKnownRemoteHead = remote
            } else {
                updateConflict(in: &record, remote: remote)
            }
        }
        self.record = record
        try await persistAndUpdateState()
    }

    func observedFenceSnapshot(
        _ observation: EpisodeFenceObservation
    ) throws -> EpisodeRemoteSnapshot {
        switch observation {
        case let .authorityLost(snapshot), let .remoteAdvanced(snapshot):
            snapshot
        case .authorityValid:
            throw EpisodeSyncCoordinatorError.fenceObservationNotPending
        }
    }

    func validatePending(
        _ observation: EpisodeFenceObservation,
        installedRemoteDigest: SyncContentDigest?
    ) throws {
        guard pendingFenceObservation == observation else {
            throw EpisodeSyncCoordinatorError.fenceObservationNotPending
        }
        guard installedRemoteDigest == observation.remoteSnapshot?.head?.contentDigest else {
            throw EpisodeSyncCoordinatorError.installedDigestMismatch
        }
    }

    func installCleanRemote(
        _ remote: EpisodeRevision?,
        into record: inout EpisodeSyncJournalRecord
    ) {
        guard let remote else { return }
        if record.localHead.contentDigest == remote.contentDigest {
            collapseEquivalentLocal(into: remote, record: &record)
            return
        }
        guard record.conflict == nil,
              record.pendingRevisions.isEmpty,
              record.sealedPublish == nil else { return }
        record.localHead = remote
        record.lastKnownRemoteHead = remote
    }

    func collapseEquivalentLocal(
        into remote: EpisodeRevision,
        record: inout EpisodeSyncJournalRecord
    ) {
        record.localHead = remote
        record.lastKnownRemoteHead = remote
        record.pendingRevisions.removeAll()
        record.sealedPublish = nil
        record.conflict = nil
        record.mode = .tracking
        record.reconciliationStatus = .idle
    }

    func verifiedAuthority(
        in record: EpisodeSyncJournalRecord,
        expected: EpisodeLeaseAuthority?,
        snapshot: EpisodeRemoteSnapshot
    ) -> EpisodeLeaseAuthority? {
        guard let authority = record.lease?.authority,
              authority == expected,
              snapshot.lease?.authority == authority,
              authority.holderReplicaID == replicaID,
              authority.holderSessionID == sessionID else { return nil }
        return authority
    }
}

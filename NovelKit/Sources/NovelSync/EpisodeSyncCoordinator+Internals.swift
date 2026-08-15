import Foundation

extension EpisodeSyncCoordinator {
    func makeInitialLinkedRecord(
        localContent: String,
        remoteHead: EpisodeRevision,
        snapshot: EpisodeRemoteSnapshot,
        branchID: SyncBranchID,
        createdAt: Date
    ) throws -> EpisodeSyncJournalRecord {
        let digest = SyncContentDigest(content: localContent)
        let differs = digest != remoteHead.contentDigest
        let localHead = try differs
            ? makeRevision(
                content: localContent,
                parents: [],
                branchID: branchID,
                createdAt: createdAt
            )
            : remoteHead
        return try EpisodeSyncJournalRecord(
            key: key,
            localWorkingCopyID: localWorkingCopyID,
            replicaID: replicaID,
            branchID: branchID,
            lastKnownRemoteHead: remoteHead,
            localHead: localHead,
            pendingRevisions: differs ? [localHead] : [],
            lease: ownedLease(from: snapshot),
            conflict: differs
                ? EpisodeConflict(base: nil, local: localHead, remote: remoteHead)
                : nil,
            mode: .tracking
        )
    }

    func appendLocalRevision(
        content: String,
        createdAt: Date,
        to record: inout EpisodeSyncJournalRecord
    ) throws {
        guard SyncContentDigest(content: content) != record.localHead.contentDigest else { return }
        let parents = coalescedParents(in: &record)
        let revision = try makeRevision(
            content: content,
            parents: parents,
            branchID: record.branchID,
            createdAt: createdAt
        )
        record.localHead = revision
        record.pendingRevisions.append(revision)
        if let conflict = record.conflict {
            let updatedConflict = EpisodeConflict(
                base: conflict.base,
                local: revision,
                remote: conflict.remote
            )
            record.conflict = updatedConflict
            record.integrationReviewDraft = makeReviewDraft(
                for: updatedConflict,
                reason: record.integrationReviewDraft?.reason ?? .ambiguousChanges,
                proposedContent: content
            )
        }
        record.remoteConfirmation = .unconfirmed
        record.localEditIntent = .explicit
        record.reconciliationStatus = record.conflict == nil ? .pending : .reviewRequired
    }

    /// conflict発見前から存在した最初のlocal forkはimmutableに残し、
    /// その後native editorへ入った未送信tailだけをcoalesceする。
    func appendConflictLocalRevision(
        content: String,
        createdAt: Date,
        to record: inout EpisodeSyncJournalRecord
    ) throws {
        guard SyncContentDigest(content: content) != record.localHead.contentDigest else { return }
        let parents = conflictTailParents(in: &record)
        let revision = try makeRevision(
            content: content,
            parents: parents,
            branchID: record.branchID,
            createdAt: createdAt
        )
        record.localHead = revision
        record.pendingRevisions.append(revision)
        if let conflict = record.conflict {
            let updatedConflict = EpisodeConflict(
                base: conflict.base,
                local: revision,
                remote: conflict.remote
            )
            record.conflict = updatedConflict
            record.integrationReviewDraft = makeReviewDraft(
                for: updatedConflict,
                reason: record.integrationReviewDraft?.reason ?? .ambiguousChanges,
                proposedContent: content
            )
        }
        record.remoteConfirmation = .unconfirmed
        record.localEditIntent = .explicit
        record.reconciliationStatus = record.conflict == nil ? .pending : .reviewRequired
    }

    func conflictTailParents(
        in record: inout EpisodeSyncJournalRecord
    ) -> [SyncRevisionID] {
        if let sealed = record.sealedPublish {
            let sealedIDs = Set(sealed.revisionIDs)
            if let tailIndex = record.pendingRevisions.firstIndex(where: {
                !sealedIDs.contains($0.revisionID)
            }) {
                let parents = record.pendingRevisions[tailIndex].parentRevisionIDs
                record.pendingRevisions.removeSubrange(tailIndex...)
                return parents
            }
            return [sealed.candidateHeadRevisionID]
        }
        if let conflict = record.conflict,
           let localIndex = record.pendingRevisions.firstIndex(where: {
               $0.revisionID == conflict.local.revisionID
           }) {
            let remoteIsPending = record.pendingRevisions.contains {
                $0.revisionID == conflict.remote.revisionID
            }
            if localIndex == 0, !remoteIsPending {
                // 最初のdetached forkは確認画面の復元元として残す。
                return [conflict.local.revisionID]
            }
            let parents = record.pendingRevisions[localIndex].parentRevisionIDs
            record.pendingRevisions.removeSubrange(localIndex...)
            return parents
        }
        if record.pendingRevisions.count > 1 {
            let parents = record.pendingRevisions[1].parentRevisionIDs
            record.pendingRevisions.removeSubrange(1...)
            return parents
        }
        return [record.localHead.revisionID]
    }

    func coalescedParents(
        in record: inout EpisodeSyncJournalRecord
    ) -> [SyncRevisionID] {
        if let sealed = record.sealedPublish {
            let sealedIDs = Set(sealed.revisionIDs)
            if let tailIndex = record.pendingRevisions.firstIndex(where: {
                !sealedIDs.contains($0.revisionID)
            }) {
                let parents = record.pendingRevisions[tailIndex].parentRevisionIDs
                record.pendingRevisions.removeSubrange(tailIndex...)
                return parents
            }
            return [sealed.candidateHeadRevisionID]
        }
        if let firstPending = record.pendingRevisions.first {
            record.pendingRevisions.removeAll(keepingCapacity: true)
            return firstPending.parentRevisionIDs
        }
        return [record.localHead.revisionID]
    }

    func snapshot(
        _ current: EpisodeRemoteSnapshot,
        stillMatches grant: EpisodeAuthorityGrant
    ) -> Bool {
        current.lease?.authority == grant.lease.authority
            && current.head?.revisionID == grant.snapshot.head?.revisionID
            && current.head?.contentDigest == grant.snapshot.head?.contentDigest
    }

    func snapshot(
        _ current: EpisodeRemoteSnapshot,
        stillMatches observation: EpisodeFenceObservation
    ) -> Bool {
        guard let observed = observation.remoteSnapshot else { return false }
        return current.leaseEpoch == observed.leaseEpoch
            && current.lease?.authority == observed.lease?.authority
            && current.head?.revisionID == observed.head?.revisionID
            && current.head?.contentDigest == observed.head?.contentDigest
    }

    func applyFence(
        _ snapshot: EpisodeRemoteSnapshot,
        expectedAuthority: EpisodeLeaseAuthority?
    ) async throws {
        await acquireLocalJournalOperation()
        defer { releaseLocalJournalOperation() }
        try await applyFenceInLocalJournalLane(
            snapshot,
            expectedAuthority: expectedAuthority
        )
    }

    func applyFenceInLocalJournalLane(
        _ snapshot: EpisodeRemoteSnapshot,
        expectedAuthority: EpisodeLeaseAuthority?
    ) async throws {
        guard var latest = record else { throw EpisodeSyncCoordinatorError.notLinked }
        if let expectedAuthority, latest.lease?.authority != expectedAuthority {
            return
        }
        latest.lease = nil
        authorityVerifiedInProcess = false
        updateConflict(in: &latest, remote: snapshot.head)
        record = latest
        try await journal.save(latest)
        if let conflict = latest.conflict {
            state = .conflicted(context(for: latest), conflict)
        } else {
            state = .authorityLost(context(for: latest), current: snapshot)
        }
    }

    func applyRemoteAdvance(
        _ snapshot: EpisodeRemoteSnapshot,
        authority: EpisodeLeaseAuthority
    ) async throws {
        await acquireLocalJournalOperation()
        defer { releaseLocalJournalOperation() }
        guard var latest = record,
              latest.lease?.authority == authority else { return }
        guard let remote = snapshot.head else {
            throw EpisodeSyncCoordinatorError.malformedRemoteSnapshot
        }
        updateConflict(in: &latest, remote: remote)
        if let conflict = latest.conflict {
            record = latest
            try await journal.save(latest)
            state = .conflicted(context(for: latest), conflict)
        } else {
            state = .remoteUpdateAvailable(context(for: latest), remote: remote)
        }
    }

    func updateConflict(
        in record: inout EpisodeSyncJournalRecord,
        remote: EpisodeRevision?
    ) {
        guard let remote else { return }
        let hasLocalFork = !record.pendingRevisions.isEmpty
            || record.conflict != nil
            || record.localHead.revisionID != record.lastKnownRemoteHead?.revisionID
        guard hasLocalFork,
              record.localHead.contentDigest != remote.contentDigest else { return }
        record.conflict = EpisodeConflict(
            base: record.conflict?.base ?? record.lastKnownRemoteHead,
            local: record.localHead,
            remote: remote
        )
        record.integrationReviewDraft = record.conflict.map {
            makeReviewDraft(
                for: $0,
                reason: $0.base == nil ? .commonAncestorUnknown : .ambiguousChanges,
                proposedContent: $0.local.content
            )
        }
        record.pendingMaterialization = nil
        record.remoteConfirmation = .unconfirmed
        record.reconciliationStatus = .reviewRequired
        record.mode = .forcedFork
    }

    func makeRevision(
        content: String,
        parents: [SyncRevisionID],
        branchID: SyncBranchID,
        createdAt: Date
    ) throws -> EpisodeRevision {
        try EpisodeRevision(
            key: key,
            parentRevisionIDs: parents,
            branchID: branchID,
            authorReplicaID: replicaID,
            authorSessionID: sessionID,
            content: content,
            clientCreatedAt: createdAt
        )
    }

    func ownedLease(from snapshot: EpisodeRemoteSnapshot) -> EpisodeLease? {
        guard snapshot.lease?.authority.holderReplicaID == replicaID,
              snapshot.lease?.authority.holderSessionID == sessionID else { return nil }
        return snapshot.lease
    }

    func context(for record: EpisodeSyncJournalRecord) -> EpisodeSyncContext {
        EpisodeSyncContext(
            key: record.key,
            localWorkingCopyID: record.localWorkingCopyID ?? localWorkingCopyID,
            branchID: record.branchID,
            localHead: record.localHead,
            lastKnownRemoteHead: record.lastKnownRemoteHead,
            lease: record.lease,
            pendingRevisionCount: record.pendingRevisions.count,
            remoteConfirmation: record.remoteConfirmation,
            pendingMaterialization: record.pendingMaterialization,
            hasExplicitLocalChanges: record.localEditIntent == .explicit,
            reconciliationStatus: record.reconciliationStatus
        )
    }

    func makeReviewDraft(
        for conflict: EpisodeConflict,
        reason: EpisodeIntegrationReviewDraft.Reason,
        proposedContent: String
    ) -> EpisodeIntegrationReviewDraft {
        EpisodeIntegrationReviewDraft(
            baseRevisionID: conflict.base?.revisionID,
            localRevisionID: conflict.local.revisionID,
            remoteRevisionID: conflict.remote.revisionID,
            proposedContent: proposedContent,
            reason: reason
        )
    }

    func refreshRemoteConfirmation(in record: inout EpisodeSyncJournalRecord) {
        let isExactRemote = record.localHead.revisionID == record.lastKnownRemoteHead?.revisionID
            && record.localHead.contentDigest == record.lastKnownRemoteHead?.contentDigest
        record.remoteConfirmation = isExactRemote
            && record.pendingRevisions.isEmpty
            && record.conflict == nil
            && record.pendingMaterialization == nil
            ? .confirmed
            : .unconfirmed
        if record.remoteConfirmation == .confirmed {
            record.localEditIntent = .observed
            record.reconciliationStatus = .idle
        } else if record.conflict != nil {
            record.reconciliationStatus = .reviewRequired
        } else if record.reconciliationStatus != .offline {
            record.reconciliationStatus = .pending
        }
    }

    func publishHead(in record: EpisodeSyncJournalRecord) -> EpisodeRevision {
        record.pendingMaterialization?.integratedRevision ?? record.localHead
    }

    func stateForRecord(_ record: EpisodeSyncJournalRecord) -> EpisodeSyncState {
        let context = context(for: record)
        if let conflict = record.conflict {
            return .conflicted(context, conflict)
        }
        if !record.pendingRevisions.isEmpty || record.pendingMaterialization != nil {
            return record.mode == .forcedFork ? .offlineFork(context) : .localChanges(context)
        }
        return .upToDate(context)
    }

    func persistAndUpdateState(forcedOffline: Bool = false) async throws {
        guard var record else { throw EpisodeSyncCoordinatorError.notLinked }
        refreshRemoteConfirmation(in: &record)
        self.record = record
        try await journal.save(record)
        state = forcedOffline ? .offlineFork(context(for: record)) : stateForRecord(record)
    }
}

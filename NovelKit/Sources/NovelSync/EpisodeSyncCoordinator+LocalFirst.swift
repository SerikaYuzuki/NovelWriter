import Foundation

public extension EpisodeSyncCoordinator {
    /// network不能を含む初回Editor表示前に、現在のpackage本文を非編集baselineとして保存する。
    /// package保存とjournal保存の間で終了しても、再起動時にdigest差から実変更を復元できる。
    @discardableResult
    func observeLocalBase(
        localContent: String,
        createdAt: Date
    ) async throws -> EpisodeSyncState {
        await acquireLocalJournalOperation()
        defer { releaseLocalJournalOperation() }
        if let current = try await loadLocalRecordIfNecessary() {
            state = stateForRecord(current)
            return state
        }
        let branchID = SyncBranchID()
        let localHead = try makeRevision(
            content: localContent,
            parents: [],
            branchID: branchID,
            createdAt: createdAt
        )
        let observed = try EpisodeSyncJournalRecord(
            key: key,
            localWorkingCopyID: localWorkingCopyID,
            replicaID: replicaID,
            branchID: branchID,
            lastKnownRemoteHead: nil,
            localHead: localHead,
            pendingRevisions: [],
            lease: nil,
            remoteConfirmation: .unconfirmed,
            localEditIntent: .observed,
            reconciliationStatus: .idle,
            mode: .tracking
        )
        record = observed
        try await journal.save(observed)
        state = stateForRecord(observed)
        return state
    }

    /// Editor表示時のread-only bootstrap。remoteをclaim/publishせず、package本文と
    /// exact remote baseだけをjournalへ保存する。閲覧だけではedit intentを立てない。
    @discardableResult
    func observeRemoteBase(
        localContent: String,
        createdAt: Date
    ) async throws -> EpisodeSyncState {
        await acquireRemoteControlOperation()
        defer { releaseRemoteControlOperation() }
        let snapshot = try await transport.fetchSnapshot(for: key)
        try validateLocalFirstSnapshot(snapshot)
        return try await observeFetchedRemoteBase(
            localContent: localContent,
            snapshot: snapshot,
            createdAt: createdAt
        )
    }

    /// native editor/model/packageの保存後に呼ぶ、authority非依存のlocal durability境界。
    /// 未link・offlineでも最初の本文からstable branchを作り、戻る前にjournalへ保存する。
    @discardableResult
    func recordLocalEdit(
        _ content: String,
        createdAt: Date
    ) async throws -> EpisodeLocalEditReceipt {
        await acquireLocalJournalOperation()
        defer { releaseLocalJournalOperation() }
        return try await recordLocalEditInJournalLane(content, createdAt: createdAt)
    }

    @discardableResult
    func synchronizeLocalFirst(
        expiresAt: Date,
        createdAt: Date
    ) async throws -> EpisodeSyncState {
        await acquireLocalJournalOperation()
        do {
            _ = try await loadLocalRecordIfNecessary()
            releaseLocalJournalOperation()
        } catch {
            releaseLocalJournalOperation()
            throw error
        }
        await acquireRemoteControlOperation()
        defer { releaseRemoteControlOperation() }
        return try await synchronizeLocalFirstSerially(
            expiresAt: expiresAt,
            createdAt: createdAt
        )
    }

    /// AppがIME/selection/editor generationを検査し、integrated本文をpackage/nativeへ
    /// installした後だけ呼ぶexact ack。古いcallbackで新しいworking本文を消さない。
    @discardableResult
    func confirmIntegratedContentMaterialized(
        _ expected: EpisodePendingMaterialization,
        installedContentDigest: SyncContentDigest
    ) async throws -> EpisodeSyncState {
        await acquireLocalJournalOperation()
        defer { releaseLocalJournalOperation() }
        guard var current = record,
              current.pendingMaterialization == expected else {
            throw EpisodeSyncCoordinatorError.materializationNotPending
        }
        guard installedContentDigest == expected.integratedRevision.contentDigest else {
            throw EpisodeSyncCoordinatorError.installedDigestMismatch
        }
        current.localHead = expected.integratedRevision
        current.pendingMaterialization = nil
        current.mode = current.conflict == nil ? .tracking : .forcedFork
        refreshRemoteConfirmation(in: &current)
        record = current
        try await journal.save(current)
        state = stateForRecord(current)
        return state
    }
}

extension EpisodeSyncCoordinator {
    enum LocalFirstPreparation {
        case finished(EpisodeSyncState)
        case publish
        case retry
    }

    func synchronizeLocalFirstSerially(
        expiresAt: Date,
        createdAt: Date
    ) async throws -> EpisodeSyncState {
        guard record != nil else { throw EpisodeSyncCoordinatorError.notLinked }
        if let current = record,
           current.stagedConflictResolution != nil,
           current.conflict != nil {
            state = stateForRecord(current)
            return state
        }
        if record?.sealedPublish != nil {
            _ = try await synchronizeSerially()
            if record?.sealedPublish != nil || record?.conflict != nil {
                return state
            }
        }
        if let current = record,
           let staged = try pendingLocalFirstConflictResolutionStage(in: current) {
            return try await publishMaterializedConflictResolution(staged, expiresAt: expiresAt)
        }
        for _ in 0 ..< 4 {
            let preparation = try await nextLocalFirstPreparation(
                expiresAt: expiresAt,
                createdAt: createdAt
            )
            switch preparation {
            case let .finished(finished):
                return finished
            case .retry:
                continue
            case .publish:
                return try await drainLocalFirstPublishTail()
            }
        }
        guard let current = record else { throw EpisodeSyncCoordinatorError.notLinked }
        state = stateForRecord(current)
        return state
    }

    func nextLocalFirstPreparation(
        expiresAt: Date,
        createdAt: Date
    ) async throws -> LocalFirstPreparation {
        do {
            let snapshot = try await transport.fetchSnapshot(for: key)
            try validateLocalFirstSnapshot(snapshot)
            try await markLocalFirstReconnected()
            return try await prepareLocalFirstSynchronization(
                snapshot: snapshot,
                expiresAt: expiresAt,
                createdAt: createdAt
            )
        } catch EpisodeSyncTransportError.unavailable {
            return try await .finished(preserveOfflineState())
        }
    }

    func markLocalFirstReconnected() async throws {
        await acquireLocalJournalOperation()
        defer { releaseLocalJournalOperation() }
        guard var reconnected = record,
              reconnected.reconciliationStatus == .offline else {
            return
        }
        reconnected.reconciliationStatus = .pending
        record = reconnected
        try await journal.save(reconnected)
    }

    func prepareLocalFirstSynchronization(
        snapshot: EpisodeRemoteSnapshot,
        expiresAt: Date,
        createdAt: Date
    ) async throws -> LocalFirstPreparation {
        guard var current = record else { throw EpisodeSyncCoordinatorError.notLinked }
        if let equivalent = try await prepareEquivalentRemote(
            snapshot: snapshot,
            record: &current
        ) {
            return equivalent
        }
        guard hasUnconfirmedLocalContent(current) else {
            return try await prepareObservedSynchronization(snapshot: snapshot, record: &current)
        }
        return try await prepareExplicitSynchronization(
            snapshot: snapshot,
            expiresAt: expiresAt,
            createdAt: createdAt,
            record: &current
        )
    }

    func prepareEquivalentRemote(
        snapshot: EpisodeRemoteSnapshot,
        record: inout EpisodeSyncJournalRecord
    ) async throws -> LocalFirstPreparation? {
        guard let remote = snapshot.head else { return nil }
        let observation = localFirstObservation(of: record)
        if record.localHead.contentDigest == remote.contentDigest {
            collapseLocalFirstEquivalent(into: remote, snapshot: snapshot, record: &record)
            guard let saved = try await saveLocalFirstPreparedRecord(
                record,
                replacing: observation
            ) else { return .retry }
            return .finished(saved)
        }
        guard let materialization = record.pendingMaterialization,
              materialization.integratedRevision.contentDigest == remote.contentDigest else {
            return nil
        }
        record.lastKnownRemoteHead = remote
        record.pendingRevisions.removeAll()
        record.sealedPublish = nil
        record.pendingMaterialization = EpisodePendingMaterialization(
            workingRevisionID: record.localHead.revisionID,
            integratedRevision: remote
        )
        record.lease = ownedLease(from: snapshot)
        record.remoteConfirmation = .unconfirmed
        record.reconciliationStatus = .pending
        guard let saved = try await saveLocalFirstPreparedRecord(
            record,
            replacing: observation
        ) else { return .retry }
        return .finished(saved)
    }

    func prepareObservedSynchronization(
        snapshot: EpisodeRemoteSnapshot,
        record: inout EpisodeSyncJournalRecord
    ) async throws -> LocalFirstPreparation {
        if record.conflict != nil {
            return .finished(stateForRecord(record))
        }
        guard let remote = snapshot.head else {
            return .finished(stateForRecord(record))
        }
        let observation = localFirstObservation(of: record)
        guard let base = observedRemoteBase(for: record) else {
            setLocalFirstConflict(
                in: &record,
                base: nil,
                remote: remote,
                reason: .commonAncestorUnknown
            )
            guard let saved = try await saveLocalFirstPreparedRecord(
                record,
                replacing: observation
            ) else { return .retry }
            return .finished(saved)
        }
        let descendsFromKnownBase = try await remoteRevision(remote, descendsFrom: base)
        guard let latest = self.record,
              latest.localEditIntent == .observed,
              localFirstObservation(of: latest) == observation else {
            return .retry
        }
        record = latest
        if descendsFromKnownBase {
            stageObservedRemoteMaterialization(remote, snapshot: snapshot, record: &record)
        } else {
            setLocalFirstConflict(
                in: &record,
                base: nil,
                remote: remote,
                reason: .commonAncestorUnknown
            )
        }
        guard let saved = try await saveLocalFirstPreparedRecord(
            record,
            replacing: observation
        ) else { return .retry }
        return .finished(saved)
    }

    func prepareExplicitSynchronization(
        snapshot: EpisodeRemoteSnapshot,
        expiresAt: Date,
        createdAt: Date,
        record: inout EpisodeSyncJournalRecord
    ) async throws -> LocalFirstPreparation {
        let observation = localFirstObservation(of: record)
        let relationship = try await localFirstRelationship(record: record, snapshot: snapshot)
        guard let latest = self.record,
              localFirstObservation(of: latest) == observation else {
            return .retry
        }
        record = latest
        switch relationship {
        case .unknown:
            return try await prepareUnknownRelationship(
                snapshot: snapshot,
                expiresAt: expiresAt,
                record: &record
            )
        case .direct:
            return try await prepareDirectLocalFirstPublish(
                snapshot: snapshot,
                expiresAt: expiresAt
            )
        case let .merge(base, remote):
            return try await prepareLocalFirstMerge(
                LocalFirstMergeRequest(
                    base: base,
                    remote: remote,
                    snapshot: snapshot,
                    expiresAt: expiresAt,
                    createdAt: createdAt
                ),
                record: &record
            )
        }
    }
}

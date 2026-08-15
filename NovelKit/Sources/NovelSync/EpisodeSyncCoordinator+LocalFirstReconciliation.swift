import Foundation

extension EpisodeSyncCoordinator {
    struct LocalFirstMergeRequest {
        let base: EpisodeRevision
        let remote: EpisodeRevision
        let snapshot: EpisodeRemoteSnapshot
        let expiresAt: Date
        let createdAt: Date
    }

    enum LocalFirstRelationship {
        case direct
        case merge(base: EpisodeRevision, remote: EpisodeRevision)
        case unknown
    }

    func prepareUnknownRelationship(
        snapshot: EpisodeRemoteSnapshot,
        expiresAt: Date,
        record: inout EpisodeSyncJournalRecord
    ) async throws -> LocalFirstPreparation {
        guard let remote = snapshot.head else {
            return try await prepareDirectLocalFirstPublish(
                snapshot: snapshot,
                expiresAt: expiresAt
            )
        }
        let observation = localFirstObservation(of: record)
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

    func prepareLocalFirstMerge(
        _ request: LocalFirstMergeRequest,
        record: inout EpisodeSyncJournalRecord
    ) async throws -> LocalFirstPreparation {
        let observation = localFirstObservation(of: record)
        switch PortableThreeWayTextMerger.analyze(
            base: request.base.content,
            local: record.localHead.content,
            remote: request.remote.content
        ) {
        case let .conflict(conflict):
            setLocalFirstConflict(
                in: &record,
                base: request.base,
                remote: request.remote,
                reason: reviewReason(for: conflict.reason),
                proposedContent: conflict.proposedContent
            )
            guard let saved = try await saveLocalFirstPreparedRecord(
                record,
                replacing: observation
            ) else { return .retry }
            return .finished(saved)
        case let .merged(mergedContent):
            return try await prepareMergedLocalFirstPublish(
                mergedContent: mergedContent,
                request: request,
                record: &record
            )
        }
    }

    func prepareMergedLocalFirstPublish(
        mergedContent: String,
        request: LocalFirstMergeRequest,
        record: inout EpisodeSyncJournalRecord
    ) async throws -> LocalFirstPreparation {
        let observation = localFirstObservation(of: record)
        guard let granted = try await acquireLocalFirstAuthority(
            matching: request.snapshot,
            expiresAt: request.expiresAt
        ) else { return .retry }
        guard granted.head?.revisionID == request.remote.revisionID,
              granted.head?.contentDigest == request.remote.contentDigest else {
            return .retry
        }
        await acquireLocalJournalOperation()
        defer { releaseLocalJournalOperation() }
        guard let latest = self.record else {
            throw EpisodeSyncCoordinatorError.notLinked
        }
        record = latest
        guard localFirstObservation(of: latest) == observation else {
            try activateLocalFirstAuthority(granted, record: &record, updateRemoteHead: false)
            self.record = record
            try await journal.save(record)
            return .retry
        }
        try prepareAutomaticMerge(
            mergedContent: mergedContent,
            remote: request.remote,
            createdAt: request.createdAt,
            record: &record
        )
        try activateLocalFirstAuthority(granted, record: &record)
        self.record = record
        try await journal.save(record)
        return .publish
    }

    func localFirstRelationship(
        record: EpisodeSyncJournalRecord,
        snapshot: EpisodeRemoteSnapshot
    ) async throws -> LocalFirstRelationship {
        guard let remote = snapshot.head else {
            return record.lastKnownRemoteHead == nil ? .direct : .unknown
        }
        guard let base = record.conflict?.base ?? record.lastKnownRemoteHead else {
            return .unknown
        }
        if remote.revisionID == base.revisionID,
           remote.contentDigest == base.contentDigest {
            return .direct
        }
        guard localRevision(record.localHead, descendsFrom: base, in: record),
              try await remoteRevision(remote, descendsFrom: base) else {
            return .unknown
        }
        return .merge(base: base, remote: remote)
    }

    func prepareDirectLocalFirstPublish(
        snapshot: EpisodeRemoteSnapshot,
        expiresAt: Date
    ) async throws -> LocalFirstPreparation {
        guard let granted = try await acquireLocalFirstAuthority(
            matching: snapshot,
            expiresAt: expiresAt
        ) else { return .retry }
        await acquireLocalJournalOperation()
        defer { releaseLocalJournalOperation() }
        guard var current = record else { throw EpisodeSyncCoordinatorError.notLinked }
        if current.conflict != nil {
            current.lease = granted.lease
            authorityVerifiedInProcess = false
            record = current
            try await journal.save(current)
            state = stateForRecord(current)
            return .finished(state)
        }
        if granted.head?.revisionID != snapshot.head?.revisionID
            || granted.head?.contentDigest != snapshot.head?.contentDigest {
            return .retry
        }
        current.lastKnownRemoteHead = granted.head
        try appendCurrentSessionRelayIfNeeded(record: &current)
        try activateLocalFirstAuthority(granted, record: &current)
        record = current
        try await journal.save(current)
        return .publish
    }
}

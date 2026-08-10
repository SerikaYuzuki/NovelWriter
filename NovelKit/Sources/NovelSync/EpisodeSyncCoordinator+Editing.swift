import Foundation

public extension EpisodeSyncCoordinator {
    /// ローカル確定本文をimmutable revisionとしてjournalへ先に保存する。
    @discardableResult
    func recordLocalContent(
        _ content: String,
        createdAt: Date
    ) async throws -> EpisodeSyncState {
        guard var record else { throw EpisodeSyncCoordinatorError.notLinked }
        guard authorityVerifiedInProcess,
              pendingAuthorityGrant == nil,
              record.lease?.authority.holderReplicaID == replicaID,
              record.lease?.authority.holderSessionID == sessionID else {
            throw EpisodeSyncCoordinatorError.noEditingAuthority
        }
        try appendLocalRevision(content: content, createdAt: createdAt, to: &record)
        self.record = record
        try await persistAndUpdateState()
        return state
    }

    /// network await中にnative editorへ入った確定本文を、すでに成立した
    /// conflictの新しいlocal側としてofflineでもjournalへ退避する。
    /// remote本文を表示中なら既存local forkを置換せず、そのままsurfaceする。
    @discardableResult
    func preserveConflictLocalContent(
        _ content: String,
        expectedConflict: EpisodeConflict,
        createdAt: Date
    ) async throws -> EpisodeSyncState {
        guard var record else { throw EpisodeSyncCoordinatorError.notLinked }
        guard record.conflict == expectedConflict else {
            throw EpisodeSyncCoordinatorError.conflictSuperseded
        }
        let digest = SyncContentDigest(content: content)
        if digest != expectedConflict.local.contentDigest,
           digest != expectedConflict.remote.contentDigest {
            try appendConflictLocalRevision(content: content, createdAt: createdAt, to: &record)
            record.mode = .forcedFork
            self.record = record
            try await journal.save(record)
        }
        guard let conflict = record.conflict else {
            throw EpisodeSyncCoordinatorError.noConflict
        }
        state = .conflicted(context(for: record), conflict)
        return state
    }

    /// 両parentを持つ新revisionだけをremote head候補にし、既存の両本文を消さない。
    @discardableResult
    func resolveConflict(
        using choice: EpisodeIntegrationChoice,
        createdAt: Date
    ) async throws -> EpisodeSyncState {
        guard var record else { throw EpisodeSyncCoordinatorError.notLinked }
        guard let conflict = record.conflict else {
            throw EpisodeSyncCoordinatorError.noConflict
        }
        guard authorityVerifiedInProcess,
              record.lease?.authority.holderReplicaID == replicaID,
              record.lease?.authority.holderSessionID == sessionID else {
            throw EpisodeSyncCoordinatorError.noEditingAuthority
        }

        let merge = try makeRevision(
            content: choice.resolvedContent(for: conflict),
            parents: [conflict.remote.revisionID, conflict.local.revisionID],
            branchID: record.branchID,
            createdAt: createdAt
        )
        record.pendingRevisions.append(merge)
        record.localHead = merge
        record.lastKnownRemoteHead = conflict.remote
        record.conflict = nil
        // merge markerをAppが先にdurable化した後、ここでprocessが終了しても
        // fresh sessionが同じmutationをreceipt replayできるよう、merge revisionと
        // publish sealを一度のjournal saveへまとめる。
        record.sealedPublish = EpisodeSealedPublish(
            mutationID: SyncMutationID(),
            revisionIDs: record.pendingRevisions.map(\.revisionID),
            candidateHeadRevisionID: merge.revisionID,
            expectedHeadRevisionID: conflict.remote.revisionID
        )
        self.record = record
        try await persistAndUpdateState()
        return try await synchronize()
    }
}

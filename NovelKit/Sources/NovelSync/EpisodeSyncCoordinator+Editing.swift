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
        record.sealedPublish = nil
        self.record = record
        try await persistAndUpdateState()
        return try await synchronize()
    }
}

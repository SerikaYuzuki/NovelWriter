import Foundation

extension EpisodeSyncCoordinator {
    func requestLease(
        kind: EpisodeLeaseClaimKind,
        snapshot: EpisodeRemoteSnapshot,
        expectedHead: EpisodeRevision? = nil,
        expiresAt: Date
    ) async throws -> EpisodeLeaseClaimResult {
        guard record != nil else { throw EpisodeSyncCoordinatorError.notLinked }
        let request = try EpisodeLeaseClaimRequest(
            key: key,
            requesterReplicaID: replicaID,
            requesterSessionID: sessionID,
            expectedEpoch: snapshot.leaseEpoch,
            expectedHeadRevisionID: expectedHead?.revisionID,
            expectedHeadContentDigest: expectedHead?.contentDigest,
            expiresAt: expiresAt,
            kind: kind
        )
        return try await transport.claimLease(request)
    }

    func applyRejectedConflictClaim(_ result: EpisodeLeaseClaimResult) async throws {
        switch result {
        case let .denied(snapshot), let .changed(snapshot):
            try await applyFence(snapshot, expectedAuthority: nil)
        case .granted:
            break
        }
    }
}

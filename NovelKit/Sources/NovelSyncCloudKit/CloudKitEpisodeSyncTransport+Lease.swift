import NovelSync

public extension CloudKitEpisodeSyncTransport {
    func claimLease(_ request: EpisodeLeaseClaimRequest) async throws -> EpisodeLeaseClaimResult {
        try await ensureZone()
        try await requireWorkExists(request.key.workID)
        let control = try await fetchControl(for: request.key)
        let currentSnapshot = try await materializeSnapshot(control)
        guard request.expectedEpoch == control.leaseEpoch else {
            return .changed(currentSnapshot)
        }

        let newEpoch: UInt64
        switch request.kind {
        case .acquireOrRenew:
            if let currentLease = control.lease {
                guard currentLease.authority.holderReplicaID == request.requesterReplicaID,
                      currentLease.authority.holderSessionID == request.requesterSessionID else {
                    return .denied(currentSnapshot)
                }
                newEpoch = currentLease.authority.epoch
            } else {
                newEpoch = try incrementedEpoch(control.leaseEpoch)
            }
        case .forceTakeover:
            newEpoch = try incrementedEpoch(control.leaseEpoch)
        }
        let authority = try EpisodeLeaseAuthority(
            holderReplicaID: request.requesterReplicaID,
            holderSessionID: request.requesterSessionID,
            epoch: newEpoch
        )
        let lease = EpisodeLease(authority: authority, expiresAt: request.expiresAt)
        let updated = try codec.updateControlRecord(
            control.record,
            key: request.key,
            headRevisionID: control.headRevisionID,
            leaseEpoch: newEpoch,
            lease: lease
        )

        do {
            let saved = try await modifyAtomically([updated])
            guard let savedControl = saved[updated.recordID] else {
                throw CloudKitSyncAdapterError.operationFailed
            }
            let decoded = try codec.decodeControlRecord(savedControl, expectedKey: request.key)
            return try await .granted(materializeSnapshot(decoded))
        } catch {
            if CloudKitErrorMapper.containsServerRecordChanged(error) {
                return try await .changed(fetchSnapshot(for: request.key))
            }
            throw mappedOperationError(error)
        }
    }

    func releaseLease(
        key: EpisodeSyncKey,
        expectedAuthority: EpisodeLeaseAuthority
    ) async throws -> EpisodeRemoteSnapshot {
        try await ensureZone()
        try await requireWorkExists(key.workID)
        let control = try await fetchControl(for: key)
        guard control.lease?.authority == expectedAuthority else {
            return try await materializeSnapshot(control)
        }
        let updated = try codec.updateControlRecord(
            control.record,
            key: key,
            headRevisionID: control.headRevisionID,
            leaseEpoch: control.leaseEpoch,
            lease: nil
        )
        do {
            let saved = try await modifyAtomically([updated])
            guard let savedControl = saved[updated.recordID] else {
                throw CloudKitSyncAdapterError.operationFailed
            }
            let decoded = try codec.decodeControlRecord(savedControl, expectedKey: key)
            return try await materializeSnapshot(decoded)
        } catch {
            if CloudKitErrorMapper.containsServerRecordChanged(error) {
                return try await fetchSnapshot(for: key)
            }
            throw mappedOperationError(error)
        }
    }
}

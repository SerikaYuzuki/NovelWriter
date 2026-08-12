import Foundation

extension EpisodeSyncCoordinator {
    func hasUnconfirmedLocalContent(_ record: EpisodeSyncJournalRecord) -> Bool {
        record.localEditIntent == .explicit
            && (!record.pendingRevisions.isEmpty
                || record.conflict != nil
                || record.pendingMaterialization != nil
                || record.localHead.revisionID != record.lastKnownRemoteHead?.revisionID
                || record.localHead.contentDigest != record.lastKnownRemoteHead?.contentDigest)
    }

    func localRevision(
        _ local: EpisodeRevision,
        descendsFrom base: EpisodeRevision,
        in record: EpisodeSyncJournalRecord
    ) -> Bool {
        let revisions = record.pendingRevisions
            + [record.localHead]
            + [record.pendingMaterialization?.integratedRevision].compactMap(\.self)
        var byID: [SyncRevisionID: EpisodeRevision] = [:]
        for revision in revisions {
            byID[revision.revisionID] = revision
        }
        var frontier = [local.revisionID]
        var visited: Set<SyncRevisionID> = []
        while let revisionID = frontier.popLast(), visited.count <= 64 {
            guard visited.insert(revisionID).inserted else { continue }
            if revisionID == base.revisionID {
                return true
            }
            guard let revision = byID[revisionID] else { continue }
            frontier.append(contentsOf: revision.parentRevisionIDs)
        }
        return false
    }

    func remoteRevision(
        _ remote: EpisodeRevision,
        descendsFrom base: EpisodeRevision
    ) async throws -> Bool {
        var frontier = remote.parentRevisionIDs
        var visited: Set<SyncRevisionID> = []
        while let revisionID = frontier.popLast(), visited.count < 64 {
            guard visited.insert(revisionID).inserted else { continue }
            let revision: EpisodeRevision
            do {
                revision = try await transport.fetchRevision(revisionID, for: key)
            } catch EpisodeSyncTransportError.missingRevision {
                return false
            }
            try revision.validate()
            guard revision.key == key,
                  revision.revisionID == revisionID else {
                throw EpisodeSyncCoordinatorError.malformedRemoteSnapshot
            }
            if revisionID == base.revisionID {
                return revision == base
            }
            frontier.append(contentsOf: revision.parentRevisionIDs)
        }
        return false
    }

    struct LocalFirstRecordObservation: Equatable {
        let localRevisionID: SyncRevisionID
        let localDigest: SyncContentDigest
        let pendingRevisionIDs: [SyncRevisionID]
        let conflict: EpisodeConflict?
        let materialization: EpisodePendingMaterialization?
        let editIntent: EpisodeLocalEditIntent
    }

    func localFirstObservation(
        of record: EpisodeSyncJournalRecord
    ) -> LocalFirstRecordObservation {
        LocalFirstRecordObservation(
            localRevisionID: record.localHead.revisionID,
            localDigest: record.localHead.contentDigest,
            pendingRevisionIDs: record.pendingRevisions.map(\.revisionID),
            conflict: record.conflict,
            materialization: record.pendingMaterialization,
            editIntent: record.localEditIntent
        )
    }

    func validateLocalFirstSnapshot(_ snapshot: EpisodeRemoteSnapshot) throws {
        guard let head = snapshot.head else { return }
        try head.validate()
        guard head.key == key else {
            throw EpisodeSyncCoordinatorError.malformedRemoteSnapshot
        }
    }

    func reviewReason(
        for reason: PortableTextMergeConflictReason
    ) -> EpisodeIntegrationReviewDraft.Reason {
        switch reason {
        case .inputLimitExceeded:
            .inputLimitExceeded
        case .sameInsertionPoint:
            .sameInsertionPoint
        case .overlappingChanges:
            .overlappingChanges
        case .ambiguousChanges:
            .ambiguousChanges
        }
    }
}

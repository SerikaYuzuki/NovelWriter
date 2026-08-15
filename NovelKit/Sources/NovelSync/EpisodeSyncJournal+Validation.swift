import Foundation

extension EpisodeSyncJournalRecord {
    public func validate() throws {
        try validateVersionsAndRevisionKeys()
        try validatePendingRevisionGraph()
        try validateSealedPublish()
        try validateMaterialization()
        try validateResolutionRecovery()
        try validateObservedState()
        try validateReviewState()
    }

    func validateVersionsAndRevisionKeys() throws {
        guard schemaVersion == Self.currentSchemaVersion else {
            throw EpisodeSyncJournalError.unsupportedSchemaVersion(schemaVersion)
        }
        guard protocolVersion == SyncWireProtocol.currentVersion else {
            throw SyncWireError.unsupportedProtocolVersion(protocolVersion)
        }
        let revisions = [
            localHead,
            lastKnownRemoteHead,
            conflict?.base,
            conflict?.local,
            conflict?.remote,
            stagedConflictResolution,
            conflictResolutionRecovery?.sourceLocalRevision,
            conflictResolutionRecovery?.sourceRemoteRevision,
            conflictResolutionRecovery?.chosenRevision,
            conflictResolutionRecovery?.supersededChosenRevision
        ]
        .compactMap(\.self)
        guard revisions.allSatisfy({ $0.key == key }) else {
            throw EpisodeSyncJournalError.keyMismatch
        }
        for revision in revisions {
            try revision.validate()
        }
    }

    func validatePendingRevisionGraph() throws {
        guard pendingRevisions.count <= Self.maximumPendingRevisionCount else {
            throw EpisodeSyncJournalError.tooManyPendingRevisions
        }
        guard conflict == nil
            || pendingRevisions.count <= Self.maximumConflictPendingRevisionCount else {
            throw EpisodeSyncJournalError.tooManyPendingRevisions
        }
        for revision in pendingRevisions {
            try revision.validate()
            guard revision.key == key else {
                throw EpisodeSyncJournalError.revisionKeyMismatch
            }
        }
        let pendingIDs = pendingRevisions.map(\.revisionID)
        guard Set(pendingIDs).count == pendingIDs.count else {
            throw EpisodeSyncJournalError.pendingChainBroken
        }
        let publishHeadID = pendingMaterialization?.integratedRevision.revisionID
            ?? localHead.revisionID
        guard pendingRevisions.last?.revisionID == publishHeadID
            || pendingRevisions.isEmpty else {
            throw EpisodeSyncJournalError.localHeadMissing
        }
        try validatePendingParentOrder()
        try validatePendingReachability(from: publishHeadID)
    }

    func validatePendingParentOrder() throws {
        let pendingIndex = Dictionary(
            uniqueKeysWithValues: pendingRevisions.enumerated().map { ($0.element.revisionID, $0.offset) }
        )
        for (index, revision) in pendingRevisions.enumerated() {
            let inBatchParents = revision.parentRevisionIDs.compactMap { pendingIndex[$0] }
            guard inBatchParents.allSatisfy({ $0 < index }) else {
                throw EpisodeSyncJournalError.pendingChainBroken
            }
        }
    }

    func validatePendingReachability(from publishHeadID: SyncRevisionID) throws {
        guard !pendingRevisions.isEmpty else { return }
        let pendingByID = Dictionary(
            uniqueKeysWithValues: pendingRevisions.map { ($0.revisionID, $0) }
        )
        var reachable: Set<SyncRevisionID> = []
        var frontier = conflict.map {
            [$0.local.revisionID, $0.remote.revisionID]
        } ?? [publishHeadID]
        while let revisionID = frontier.popLast() {
            guard reachable.insert(revisionID).inserted,
                  let revision = pendingByID[revisionID] else { continue }
            frontier.append(contentsOf: revision.parentRevisionIDs)
        }
        guard Set(pendingByID.keys).isSubset(of: reachable) else {
            throw EpisodeSyncJournalError.pendingChainBroken
        }
    }

    func validateSealedPublish() throws {
        guard let sealedPublish else { return }
        let pendingIDs = Set(pendingRevisions.map(\.revisionID))
        guard !sealedPublish.revisionIDs.isEmpty,
              sealedPublish.revisionIDs.count <= EpisodePublishRequest.maximumRevisionCount,
              sealedPublish.revisionIDs.allSatisfy(pendingIDs.contains),
              sealedPublish.revisionIDs.last == sealedPublish.candidateHeadRevisionID else {
            throw EpisodeSyncJournalError.sealedPublishMismatch
        }
    }

    func validateMaterialization() throws {
        guard conflict == nil || pendingMaterialization == nil else {
            throw EpisodeSyncJournalError.materializationMismatch
        }
        guard let materialization = pendingMaterialization else { return }
        try materialization.integratedRevision.validate()
        guard materialization.workingRevisionID == localHead.revisionID,
              materialization.integratedRevision.key == key else {
            throw EpisodeSyncJournalError.materializationMismatch
        }
        let integratedIsPending = pendingRevisions.contains(materialization.integratedRevision)
        let integratedIsAcknowledged = lastKnownRemoteHead.map {
            $0.revisionID == materialization.integratedRevision.revisionID
                && $0.contentDigest == materialization.integratedRevision.contentDigest
        } ?? false
        guard integratedIsPending || integratedIsAcknowledged else {
            throw EpisodeSyncJournalError.materializationMismatch
        }
    }

    func validateObservedState() throws {
        guard localEditIntent == .observed else { return }
        guard pendingRevisions.isEmpty,
              sealedPublish == nil else {
            throw EpisodeSyncJournalError.pendingChainBroken
        }
        if let conflict {
            guard conflict.base == nil,
                  conflict.local == localHead,
                  pendingMaterialization == nil else {
                throw EpisodeSyncJournalError.pendingChainBroken
            }
        } else if let pendingMaterialization {
            let integrated = pendingMaterialization.integratedRevision
            guard lastKnownRemoteHead?.revisionID == integrated.revisionID,
                  lastKnownRemoteHead?.contentDigest == integrated.contentDigest,
                  reconciliationStatus == .pending else {
                throw EpisodeSyncJournalError.materializationMismatch
            }
        }
    }

    func validateResolutionRecovery() throws {
        if let stagedConflictResolution {
            try validateStagedResolution(stagedConflictResolution)
        }
        guard let recovery = conflictResolutionRecovery else { return }
        if conflict != nil {
            return
        }
        guard let stagedConflictResolution,
              stagedConflictResolution == recovery.chosenRevision,
              pendingRevisions.contains(recovery.chosenRevision),
              stagedConflictResolution.parentRevisionIDs.count == 2,
              hasStoredResolutionParent(stagedConflictResolution.parentRevisionIDs[0]),
              pendingRevisions.contains(where: {
                  $0.revisionID == stagedConflictResolution.parentRevisionIDs[1]
              }),
              pendingMaterialization == nil else {
            throw EpisodeSyncJournalError.reviewDraftMismatch
        }
    }

    func hasStoredResolutionParent(_ revisionID: SyncRevisionID) -> Bool {
        lastKnownRemoteHead?.revisionID == revisionID
            || pendingRevisions.contains { $0.revisionID == revisionID }
    }

    func validateStagedResolution(_ staged: EpisodeRevision) throws {
        guard pendingMaterialization == nil else {
            throw EpisodeSyncJournalError.reviewDraftMismatch
        }
        if let conflict {
            guard sealedPublish == nil,
                  localHead == conflict.local,
                  !pendingRevisions.contains(staged),
                  staged.parentRevisionIDs == [
                      conflict.remote.revisionID,
                      conflict.local.revisionID
                  ] else {
                throw EpisodeSyncJournalError.reviewDraftMismatch
            }
            return
        }
        guard let recovery = conflictResolutionRecovery,
              recovery.chosenRevision == staged,
              pendingRevisions.contains(staged) else {
            throw EpisodeSyncJournalError.reviewDraftMismatch
        }
    }

    func validateReviewState() throws {
        guard conflict == nil || reconciliationStatus == .reviewRequired else {
            throw EpisodeSyncJournalError.reviewDraftMismatch
        }
        if let draft = integrationReviewDraft {
            guard let conflict,
                  draft.baseRevisionID == conflict.base?.revisionID,
                  draft.localRevisionID == conflict.local.revisionID,
                  draft.remoteRevisionID == conflict.remote.revisionID,
                  draft.proposedContent.utf8.count <= EpisodeRevision.maximumContentUTF8Bytes else {
                throw EpisodeSyncJournalError.reviewDraftMismatch
            }
        }
        guard conflict != nil || integrationReviewDraft == nil else {
            throw EpisodeSyncJournalError.reviewDraftMismatch
        }
    }

    static func inferredRemoteConfirmation(
        localHead: EpisodeRevision,
        lastKnownRemoteHead: EpisodeRevision?,
        pendingRevisions: [EpisodeRevision],
        conflict: EpisodeConflict?,
        pendingMaterialization: EpisodePendingMaterialization?
    ) -> EpisodeRemoteConfirmation {
        let isExactRemote = localHead.revisionID == lastKnownRemoteHead?.revisionID
            && localHead.contentDigest == lastKnownRemoteHead?.contentDigest
        return isExactRemote && pendingRevisions.isEmpty && conflict == nil
            && pendingMaterialization == nil
            ? .confirmed
            : .unconfirmed
    }

    static func defaultReviewDraft(
        for conflict: EpisodeConflict?
    ) -> EpisodeIntegrationReviewDraft? {
        guard let conflict else { return nil }
        return EpisodeIntegrationReviewDraft(
            baseRevisionID: conflict.base?.revisionID,
            localRevisionID: conflict.local.revisionID,
            remoteRevisionID: conflict.remote.revisionID,
            proposedContent: conflict.local.content,
            reason: conflict.base == nil ? .commonAncestorUnknown : .ambiguousChanges
        )
    }
}

import Foundation

extension EpisodeSyncCoordinator {
    private struct MaterializationEditContext {
        let oldWorking: EpisodeRevision
        let oldIntegrated: EpisodeRevision
        let newWorking: EpisodeRevision
        let workingParents: [SyncRevisionID]
        let integrationBaseID: SyncRevisionID
        let canReplaceUnsealedPair: Bool
    }

    func recordLocalEditInJournalLane(
        _ content: String,
        createdAt: Date
    ) async throws -> EpisodeLocalEditReceipt {
        var didChange = false
        var current: EpisodeSyncJournalRecord
        if let loaded = try await loadLocalRecordIfNecessary() {
            current = loaded
        } else {
            current = try makeDetachedWorkingRecord(content: content, createdAt: createdAt)
            didChange = true
        }
        guard current.localWorkingCopyID == localWorkingCopyID else {
            throw EpisodeSyncJournalError.workingCopyMismatch
        }
        if SyncContentDigest(content: content) != current.localHead.contentDigest {
            didChange = true
            try appendExplicitLocalEdit(content, createdAt: createdAt, record: &current)
        } else if current.localEditIntent == .observed {
            didChange = true
            promoteObservedMutation(record: &current)
        }
        if didChange {
            markLocalEditPending(record: &current)
        }
        record = current
        try await journal.save(current)
        state = stateForRecord(current)
        return EpisodeLocalEditReceipt(
            localWorkingCopyID: localWorkingCopyID,
            revisionID: current.localHead.revisionID,
            contentDigest: current.localHead.contentDigest,
            state: state
        )
    }

    func appendExplicitLocalEdit(
        _ content: String,
        createdAt: Date,
        record: inout EpisodeSyncJournalRecord
    ) throws {
        if record.pendingMaterialization != nil {
            try appendEditWhileAwaitingMaterialization(
                content: content,
                createdAt: createdAt,
                to: &record
            )
        } else if record.conflict != nil {
            preserveStagedConflictResolutionBeforeEdit(record: &record)
            if record.conflictResolutionRecovery != nil {
                try appendRecoveredConflictLocalRevision(
                    content: content,
                    createdAt: createdAt,
                    to: &record
                )
            } else if record.localEditIntent == .observed, record.pendingRevisions.isEmpty {
                record.pendingRevisions = [record.localHead]
                try appendConflictLocalRevision(content: content, createdAt: createdAt, to: &record)
            } else {
                try appendConflictLocalRevision(content: content, createdAt: createdAt, to: &record)
            }
        } else if record.stagedConflictResolution != nil,
                  record.conflictResolutionRecovery != nil {
            try appendConflictResolutionTail(content: content, createdAt: createdAt, to: &record)
        } else if record.localEditIntent == .observed, record.pendingRevisions.isEmpty {
            try appendFirstExplicitEdit(content: content, createdAt: createdAt, to: &record)
        } else {
            try appendLocalRevision(content: content, createdAt: createdAt, to: &record)
        }
    }

    func appendRecoveredConflictLocalRevision(
        content: String,
        createdAt: Date,
        to record: inout EpisodeSyncJournalRecord
    ) throws {
        guard let conflict = record.conflict,
              let recovery = record.conflictResolutionRecovery,
              SyncContentDigest(content: content) != record.localHead.contentDigest else { return }
        let revision = try makeRevision(
            content: content,
            parents: [recovery.sourceLocalRevision.revisionID],
            branchID: record.branchID,
            createdAt: createdAt
        )
        var retainedAncestry = try orderedKnownResolutionAncestry(
            endingAt: recovery.sourceLocalRevision,
            pendingRevisions: record.pendingRevisions,
            supplementalRevisions: [
                recovery.sourceLocalRevision,
                recovery.chosenRevision,
                recovery.supersededChosenRevision
            ].compactMap(\.self)
        )
        try appendResolutionRevision(revision, to: &retainedAncestry)
        guard retainedAncestry.count <= EpisodeSyncJournalRecord.maximumConflictPendingRevisionCount else {
            throw EpisodeSyncJournalError.tooManyPendingRevisions
        }
        record.localHead = revision
        record.pendingRevisions = retainedAncestry
        record.lastKnownRemoteHead = nil
        let updatedConflict = EpisodeConflict(base: nil, local: revision, remote: conflict.remote)
        record.conflict = updatedConflict
        record.integrationReviewDraft = makeReviewDraft(
            for: updatedConflict,
            reason: .ambiguousChanges,
            proposedContent: content
        )
        record.remoteConfirmation = .unconfirmed
        record.localEditIntent = .explicit
        record.reconciliationStatus = .reviewRequired
    }

    func appendConflictResolutionTail(
        content: String,
        createdAt: Date,
        to record: inout EpisodeSyncJournalRecord
    ) throws {
        guard SyncContentDigest(content: content) != record.localHead.contentDigest,
              let chosen = record.stagedConflictResolution else { return }
        if record.sealedPublish != nil {
            try appendLocalRevision(content: content, createdAt: createdAt, to: &record)
            return
        }
        guard let chosenIndex = record.pendingRevisions.firstIndex(of: chosen) else {
            throw EpisodeSyncJournalError.pendingChainBroken
        }
        record.pendingRevisions.removeSubrange(record.pendingRevisions.index(after: chosenIndex)...)
        let revision = try makeRevision(
            content: content,
            parents: [chosen.revisionID],
            branchID: record.branchID,
            createdAt: createdAt
        )
        record.pendingRevisions.append(revision)
        record.localHead = revision
        record.remoteConfirmation = .unconfirmed
        record.localEditIntent = .explicit
        record.reconciliationStatus = .pending
    }

    func markLocalEditPending(record: inout EpisodeSyncJournalRecord) {
        record.remoteConfirmation = .unconfirmed
        record.reconciliationStatus = record.conflict == nil ? .pending : .reviewRequired
        if !authorityVerifiedInProcess || record.conflict != nil {
            record.mode = .forcedFork
        }
    }

    func promoteObservedMutation(record: inout EpisodeSyncJournalRecord) {
        record.localEditIntent = .explicit
        if record.pendingRevisions.isEmpty,
           record.pendingMaterialization == nil {
            record.pendingRevisions = [record.localHead]
        }
    }

    func makeDetachedWorkingRecord(
        content: String,
        createdAt: Date
    ) throws -> EpisodeSyncJournalRecord {
        let branchID = SyncBranchID()
        let revision = try makeRevision(
            content: content,
            parents: [],
            branchID: branchID,
            createdAt: createdAt
        )
        return try EpisodeSyncJournalRecord(
            key: key,
            localWorkingCopyID: localWorkingCopyID,
            replicaID: replicaID,
            branchID: branchID,
            lastKnownRemoteHead: nil,
            localHead: revision,
            pendingRevisions: [revision],
            remoteConfirmation: .unconfirmed,
            localEditIntent: .explicit,
            mode: .forcedFork
        )
    }

    func loadLocalRecordIfNecessary() async throws -> EpisodeSyncJournalRecord? {
        if let record {
            return record
        }
        guard var stored = try await journal.load(for: key) else { return nil }
        if stored.localWorkingCopyID == nil {
            stored.localWorkingCopyID = localWorkingCopyID
            try await journal.save(stored)
        }
        guard stored.localWorkingCopyID == localWorkingCopyID else {
            throw EpisodeSyncJournalError.workingCopyMismatch
        }
        record = stored
        state = stateForRecord(stored)
        return stored
    }

    func appendFirstExplicitEdit(
        content: String,
        createdAt: Date,
        to record: inout EpisodeSyncJournalRecord
    ) throws {
        let observed = record.localHead
        let revision = try makeRevision(
            content: content,
            parents: [observed.revisionID],
            branchID: record.branchID,
            createdAt: createdAt
        )
        record.localHead = revision
        record.pendingRevisions = observed.revisionID == record.lastKnownRemoteHead?.revisionID
            ? [revision]
            : [observed, revision]
        record.localEditIntent = .explicit
        record.remoteConfirmation = .unconfirmed
        record.reconciliationStatus = .pending
    }

    func appendEditWhileAwaitingMaterialization(
        content: String,
        createdAt: Date,
        to record: inout EpisodeSyncJournalRecord
    ) throws {
        let context = try makeMaterializationEditContext(
            content: content,
            createdAt: createdAt,
            record: record
        )
        switch PortableThreeWayTextMerger.analyze(
            base: context.oldWorking.content,
            local: content,
            remote: context.oldIntegrated.content
        ) {
        case let .merged(integratedContent):
            try applyMaterializationMerge(
                integratedContent,
                context: context,
                createdAt: createdAt,
                record: &record
            )
        case let .conflict(mergeConflict):
            applyMaterializationConflict(
                mergeConflict,
                context: context,
                record: &record
            )
        }
        record.localEditIntent = .explicit
        record.remoteConfirmation = .unconfirmed
    }

    private func makeMaterializationEditContext(
        content: String,
        createdAt: Date,
        record: EpisodeSyncJournalRecord
    ) throws -> MaterializationEditContext {
        guard let materialization = record.pendingMaterialization,
              materialization.workingRevisionID == record.localHead.revisionID else {
            throw EpisodeSyncJournalError.materializationMismatch
        }
        let oldWorking = record.localHead
        let oldIntegrated = materialization.integratedRevision
        let sealedIDs = Set(record.sealedPublish?.revisionIDs ?? [])
        let workingIsUnsealed = record.pendingRevisions.contains {
            $0.revisionID == oldWorking.revisionID && !sealedIDs.contains($0.revisionID)
        }
        let integrationIsUnsealed = record.pendingRevisions.contains {
            $0.revisionID == oldIntegrated.revisionID && !sealedIDs.contains($0.revisionID)
        }
        let canReplaceUnsealedPair = workingIsUnsealed && integrationIsUnsealed
        let workingParents = canReplaceUnsealedPair
            ? oldWorking.parentRevisionIDs
            : [oldWorking.revisionID]
        let integrationBaseID = canReplaceUnsealedPair
            ? oldIntegrated.parentRevisionIDs.first { $0 != oldWorking.revisionID }
            ?? oldIntegrated.revisionID
            : oldIntegrated.revisionID
        return try MaterializationEditContext(
            oldWorking: oldWorking,
            oldIntegrated: oldIntegrated,
            newWorking: makeRevision(
                content: content,
                parents: workingParents,
                branchID: record.branchID,
                createdAt: createdAt
            ),
            workingParents: workingParents,
            integrationBaseID: integrationBaseID,
            canReplaceUnsealedPair: canReplaceUnsealedPair
        )
    }

    private func applyMaterializationMerge(
        _ integratedContent: String,
        context: MaterializationEditContext,
        createdAt: Date,
        record: inout EpisodeSyncJournalRecord
    ) throws {
        removeReplacedMaterializationPair(context, record: &record)
        let integrated = try makeRevision(
            content: integratedContent,
            parents: [context.integrationBaseID, context.newWorking.revisionID],
            branchID: record.branchID,
            createdAt: createdAt
        )
        record.localHead = context.newWorking
        record.pendingRevisions.append(contentsOf: [context.newWorking, integrated])
        record.pendingMaterialization = EpisodePendingMaterialization(
            workingRevisionID: context.newWorking.revisionID,
            integratedRevision: integrated
        )
        record.conflict = nil
        record.integrationReviewDraft = nil
        record.reconciliationStatus = .pending
    }

    private func applyMaterializationConflict(
        _ mergeConflict: PortableTextMergeConflict,
        context: MaterializationEditContext,
        record: inout EpisodeSyncJournalRecord
    ) {
        let conflictBase = context.canReplaceUnsealedPair
            ? record.pendingRevisions.first {
                context.workingParents.contains($0.revisionID)
            } ?? context.oldWorking
            : context.oldWorking
        let conflictRemote = context.canReplaceUnsealedPair
            ? record.pendingRevisions.first {
                $0.revisionID == context.integrationBaseID
            } ?? record.lastKnownRemoteHead ?? context.oldIntegrated
            : context.oldIntegrated
        removeReplacedMaterializationPair(context, record: &record)
        record.localHead = context.newWorking
        record.pendingRevisions.append(context.newWorking)
        let conflict = EpisodeConflict(
            base: conflictBase,
            local: context.newWorking,
            remote: conflictRemote
        )
        record.conflict = conflict
        record.integrationReviewDraft = makeReviewDraft(
            for: conflict,
            reason: reviewReason(for: mergeConflict.reason),
            proposedContent: mergeConflict.proposedContent
        )
        record.pendingMaterialization = nil
        record.reconciliationStatus = .reviewRequired
    }

    private func removeReplacedMaterializationPair(
        _ context: MaterializationEditContext,
        record: inout EpisodeSyncJournalRecord
    ) {
        guard context.canReplaceUnsealedPair else { return }
        record.pendingRevisions.removeAll {
            $0.revisionID == context.oldWorking.revisionID
                || $0.revisionID == context.oldIntegrated.revisionID
        }
    }
}

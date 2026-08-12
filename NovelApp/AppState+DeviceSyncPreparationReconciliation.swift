import Foundation
import NovelSync

extension AppState {
    func reconcileDeviceSyncPreparation(_ preparation: DeviceSyncPreparation) async throws -> Bool {
        var recovery = try await preparation.runtime.mergeRecoveryStore.load(
            localWorkingCopyID: preparation.identity.localWorkingCopyID,
            key: preparation.identity.syncKey
        )
        guard deviceSyncContextIsCurrent(preparation.identity) else { return false }
        guard try await reconcilePreparedConflictRecovery(&recovery, preparation: preparation) else {
            return false
        }
        guard deviceSyncContextIsCurrent(preparation.identity) else { return false }
        guard try await removePreparedConflictBridge(recovery, preparation: preparation) else {
            return false
        }
        guard deviceSyncContextIsCurrent(preparation.identity) else { return false }
        guard try await resumePreparedConflictChoice(preparation) else { return false }
        guard deviceSyncContextIsCurrent(preparation.identity) else { return false }
        try await acknowledgePreparedMaterialization(preparation)
        guard deviceSyncContextIsCurrent(preparation.identity) else { return false }
        guard try await reconcilePreparedWorkingCopy(preparation) else { return false }
        guard deviceSyncContextIsCurrent(preparation.identity) else { return false }
        try await observePreparedRemoteIfClean(preparation)
        return deviceSyncContextIsCurrent(preparation.identity)
    }

    private func reconcilePreparedConflictRecovery(
        _ recovery: inout DeviceSyncMergeRecoveryRecord?,
        preparation: DeviceSyncPreparation
    ) async throws -> Bool {
        guard let record = recovery,
              case let .conflicted(_, conflict) = preparation.state else { return true }
        guard mergeRecoveryRecord(record, matches: conflict) else {
            try await preserveSupersededPreparedConflict(record, conflict: conflict, preparation: preparation)
            return false
        }
        pendingDeviceSyncConflictResolution = PendingDeviceSyncConflictResolution(
            key: preparation.identity.syncKey,
            conflict: conflict,
            content: record.content
        )
        if record.purpose == .acceptedResolution {
            if await preparation.client.coordinator.conflictChoiceAwaitingMaterialization == nil {
                _ = try await preparation.client.coordinator.stageConflictResolutionLocalFirst(
                    expectedConflict: conflict,
                    choice: .manual(content: record.content),
                    createdAt: preparation.runtime.now()
                )
                preparation.state = await preparation.client.coordinator.state
            }
            return true
        }
        deviceSyncConflict = conflict
        deviceSyncState = .conflict(conflict)
        return false
    }

    private func preserveSupersededPreparedConflict(
        _ record: DeviceSyncMergeRecoveryRecord,
        conflict: EpisodeConflict,
        preparation: DeviceSyncPreparation
    ) async throws {
        try await preparation.runtime.mergeRecoveryStore.save(
            DeviceSyncMergeRecoveryRecord(
                localWorkingCopyID: preparation.identity.localWorkingCopyID,
                key: preparation.identity.syncKey,
                conflict: conflict,
                content: record.content
            )
        )
        guard deviceSyncContextIsCurrent(preparation.identity) else { return }
        pendingDeviceSyncConflictResolution = PendingDeviceSyncConflictResolution(
            key: preparation.identity.syncKey,
            conflict: conflict,
            content: record.content
        )
        deviceSyncConflict = conflict
        deviceSyncState = .conflict(conflict)
    }

    private func removePreparedConflictBridge(
        _ recovery: DeviceSyncMergeRecoveryRecord?,
        preparation: DeviceSyncPreparation
    ) async throws -> Bool {
        guard let recovery,
              recovery.purpose == .acceptedResolution,
              let staged = await preparation.client.coordinator.conflictChoiceAwaitingMaterialization else {
            return true
        }
        guard deviceSyncContextIsCurrent(preparation.identity) else { return false }
        guard mergeRecoveryRecord(recovery, matches: staged.sourceConflict),
              recovery.contentDigest == staged.chosenRevision.contentDigest,
              recovery.content == staged.chosenRevision.content else {
            deviceSyncConflict = staged.sourceConflict
            deviceSyncState = .conflict(staged.sourceConflict)
            return false
        }
        try await preparation.runtime.mergeRecoveryStore.remove(
            localWorkingCopyID: preparation.identity.localWorkingCopyID,
            key: preparation.identity.syncKey
        )
        guard deviceSyncContextIsCurrent(preparation.identity) else { return false }
        return true
    }

    private func resumePreparedConflictChoice(_ preparation: DeviceSyncPreparation) async throws -> Bool {
        guard !preparation.hasPendingEditIntent,
              let staged = await preparation.client.coordinator.conflictChoiceAwaitingMaterialization else {
            return true
        }
        guard deviceSyncContextIsCurrent(preparation.identity) else { return false }
        pendingDeviceSyncConflictResolution = PendingDeviceSyncConflictResolution(
            key: preparation.identity.syncKey,
            conflict: staged.sourceConflict,
            content: staged.chosenRevision.content
        )
        if preparation.contentDigest == staged.chosenRevision.contentDigest {
            preparation.state = try await preparation.client.coordinator.confirmStagedConflictResolutionMaterialized(
                staged,
                installedContentDigest: staged.chosenRevision.contentDigest
            )
            guard deviceSyncContextIsCurrent(preparation.identity) else { return false }
        } else if await installPreparedConflictChoice(staged, preparation: preparation) == false {
            guard deviceSyncContextIsCurrent(preparation.identity) else { return false }
            deviceSyncConflict = staged.sourceConflict
            deviceSyncState = .conflict(staged.sourceConflict)
            return false
        }
        guard deviceSyncContextIsCurrent(preparation.identity) else { return false }
        deviceSyncConflict = nil
        preparation.resumedConflictChoice = true
        return true
    }

    private func installPreparedConflictChoice(
        _ staged: EpisodeConflictResolutionMaterialization,
        preparation: DeviceSyncPreparation
    ) async -> Bool {
        guard preparation.contentDigest == staged.sourceConflict.local.contentDigest,
              await installResolvedConflictContent(
                  staged.chosenRevision.content,
                  expectedCurrentDigest: preparation.contentDigest,
                  expectedIdentity: preparation.identity
              ), let installed = currentDeviceSyncIdentityAfterSingleInstall(from: preparation.identity) else {
            return false
        }
        preparation.identity = installed
        preparation.content = staged.chosenRevision.content
        preparation.contentDigest = staged.chosenRevision.contentDigest
        do {
            preparation.state = try await preparation.client.coordinator.confirmStagedConflictResolutionMaterialized(
                staged,
                installedContentDigest: staged.chosenRevision.contentDigest
            )
            return deviceSyncContextIsCurrent(preparation.identity)
        } catch {
            return false
        }
    }

    private func acknowledgePreparedMaterialization(_ preparation: DeviceSyncPreparation) async throws {
        guard let context = deviceSyncContext(in: preparation.state),
              let pending = context.pendingMaterialization,
              pending.integratedRevision.contentDigest == preparation.contentDigest else { return }
        preparation.state = try await preparation.client.coordinator.confirmIntegratedContentMaterialized(
            pending,
            installedContentDigest: pending.integratedRevision.contentDigest
        )
    }

    private func reconcilePreparedWorkingCopy(_ preparation: DeviceSyncPreparation) async throws -> Bool {
        guard deviceSyncContextIsCurrent(preparation.identity) else { return false }
        if case .unlinked = preparation.state {
            guard try await establishPreparedWorkingCopy(preparation) else { return false }
            return true
        }
        let packageAhead = deviceSyncContext(in: preparation.state).map {
            $0.localHead.contentDigest != preparation.contentDigest
        } == true
        guard preparation.hasPendingEditIntent || packageAhead else { return true }
        return try await recordPreparedWorkingCopy(preparation)
    }

    private func establishPreparedWorkingCopy(_ preparation: DeviceSyncPreparation) async throws -> Bool {
        guard deviceSyncContextIsCurrent(preparation.identity) else { return false }
        if preparation.hasPendingEditIntent {
            guard try await recordPreparedWorkingCopy(preparation) else { return false }
        } else {
            preparation.state = try await preparation.client.coordinator.observeLocalBase(
                localContent: preparation.content,
                createdAt: preparation.runtime.now()
            )
        }
        guard deviceSyncContextIsCurrent(preparation.identity) else { return false }
        guard preparation.preservedMarkers.isEmpty,
              !preparation.hasPendingEditIntent,
              preparation.client.remoteSynchronizationAllowed else { return true }
        preparation.state = try await preparation.client.coordinator.observeRemoteBase(
            localContent: preparation.content,
            createdAt: preparation.runtime.now()
        )
        guard deviceSyncContextIsCurrent(preparation.identity) else { return false }
        preparation.observedRemote = true
        return true
    }

    private func recordPreparedWorkingCopy(_ preparation: DeviceSyncPreparation) async throws -> Bool {
        guard deviceSyncContextIsCurrent(preparation.identity) else { return false }
        deviceSyncLocalDurabilityState = .pending
        guard await saveCoordinator.saveNow(),
              deviceSyncContextIsCurrent(preparation.identity),
              document.episode(preparation.identity.episodeID)?.episode.content == preparation.content else {
            return false
        }
        let sequence = preparation.exactMarkers.map(\.mutationSequence).max()
        let receipt = try await preparation.client.coordinator.recordLocalEdit(
            preparation.content,
            createdAt: preparation.runtime.now()
        )
        guard deviceSyncContextIsCurrent(preparation.identity) else { return false }
        preparation.state = receipt.state
        await markDeviceSyncLocalEditSavedIfCurrent(
            receipt,
            content: preparation.content,
            expectedIdentity: preparation.identity,
            acknowledgedMutationSequence: sequence
        )
        guard deviceSyncContextIsCurrent(preparation.identity) else { return false }
        preparation.hasPendingEditIntent = deviceSyncLocalDurabilityState != .saved
        return deviceSyncLocalDurabilityState == .saved
    }

    private func observePreparedRemoteIfClean(_ preparation: DeviceSyncPreparation) async throws {
        guard deviceSyncContextIsCurrent(preparation.identity),
              preparation.preservedMarkers.isEmpty,
              !preparation.observedRemote,
              preparation.client.remoteSynchronizationAllowed,
              let context = deviceSyncContext(in: preparation.state),
              !context.hasExplicitLocalChanges,
              context.pendingMaterialization == nil,
              context.reconciliationStatus != .reviewRequired else { return }
        preparation.state = try await preparation.client.coordinator.observeRemoteBase(
            localContent: preparation.content,
            createdAt: preparation.runtime.now()
        )
        guard deviceSyncContextIsCurrent(preparation.identity) else { return }
    }

    func finishDeviceSyncPreparation(_ preparation: DeviceSyncPreparation) async throws {
        guard deviceSyncContextIsCurrent(preparation.identity) else { return }
        applyDeviceSyncState(
            preparation.state,
            client: preparation.client,
            expectedIdentity: preparation.identity
        )
        if !preparation.preservedMarkers.isEmpty || deviceSyncLocalRecoveryReview != nil {
            try await finishAcceptedLocalRecoveryChoice(preparation)
            return
        }
        if preparation.resumedConflictChoice {
            guard preparation.client.remoteSynchronizationAllowed else {
                deviceSyncState = preparation.client.remoteAvailability == .temporarilyOffline
                    ? .offlineLocal
                    : .blocked
                return
            }
            synchronizeResolvedConflictInBackground(
                client: preparation.client,
                identity: preparation.identity,
                runtime: preparation.runtime
            )
            return
        }
        guard preparation.client.remoteSynchronizationAllowed,
              !preparation.hasIncompatibleMarker else {
            if case .conflict = deviceSyncState {
                return
            }
            deviceSyncState = preparation.client.remoteAvailability == .temporarilyOffline
                ? .offlineLocal
                : .blocked
            return
        }
        guard shouldSynchronizeLocalFirst(preparation.state) else { return }
        deviceSyncTransferState = .uploading
        preparation.state = try await preparation.client.coordinator.synchronizeLocalFirst(
            expiresAt: preparation.runtime.leaseExpiration(),
            createdAt: preparation.runtime.now()
        )
        guard deviceSyncContextIsCurrent(preparation.identity) else { return }
        applyDeviceSyncState(
            preparation.state,
            client: preparation.client,
            expectedIdentity: preparation.identity
        )
    }

    private func finishAcceptedLocalRecoveryChoice(
        _ preparation: DeviceSyncPreparation
    ) async throws {
        guard deviceSyncLocalRecoveryChoicePending,
              preparation.client.remoteSynchronizationAllowed else {
            deviceSyncState = .needsReview
            deviceSyncTransferState = .localPending
            return
        }
        let alreadyConfirmed = await completeDeviceSyncLocalRecoveryReviewIfConfirmed(
            state: preparation.state,
            client: preparation.client,
            identity: preparation.identity,
            runtime: preparation.runtime
        )
        guard deviceSyncContextIsCurrent(preparation.identity) else { return }
        if alreadyConfirmed {
            return
        }
        guard shouldSynchronizeLocalFirst(preparation.state) else {
            deviceSyncState = .needsReview
            return
        }
        preparation.state = try await preparation.client.coordinator.synchronizeLocalFirst(
            expiresAt: preparation.runtime.leaseExpiration(),
            createdAt: preparation.runtime.now()
        )
        guard deviceSyncContextIsCurrent(preparation.identity) else { return }
        if case let .conflicted(_, conflict) = preparation.state {
            deviceSyncConflict = conflict
            deviceSyncState = .conflict(conflict)
            return
        }
        if await completeDeviceSyncLocalRecoveryReviewIfConfirmed(
            state: preparation.state,
            client: preparation.client,
            identity: preparation.identity,
            runtime: preparation.runtime
        ) == false {
            guard deviceSyncContextIsCurrent(preparation.identity) else { return }
            deviceSyncState = .needsReview
            deviceSyncTransferState = .localPending
        }
    }

    func applyDeviceSyncPreparationFailure(
        _ preparation: DeviceSyncPreparation,
        offline: Bool
    ) async {
        guard deviceSyncContextIsCurrent(preparation.identity) else { return }
        let state = await preparation.client.coordinator.state
        guard deviceSyncContextIsCurrent(preparation.identity) else { return }
        applyDeviceSyncState(
            state,
            client: preparation.client,
            expectedIdentity: preparation.identity
        )
        guard deviceSyncContextIsCurrent(preparation.identity) else { return }
        deviceSyncState = offline ? .offlineLocal : .blocked
    }
}

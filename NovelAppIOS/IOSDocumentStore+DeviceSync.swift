import EditorKit
import Foundation
import NovelCore
import NovelSync

extension IOSDocumentStore {
    var currentDeviceSyncLookupIdentity: IOSDeviceSyncLookupIdentity? {
        guard startupState == .ready,
              let editingToken = currentEpisodeEditingToken,
              let structureDigest = try? SyncWorkStructureDigest(chapters: document.chapters) else { return nil }
        return IOSDeviceSyncLookupIdentity(
            editingToken: editingToken,
            structureDigest: structureDigest
        )
    }

    func deviceSyncAllowsEditing(for lookup: IOSDeviceSyncLookupIdentity) -> Bool {
        guard !deviceSyncStartupFailedSafely,
              startupState == .ready,
              !deviceSyncLocalRecoveryPending else { return false }
        return currentDeviceSyncLookupIdentity == lookup
    }

    func deviceSyncSelectionDidChange() {
        if usesWholeWorkDeviceSync {
            workDeviceSyncSelectionDidChange()
            return
        }
        deviceSyncDraftTask?.cancel()
        deviceSyncDraftTask = nil
        deviceSyncEditIntentLineage = nil
        deviceSyncLocalRecoveryPending = deviceSyncRuntime != nil
        deviceSyncLocalRecoveryReview = nil
        deviceSyncLocalRecoveryChoicePending = false
        activeDeviceSyncIdentity = nil
        resolvedDeviceSyncLookupIdentity = nil
        pendingDeviceSyncConflictResolution = nil
        deviceSyncConflict = nil
        deviceSyncState = deviceSyncRuntime == nil ? .unconfigured : .syncing
        deviceSyncTransferState = .notApplicable
        deviceSyncLocalDurabilityState = .notApplicable
        if case .candidates = deviceSyncSetupState {
            deviceSyncSetupState = .idle
        }
        if pendingDeviceSyncNewWork?.session != currentDocumentSessionToken {
            pendingDeviceSyncNewWork = nil
        }
    }

    func prepareDeviceSync(for expectedLookup: IOSDeviceSyncLookupIdentity) async {
        if usesWholeWorkDeviceSync {
            await refreshOrPrepareWorkDeviceSync()
            return
        }
        while let inFlight = deviceSyncPreparationTask {
            let observedGeneration = deviceSyncPreparationGeneration
            let observedLookup = deviceSyncPreparationLookup
            let joinsSameSurface = deviceSyncPreparationSurfaceMatches(
                observedLookup,
                expectedLookup
            )
            if observedLookup != expectedLookup, !joinsSameSurface {
                inFlight.cancel()
                deviceSyncPreparationGeneration &+= 1
                deviceSyncPreparationTask = nil
                deviceSyncPreparationLookup = nil
                break
            }
            await inFlight.value
            if deviceSyncPreparationGeneration == observedGeneration {
                deviceSyncPreparationTask = nil
                deviceSyncPreparationLookup = nil
            }
            guard currentDeviceSyncLookupIdentity == expectedLookup else { return }
            if observedLookup == expectedLookup || joinsSameSurface {
                return
            }
        }
        deviceSyncPreparationGeneration &+= 1
        let generation = deviceSyncPreparationGeneration
        let preparation = Task<Void, Never> { @MainActor [weak self] in
            guard let self else { return }
            await prepareDeviceSyncSerially(for: expectedLookup)
        }
        deviceSyncPreparationTask = preparation
        deviceSyncPreparationLookup = expectedLookup
        await preparation.value
        if deviceSyncPreparationGeneration == generation {
            deviceSyncPreparationTask = nil
            deviceSyncPreparationLookup = nil
        }
    }

    func deviceSyncPreparationSurfaceMatches(
        _ observed: IOSDeviceSyncLookupIdentity?,
        _ expected: IOSDeviceSyncLookupIdentity
    ) -> Bool {
        guard let observed else { return false }
        return observed.editingToken.documentSession == expected.editingToken.documentSession
            && observed.editingToken.chapterID == expected.editingToken.chapterID
            && observed.editingToken.episodeID == expected.editingToken.episodeID
            && observed.structureDigest == expected.structureDigest
    }

    func scheduleDeviceSyncForEditedEpisode(
        content: String,
        expectedEditingToken: IOSEpisodeEditingToken,
        baseContentDigest: SyncContentDigest,
        previousContentDigest: SyncContentDigest
    ) {
        guard deviceSyncRuntime != nil,
              let expectedLookup = currentDeviceSyncLookupIdentity,
              expectedLookup.editingToken == expectedEditingToken else { return }
        if usesWholeWorkDeviceSync {
            deviceSyncTransferState = .localPending
            deviceSyncLocalDurabilityState = .pending
            return
        }
        if resolvedDeviceSyncLookupIdentity == expectedLookup,
           deviceSyncState == .unconfigured || deviceSyncState == .episodeNotIncluded {
            deviceSyncTransferState = .notApplicable
            deviceSyncLocalDurabilityState = .notApplicable
            return
        }

        deviceSyncTransferState = .localPending
        deviceSyncLocalDurabilityState = .pending
        enqueueDeviceSyncEditIntent(
            content: content,
            expectedLookup: expectedLookup,
            baseContentDigest: baseContentDigest,
            previousContentDigest: previousContentDigest
        )
        deviceSyncDraftTask?.cancel()
        deviceSyncDraftTask = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(nanoseconds: 2_000_000_000)
            } catch {
                return
            }
            guard !Task.isCancelled else { return }
            await self?.publishDeviceSyncDraft(content: content, expectedEditingToken: expectedEditingToken)
        }
    }

    func applyDeviceSyncState(
        _ state: EpisodeSyncState,
        client: IOSDeviceSyncClient,
        expectedIdentity: IOSDeviceSyncEpisodeIdentity
    ) {
        guard deviceSyncContextIsCurrent(expectedIdentity),
              let runtime = deviceSyncRuntime else { return }
        switch state {
        case .upToDate, .localChanges, .offlineFork, .conflicted:
            applyDeviceSyncLocalFirstState(state, client: client, runtime: runtime)
        default:
            applyDeviceSyncObservationState(state)
        }
        updateDeviceSyncLocalDurability(from: state, expectedIdentity: expectedIdentity)
    }

    private func applyDeviceSyncLocalFirstState(
        _ state: EpisodeSyncState,
        client: IOSDeviceSyncClient,
        runtime: IOSDeviceSyncRuntime
    ) {
        switch state {
        case let .upToDate(context):
            deviceSyncState = ownsDeviceSyncAuthority(context: context, client: client, runtime: runtime)
                ? .writer : .readOnly
            deviceSyncConflict = nil
            deviceSyncTransferState = context.remoteConfirmation == .confirmed ? .upToDate : .notApplicable
        case let .localChanges(context):
            deviceSyncState = ownsDeviceSyncAuthority(context: context, client: client, runtime: runtime)
                ? .writer : .readOnly
            deviceSyncTransferState = .localPending
        case let .offlineFork(context):
            deviceSyncState = deviceSyncOfflinePresentation(context.reconciliationStatus)
            deviceSyncTransferState = .localPending
        case let .conflicted(_, conflict):
            deviceSyncConflict = conflict
            deviceSyncState = .conflict(conflict)
            deviceSyncTransferState = .localPending
        default:
            break
        }
    }

    private func deviceSyncOfflinePresentation(
        _ status: EpisodeRemoteReconciliationStatus
    ) -> IOSDeviceSyncUIState {
        switch status {
        case .offline:
            .offlineLocal
        case .reviewRequired:
            .needsReview
        case .idle, .pending:
            .readOnly
        }
    }

    private func applyDeviceSyncObservationState(_ state: EpisodeSyncState) {
        switch state {
        case .readOnly, .authorityLost, .restoredUnverified, .remoteUpdateAvailable:
            deviceSyncState = .readOnly
            deviceSyncTransferState = .notApplicable
        case .synchronizing, .authorityGrantedAwaitingInstall:
            deviceSyncState = .syncing
        case .unlinked:
            deviceSyncState = .blocked
        default:
            break
        }
    }

    private func updateDeviceSyncLocalDurability(
        from state: EpisodeSyncState,
        expectedIdentity: IOSDeviceSyncEpisodeIdentity
    ) {
        guard deviceSyncContextIsCurrent(expectedIdentity) else { return }
        guard deviceSyncLocalDurabilityState != .pending,
              deviceSyncLocalDurabilityState != .failed else { return }
        guard let context = deviceSyncContext(in: state) else {
            if case .unlinked = state {
                deviceSyncLocalDurabilityState = .notApplicable
            }
            return
        }
        guard saveState == .saved,
              let content = document.episode(expectedIdentity.editingToken.episodeID)?.episode.content,
              SyncContentDigest(content: content) == context.localHead.contentDigest else { return }
        deviceSyncLocalDurabilityState = .saved
    }

    func deviceSyncContext(in state: EpisodeSyncState) -> EpisodeSyncContext? {
        switch state {
        case .unlinked:
            nil
        case let .restoredUnverified(context),
             let .upToDate(context),
             let .localChanges(context),
             let .offlineFork(context),
             let .synchronizing(context),
             let .authorityGrantedAwaitingInstall(context, _),
             let .readOnly(context, _),
             let .authorityLost(context, _),
             let .remoteUpdateAvailable(context, _),
             let .conflicted(context, _):
            context
        }
    }

    func shouldSynchronizeLocalFirst(_ state: EpisodeSyncState) -> Bool {
        guard let context = deviceSyncContext(in: state),
              context.hasExplicitLocalChanges,
              context.pendingMaterialization == nil else { return false }
        if case .conflicted = state {
            return false
        }
        if case .synchronizing = state {
            return false
        }
        return true
    }

    func ownsDeviceSyncAuthority(
        in state: EpisodeSyncState,
        client: IOSDeviceSyncClient,
        runtime: IOSDeviceSyncRuntime
    ) -> Bool {
        let context: EpisodeSyncContext? = switch state {
        case let .upToDate(value), let .localChanges(value), let .offlineFork(value), let .conflicted(value, _):
            value
        default:
            nil
        }
        guard let context else { return false }
        return ownsDeviceSyncAuthority(context: context, client: client, runtime: runtime)
    }

    func ownsDeviceSyncAuthority(
        context: EpisodeSyncContext,
        client: IOSDeviceSyncClient,
        runtime: IOSDeviceSyncRuntime
    ) -> Bool {
        context.lease?.authority.holderReplicaID == runtime.replicaID &&
            context.lease?.authority.holderSessionID == client.sessionID
    }

    func deviceSyncClient(for identity: IOSDeviceSyncEpisodeIdentity) -> IOSDeviceSyncClient? {
        deviceSyncClients[
            IOSDeviceSyncClientKey(
                localWorkingCopyID: identity.localWorkingCopyID,
                syncKey: identity.syncKey
            )
        ]
    }

    func deviceSyncContextIsCurrent(_ identity: IOSDeviceSyncEpisodeIdentity) -> Bool {
        activeDeviceSyncIdentity == identity &&
            currentDeviceSyncLookupIdentity == IOSDeviceSyncLookupIdentity(
                editingToken: identity.editingToken,
                structureDigest: identity.structureDigest
            )
    }
}

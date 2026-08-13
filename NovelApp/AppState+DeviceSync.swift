import AppKit
import EditorKit
import Foundation
import NovelCore
import NovelSync

extension AppState {
    var currentDeviceSyncLookupIdentity: DeviceSyncLookupIdentity? {
        guard startupState.isReady,
              let selectedChapterID,
              let selectedEpisodeID,
              let structureDigest = try? SyncWorkStructureDigest(chapters: document.chapters) else { return nil }
        return DeviceSyncLookupIdentity(
            documentSession: documentSessionToken,
            chapterID: selectedChapterID,
            episodeID: selectedEpisodeID,
            editorContentGeneration: editorContentGeneration,
            structureDigest: structureDigest
        )
    }

    func deviceSyncAllowsEditing(for lookup: DeviceSyncLookupIdentity) -> Bool {
        guard !deviceSyncStartupFailedSafely,
              startupState.isReady else { return false }
        if !usesNoteSyncRuntime, deviceSyncLocalRecoveryPending {
            return false
        }
        return currentDeviceSyncLookupIdentity == lookup
    }

    func deviceSyncSelectionDidChange() {
        deviceSyncDraftTask?.cancel()
        deviceSyncDraftTask = nil
        deviceSyncEditIntentLineage = nil
        if usesWholeWorkSyncRuntime {
            activeDeviceSyncIdentity = nil
            pendingDeviceSyncConflictResolution = nil
            deviceSyncConflict = nil
            if activeWorkSyncIdentity?.documentSession == documentSessionToken,
               workSyncClient != nil || noteSyncClient != nil {
                deviceSyncLocalRecoveryPending = false
                resolvedDeviceSyncLookupIdentity = currentDeviceSyncLookupIdentity
            } else {
                clearWorkSyncClient()
                // Note sync must not inherit D-061's CloudKit-blocking recovery overlay.
                deviceSyncLocalRecoveryPending = !usesNoteSyncRuntime
                resolvedDeviceSyncLookupIdentity = nil
                deviceSyncState = .syncing
                deviceSyncTransferState = .notApplicable
                deviceSyncLocalDurabilityState = .notApplicable
            }
            return
        }
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
        if pendingDeviceSyncNewWork?.session != documentSessionToken {
            pendingDeviceSyncNewWork = nil
        }
    }

    func prepareDeviceSync(for expectedLookup: DeviceSyncLookupIdentity) async {
        while let inFlight = deviceSyncPreparationTask {
            let observedGeneration = deviceSyncPreparationGeneration
            let observedLookup = deviceSyncPreparationLookup
            let joinsSameSurface = deviceSyncPreparationSurfaceMatches(
                observedLookup,
                expectedLookup
            )
            if observedLookup != expectedLookup, !joinsSameSurface {
                // A remote lookup for the previous surface must not keep the
                // newly selected Editor behind the local crash-recovery gate.
                // The old task keeps its own lifetime and is fenced by lookup
                // identity when it eventually completes.
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
        _ observed: DeviceSyncLookupIdentity?,
        _ expected: DeviceSyncLookupIdentity
    ) -> Bool {
        guard let observed else { return false }
        return observed.documentSession == expected.documentSession
            && observed.chapterID == expected.chapterID
            && observed.episodeID == expected.episodeID
            && observed.structureDigest == expected.structureDigest
    }

    func scheduleDeviceSyncForEditedEpisode(
        content: String,
        expectedLookup: DeviceSyncLookupIdentity,
        baseContentDigest: SyncContentDigest,
        previousContentDigest: SyncContentDigest
    ) {
        guard deviceSyncRuntime != nil,
              currentDeviceSyncLookupIdentity == expectedLookup else { return }
        if hasCurrentWorkSyncClient {
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
            await self?.publishDeviceSyncDraft(content: content, expectedLookup: expectedLookup)
        }
    }

    func applyDeviceSyncState(
        _ state: EpisodeSyncState,
        client: DeviceSyncClient,
        expectedIdentity: DeviceSyncEpisodeIdentity
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
        client: DeviceSyncClient,
        runtime: DeviceSyncRuntime
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
    ) -> DeviceSyncUIState {
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
        expectedIdentity: DeviceSyncEpisodeIdentity
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
              let content = document.episode(expectedIdentity.episodeID)?.episode.content,
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
        client: DeviceSyncClient,
        runtime: DeviceSyncRuntime
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
        client: DeviceSyncClient,
        runtime: DeviceSyncRuntime
    ) -> Bool {
        context.lease?.authority.holderReplicaID == runtime.replicaID &&
            context.lease?.authority.holderSessionID == client.sessionID
    }

    func deviceSyncClient(for identity: DeviceSyncEpisodeIdentity) -> DeviceSyncClient? {
        deviceSyncClients[
            DeviceSyncClientKey(
                localWorkingCopyID: identity.localWorkingCopyID,
                syncKey: identity.syncKey
            )
        ]
    }

    func deviceSyncContextIsCurrent(_ identity: DeviceSyncEpisodeIdentity) -> Bool {
        activeDeviceSyncIdentity == identity &&
            currentDeviceSyncLookupIdentity == DeviceSyncLookupIdentity(
                documentSession: identity.documentSession,
                chapterID: identity.chapterID,
                episodeID: identity.episodeID,
                editorContentGeneration: identity.editorContentGeneration,
                structureDigest: identity.structureDigest
            )
    }
}

import Foundation
import NovelCore
import NovelSync

@MainActor
final class DeviceSyncPreparation {
    let expectedLookup: DeviceSyncLookupIdentity
    let runtime: DeviceSyncRuntime
    let binding: SyncWorkingCopyBinding
    let client: DeviceSyncClient
    let isNewClient: Bool
    var identity: DeviceSyncEpisodeIdentity
    var state: EpisodeSyncState = .unlinked
    var content: String
    var contentDigest: SyncContentDigest
    var storedMarkers: [DeviceSyncEditIntentMarker] = []
    var eligibleMarkers: [DeviceSyncEditIntentMarker] = []
    var preservedMarkers: [DeviceSyncEditIntentMarker] = []
    var packageCheckpointIntent: DeviceSyncPackageCheckpoint?
    var hasIncompatibleMarker = false
    var hasPendingEditIntent = false
    var resumedConflictChoice = false
    var observedRemote = false

    init(
        expectedLookup: DeviceSyncLookupIdentity,
        runtime: DeviceSyncRuntime,
        binding: SyncWorkingCopyBinding,
        client: DeviceSyncClient,
        isNewClient: Bool,
        identity: DeviceSyncEpisodeIdentity,
        content: String
    ) {
        self.expectedLookup = expectedLookup
        self.runtime = runtime
        self.binding = binding
        self.client = client
        self.isNewClient = isNewClient
        self.identity = identity
        self.content = content
        contentDigest = SyncContentDigest(content: content)
    }

    var exactMarkers: [DeviceSyncEditIntentMarker] {
        eligibleMarkers.filter { $0.contentDigest == contentDigest && $0.content == content }
    }
}

extension AppState {
    func prepareDeviceSyncSerially(for expectedLookup: DeviceSyncLookupIdentity) async {
        if await prepareWorkSyncIfAvailable(for: expectedLookup) {
            return
        }
        guard shouldBeginDeviceSyncPreparation(expectedLookup) else { return }
        guard let preparation = await makeDeviceSyncPreparation(expectedLookup) else { return }
        do {
            guard try await restoreDeviceSyncPreparation(preparation) else { return }
            guard deviceSyncContextIsCurrent(preparation.identity) else { return }
            guard try await reconcileDeviceSyncEditIntents(preparation) else { return }
            guard deviceSyncContextIsCurrent(preparation.identity) else { return }
            guard try await reconcileDeviceSyncPreparation(preparation) else { return }
            guard deviceSyncContextIsCurrent(preparation.identity) else { return }
            try await finishDeviceSyncPreparation(preparation)
        } catch EpisodeSyncTransportError.unavailable {
            await applyDeviceSyncPreparationFailure(preparation, offline: true)
        } catch {
            await applyDeviceSyncPreparationFailure(preparation, offline: false)
        }
    }

    private func shouldBeginDeviceSyncPreparation(_ expectedLookup: DeviceSyncLookupIdentity) -> Bool {
        guard currentDeviceSyncLookupIdentity == expectedLookup else { return false }
        startDeviceSyncSignalObservationIfNeeded()
        let alreadyResolved = resolvedDeviceSyncLookupIdentity == expectedLookup
            && activeDeviceSyncIdentity?.documentSession == expectedLookup.documentSession
        if alreadyResolved || deviceSyncRuntime == nil {
            if deviceSyncRuntime == nil {
                deviceSyncLocalRecoveryPending = false
                resolvedDeviceSyncLookupIdentity = expectedLookup
                deviceSyncState = .unconfigured
                deviceSyncSetupState = .idle
            }
            return false
        }
        deviceSyncState = .syncing
        resolvedDeviceSyncLookupIdentity = nil
        activeDeviceSyncIdentity = nil
        return true
    }

    private func makeDeviceSyncPreparation(
        _ expectedLookup: DeviceSyncLookupIdentity
    ) async -> DeviceSyncPreparation? {
        guard let runtime = deviceSyncRuntime else { return nil }
        guard await completeDeviceSyncLocalRecoveryPreflight(
            for: expectedLookup,
            runtime: runtime
        ) else { return nil }
        guard let preparedLookup = currentDeviceSyncLookupIdentity,
              preparedLookup.documentSession == expectedLookup.documentSession,
              preparedLookup.chapterID == expectedLookup.chapterID,
              preparedLookup.episodeID == expectedLookup.episodeID,
              preparedLookup.structureDigest == expectedLookup.structureDigest else { return nil }
        if deviceSyncPreparationLookup == expectedLookup {
            // Local crash recovery may install the WAL body and advance the
            // Editor generation. Keep the existing single-flight slot attached
            // to that same surface so SwiftUI's new task joins this preparation
            // instead of starting a second binding/journal pass.
            deviceSyncPreparationLookup = preparedLookup
        }
        let result = await resolveDeviceSyncBinding(preparedLookup, runtime: runtime)
        guard !Task.isCancelled,
              currentDeviceSyncLookupIdentity == preparedLookup else { return nil }
        guard case let .success(resolution) = result else {
            resolvedDeviceSyncLookupIdentity = preparedLookup
            deviceSyncState = .blocked
            deviceSyncSetupState = .unavailable(message: "iCloud本文同期の接続を確認できません")
            return nil
        }
        guard let resolution else {
            resolvedDeviceSyncLookupIdentity = preparedLookup
            deviceSyncState = .unconfigured
            deviceSyncSetupState = .idle
            await finalizePackageOnlyDeviceSync(expectedLookup: preparedLookup, runtime: runtime)
            preserveLocalRecoveryReviewStatusIfNeeded(expectedLookup: preparedLookup)
            return nil
        }
        guard await validateDeviceSyncResolution(
            resolution,
            expectedLookup: preparedLookup,
            runtime: runtime
        ) else { return nil }
        return createDeviceSyncPreparation(
            expectedLookup: preparedLookup,
            resolution: resolution,
            runtime: runtime
        )
    }

    private func resolveDeviceSyncBinding(
        _ expectedLookup: DeviceSyncLookupIdentity,
        runtime: DeviceSyncRuntime
    ) async -> Result<DeviceSyncBindingResolution?, Error> {
        do {
            return try await .success(runtime.binding(
                expectedLookup.documentSession,
                expectedLookup.structureDigest
            ))
        } catch {
            return .failure(error)
        }
    }

    private func validateDeviceSyncResolution(
        _ resolution: DeviceSyncBindingResolution,
        expectedLookup: DeviceSyncLookupIdentity,
        runtime: DeviceSyncRuntime
    ) async -> Bool {
        deviceSyncSetupState = .configured
        if let descriptor = resolution.descriptor,
           descriptor.workID != resolution.binding.workID || descriptor.sourceDocumentID != document.id {
            resolvedDeviceSyncLookupIdentity = expectedLookup
            deviceSyncState = .blocked
            deviceSyncSetupState = .unavailable(message: "作品の同期情報が一致しません")
            return false
        }
        guard resolution.allowedEpisodeIDs.contains(expectedLookup.episodeID) else {
            resolvedDeviceSyncLookupIdentity = expectedLookup
            activeDeviceSyncIdentity = nil
            deviceSyncState = .episodeNotIncluded
            await finalizePackageOnlyDeviceSync(expectedLookup: expectedLookup, runtime: runtime)
            preserveLocalRecoveryReviewStatusIfNeeded(expectedLookup: expectedLookup)
            return false
        }
        return true
    }

    private func preserveLocalRecoveryReviewStatusIfNeeded(
        expectedLookup: DeviceSyncLookupIdentity
    ) {
        guard currentDeviceSyncLookupIdentity == expectedLookup,
              deviceSyncLocalRecoveryReview != nil else { return }
        deviceSyncState = .needsReview
        deviceSyncTransferState = .localPending
    }

    private func createDeviceSyncPreparation(
        expectedLookup: DeviceSyncLookupIdentity,
        resolution: DeviceSyncBindingResolution,
        runtime: DeviceSyncRuntime
    ) -> DeviceSyncPreparation {
        let key = EpisodeSyncKey(workID: resolution.binding.workID, episodeID: expectedLookup.episodeID)
        let clientResult = deviceSyncClient(
            key: key,
            resolution: resolution,
            runtime: runtime
        )
        let identity = DeviceSyncEpisodeIdentity(
            documentSession: expectedLookup.documentSession,
            chapterID: expectedLookup.chapterID,
            episodeID: expectedLookup.episodeID,
            editorContentGeneration: expectedLookup.editorContentGeneration,
            structureDigest: expectedLookup.structureDigest,
            localWorkingCopyID: resolution.binding.localWorkingCopyID,
            syncKey: key
        )
        activeDeviceSyncIdentity = identity
        resolvedDeviceSyncLookupIdentity = expectedLookup
        return DeviceSyncPreparation(
            expectedLookup: expectedLookup,
            runtime: runtime,
            binding: resolution.binding,
            client: clientResult.client,
            isNewClient: clientResult.isNew,
            identity: identity,
            content: document.episode(identity.episodeID)?.episode.content ?? ""
        )
    }

    private func deviceSyncClient(
        key: EpisodeSyncKey,
        resolution: DeviceSyncBindingResolution,
        runtime: DeviceSyncRuntime
    ) -> (client: DeviceSyncClient, isNew: Bool) {
        let clientKey = DeviceSyncClientKey(
            localWorkingCopyID: resolution.binding.localWorkingCopyID,
            syncKey: key
        )
        if let existing = deviceSyncClients[clientKey] {
            let client = DeviceSyncClient(
                coordinator: existing.coordinator,
                sessionID: existing.sessionID,
                remoteAvailability: resolution.remoteAvailability
            )
            deviceSyncClients[clientKey] = client
            return (client, false)
        }
        let sessionID = SyncEditSessionID()
        let client = DeviceSyncClient(
            coordinator: EpisodeSyncCoordinator(
                key: key,
                localWorkingCopyID: resolution.binding.localWorkingCopyID,
                replicaID: runtime.replicaID,
                sessionID: sessionID,
                transport: runtime.transport,
                journal: resolution.journal
            ),
            sessionID: sessionID,
            remoteAvailability: resolution.remoteAvailability
        )
        deviceSyncClients[clientKey] = client
        return (client, true)
    }

    private func restoreDeviceSyncPreparation(_ preparation: DeviceSyncPreparation) async throws -> Bool {
        preparation.state = preparation.isNewClient
            ? try await preparation.client.coordinator.restore()
            : await preparation.client.coordinator.state
        guard deviceSyncContextIsCurrent(preparation.identity) else { return false }
        guard await flushPendingDeviceSyncEditIntents(),
              deviceSyncContextIsCurrent(preparation.identity) else { return false }
        preparation.content = document.episode(preparation.identity.episodeID)?.episode.content ?? ""
        preparation.contentDigest = SyncContentDigest(content: preparation.content)
        try await loadDeviceSyncPreparationMarkers(preparation)
        guard deviceSyncContextIsCurrent(preparation.identity) else { return false }
        guard let marker = newestDeviceSyncPreparationMarker(preparation) else { return true }
        guard let recovery = await recoverDeviceSyncPreparationContent(
            from: marker,
            replacing: preparation.content,
            identity: preparation.identity,
            client: preparation.client
        ) else {
            guard deviceSyncContextIsCurrent(preparation.identity) else { return false }
            deviceSyncLocalDurabilityState = .failed
            return false
        }
        preparation.content = recovery.content
        preparation.contentDigest = SyncContentDigest(content: recovery.content)
        preparation.identity = recovery.identity
        preparation.state = recovery.state
        try await loadDeviceSyncPreparationMarkers(preparation)
        guard deviceSyncContextIsCurrent(preparation.identity) else { return false }
        return true
    }

    private func loadDeviceSyncPreparationMarkers(_ preparation: DeviceSyncPreparation) async throws {
        let identity = preparation.identity
        var persistence = try await preparation.runtime.editIntentStore.loadPersistenceSnapshot(
            workingCopyIdentity: deviceSyncWorkingCopyIdentity(for: identity.documentSession),
            documentID: identity.documentSession.documentID,
            episodeID: identity.episodeID
        )
        guard deviceSyncContextIsCurrent(identity) else { return }
        if let marker = persistence.marker,
           marker.replicaID != preparation.runtime.replicaID
           || marker.localWorkingCopyID.map({ $0 != identity.localWorkingCopyID }) == true
           || marker.workID.map({ $0 != identity.syncKey.workID }) == true {
            try await preparation.runtime.editIntentStore.preserveForReview(marker)
            guard deviceSyncContextIsCurrent(identity) else { return }
            persistence = try await preparation.runtime.editIntentStore.loadPersistenceSnapshot(
                workingCopyIdentity: deviceSyncWorkingCopyIdentity(for: identity.documentSession),
                documentID: identity.documentSession.documentID,
                episodeID: identity.episodeID
            )
            guard deviceSyncContextIsCurrent(identity) else { return }
        }
        updateDeviceSyncLocalRecoveryChoice(from: persistence)
        preparation.packageCheckpointIntent = persistence.committedPackage.flatMap { checkpoint in
            checkpoint.containsLocalEditIntent && checkpoint.contentDigest == preparation.contentDigest
                ? checkpoint
                : nil
        }
        preparation.storedMarkers = persistence.marker.map { [$0] } ?? []
        preparation.preservedMarkers = persistence.preservedMarkers
        if !persistence.preservedMarkers.isEmpty {
            deviceSyncLocalRecoveryReview = DeviceSyncLocalRecoveryReview(
                packageContent: preparation.content,
                preservedMarkers: persistence.preservedMarkers
            )
            deviceSyncState = .needsReview
        }
        if let maximumSequence = preparation.storedMarkers.map(\.mutationSequence).max() {
            deviceSyncEditIntentGeneration = max(deviceSyncEditIntentGeneration, maximumSequence)
        }
        if let newest = preparation.storedMarkers.max(by: {
            ($0.createdAt, $0.mutationSequence) < ($1.createdAt, $1.mutationSequence)
        }) {
            deviceSyncEditIntentLineage = (
                newest.workingCopyIdentity,
                newest.episodeID,
                newest.contentDigest,
                newest.acceptedPriorPackageDigests ?? newest.baseContentDigest.map { [$0] } ?? []
            )
        }
        preparation.eligibleMarkers = preparation.storedMarkers.filter {
            $0.replicaID == preparation.runtime.replicaID
                && ($0.localWorkingCopyID == nil || $0.localWorkingCopyID == identity.localWorkingCopyID)
                && ($0.workID == nil || $0.workID == identity.syncKey.workID)
        }
        preparation.hasIncompatibleMarker = preparation.eligibleMarkers.count != preparation.storedMarkers.count
        if preparation.hasIncompatibleMarker {
            deviceSyncLocalDurabilityState = .failed
        } else if !preparation.preservedMarkers.isEmpty,
                  deviceSyncLocalDurabilityState == .failed {
            deviceSyncLocalDurabilityState = saveState == .saved ? .saved : .pending
        }
    }

    private func newestDeviceSyncPreparationMarker(
        _ preparation: DeviceSyncPreparation
    ) -> DeviceSyncEditIntentMarker? {
        guard let marker = preparation.eligibleMarkers.max(by: {
            ($0.createdAt, $0.mutationSequence) < ($1.createdAt, $1.mutationSequence)
        }), marker.contentDigest != preparation.contentDigest else { return nil }
        if case .unlinked = preparation.state {
            let accepted = marker.acceptedPriorPackageDigests
                ?? marker.baseContentDigest.map { [$0] }
                ?? []
            guard accepted.contains(preparation.contentDigest) else {
                deviceSyncLocalDurabilityState = .failed
                return nil
            }
            return marker
        }
        let packageIsAcceptedPredecessor = marker.acceptedPriorPackageDigests?
            .contains(preparation.contentDigest)
            ?? marker.baseContentDigest.map { $0 == preparation.contentDigest }
            ?? true
        guard let context = deviceSyncContext(in: preparation.state),
              context.localHead.contentDigest == preparation.contentDigest,
              packageIsAcceptedPredecessor else {
            deviceSyncLocalDurabilityState = .failed
            return nil
        }
        return marker
    }

    private func reconcileDeviceSyncEditIntents(_ preparation: DeviceSyncPreparation) async throws -> Bool {
        preparation.hasPendingEditIntent = deviceSyncLocalDurabilityState == .pending
        let exactMarkers = preparation.exactMarkers
        if exactMarkers.isEmpty {
            if !preparation.storedMarkers.isEmpty {
                deviceSyncLocalDurabilityState = .failed
                deviceSyncState = .needsReview
                return false
            }
            if preparation.packageCheckpointIntent != nil,
               deviceSyncContext(in: preparation.state)?.hasExplicitLocalChanges != true {
                preparation.hasPendingEditIntent = true
                deviceSyncLocalDurabilityState = .pending
            }
        } else if deviceSyncContext(in: preparation.state)?.hasExplicitLocalChanges == true {
            guard try await acknowledgePreparedDeviceSyncMarkers(exactMarkers, preparation: preparation) else {
                return false
            }
            guard deviceSyncContextIsCurrent(preparation.identity) else { return false }
        } else {
            preparation.hasPendingEditIntent = true
            deviceSyncLocalDurabilityState = .pending
        }
        if preparation.exactMarkers.isEmpty,
           let checkpoint = preparation.packageCheckpointIntent,
           deviceSyncContext(in: preparation.state)?.hasExplicitLocalChanges == true {
            guard try await acknowledgeDeviceSyncPackageIntent(
                contentDigest: checkpoint.contentDigest,
                identity: preparation.identity,
                throughSequence: checkpoint.sequence,
                runtime: preparation.runtime
            ) else { return false }
            guard deviceSyncContextIsCurrent(preparation.identity) else { return false }
            preparation.packageCheckpointIntent = nil
            preparation.hasPendingEditIntent = false
            deviceSyncLocalDurabilityState = saveState == .saved ? .saved : .pending
        }
        return try await promotePreparedDeviceSyncEditIntentIfNeeded(preparation)
    }

    private func acknowledgePreparedDeviceSyncMarkers(
        _ markers: [DeviceSyncEditIntentMarker],
        preparation: DeviceSyncPreparation
    ) async throws -> Bool {
        for marker in markers where marker.resolvesPreservedSequences == nil {
            try await preparation.runtime.editIntentStore.remove(marker)
            guard deviceSyncContextIsCurrent(preparation.identity) else { return false }
        }
        guard deviceSyncContextIsCurrent(preparation.identity),
              document.episode(preparation.identity.episodeID)?.episode.content == preparation.content else {
            deviceSyncLocalDurabilityState = .pending
            return false
        }
        try await loadDeviceSyncPreparationMarkers(preparation)
        guard deviceSyncContextIsCurrent(preparation.identity) else { return false }
        guard preparation.storedMarkers.allSatisfy({
            $0.resolvesPreservedSequences?.isEmpty == false
        }) else {
            deviceSyncLocalDurabilityState = .pending
            return false
        }
        deviceSyncLocalDurabilityState = saveState == .saved ? .saved : .pending
        preparation.hasPendingEditIntent = false
        return deviceSyncLocalDurabilityState == .saved
    }

    private func promotePreparedDeviceSyncEditIntentIfNeeded(
        _ preparation: DeviceSyncPreparation
    ) async throws -> Bool {
        guard preparation.hasPendingEditIntent,
              !preparation.exactMarkers.isEmpty || preparation.packageCheckpointIntent != nil,
              deviceSyncContext(in: preparation.state)?.hasExplicitLocalChanges != true else { return true }
        guard await saveCoordinator.saveNow(),
              deviceSyncContextIsCurrent(preparation.identity),
              document.episode(preparation.identity.episodeID)?.episode.content == preparation.content else {
            deviceSyncLocalDurabilityState = .pending
            return false
        }
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
            acknowledgedMutationSequence: preparation.exactMarkers.map(\.mutationSequence).max()
                ?? preparation.packageCheckpointIntent?.sequence
        )
        guard deviceSyncContextIsCurrent(preparation.identity) else { return false }
        guard deviceSyncLocalDurabilityState == .saved else { return false }
        preparation.hasPendingEditIntent = false
        try await loadDeviceSyncPreparationMarkers(preparation)
        return deviceSyncContextIsCurrent(preparation.identity)
    }
}

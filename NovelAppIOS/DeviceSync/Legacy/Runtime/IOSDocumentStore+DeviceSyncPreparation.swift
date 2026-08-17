import Foundation
import NovelCore
import NovelSync

@MainActor
final class IOSDeviceSyncPreparation {
    let expectedLookup: IOSDeviceSyncLookupIdentity
    let runtime: IOSDeviceSyncRuntime
    let binding: SyncWorkingCopyBinding
    let client: IOSDeviceSyncClient
    let isNewClient: Bool
    var identity: IOSDeviceSyncEpisodeIdentity
    var state: EpisodeSyncState = .unlinked
    var content: String
    var contentDigest: SyncContentDigest
    var storedMarkers: [IOSDeviceSyncEditIntentMarker] = []
    var eligibleMarkers: [IOSDeviceSyncEditIntentMarker] = []
    var preservedMarkers: [IOSDeviceSyncEditIntentMarker] = []
    var packageCheckpointIntent: IOSDeviceSyncPackageCheckpoint?
    var hasIncompatibleMarker = false
    var hasPendingEditIntent = false
    var resumedConflictChoice = false
    var observedRemote = false

    init(
        expectedLookup: IOSDeviceSyncLookupIdentity,
        runtime: IOSDeviceSyncRuntime,
        binding: SyncWorkingCopyBinding,
        client: IOSDeviceSyncClient,
        isNewClient: Bool,
        identity: IOSDeviceSyncEpisodeIdentity,
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

    var exactMarkers: [IOSDeviceSyncEditIntentMarker] {
        eligibleMarkers.filter { $0.contentDigest == contentDigest && $0.content == content }
    }
}

extension IOSDocumentStore {
    func prepareDeviceSyncSerially(for expectedLookup: IOSDeviceSyncLookupIdentity) async {
        guard shouldBeginIOSDeviceSyncPreparation(expectedLookup) else { return }
        guard let preparation = await makeIOSDeviceSyncPreparation(expectedLookup) else { return }
        do {
            guard try await restoreIOSDeviceSyncPreparation(preparation) else { return }
            guard deviceSyncContextIsCurrent(preparation.identity) else { return }
            guard try await reconcileDeviceSyncEditIntents(preparation) else { return }
            guard deviceSyncContextIsCurrent(preparation.identity) else { return }
            guard try await reconcileIOSDeviceSyncPreparation(preparation) else { return }
            guard deviceSyncContextIsCurrent(preparation.identity) else { return }
            try await finishIOSDeviceSyncPreparation(preparation)
        } catch EpisodeSyncTransportError.unavailable {
            await applyIOSDeviceSyncPreparationFailure(preparation, offline: true)
        } catch {
            await applyIOSDeviceSyncPreparationFailure(preparation, offline: false)
        }
    }

    private func shouldBeginIOSDeviceSyncPreparation(_ expectedLookup: IOSDeviceSyncLookupIdentity) -> Bool {
        guard currentDeviceSyncLookupIdentity == expectedLookup else { return false }
        startDeviceSyncSignalObservationIfNeeded()
        let alreadyResolved = resolvedDeviceSyncLookupIdentity == expectedLookup
            && activeDeviceSyncIdentity?.editingToken.documentSession == expectedLookup.editingToken.documentSession
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

    private func makeIOSDeviceSyncPreparation(
        _ expectedLookup: IOSDeviceSyncLookupIdentity
    ) async -> IOSDeviceSyncPreparation? {
        guard let runtime = deviceSyncRuntime else { return nil }
        guard await completeDeviceSyncLocalRecoveryPreflight(
            for: expectedLookup,
            runtime: runtime
        ) else { return nil }
        guard let preparedLookup = currentDeviceSyncLookupIdentity,
              preparedLookup.editingToken.documentSession == expectedLookup.editingToken.documentSession,
              preparedLookup.editingToken.chapterID == expectedLookup.editingToken.chapterID,
              preparedLookup.editingToken.episodeID == expectedLookup.editingToken.episodeID,
              preparedLookup.structureDigest == expectedLookup.structureDigest else { return nil }
        if deviceSyncPreparationLookup == expectedLookup {
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
        return createIOSDeviceSyncPreparation(
            expectedLookup: preparedLookup,
            resolution: resolution,
            runtime: runtime
        )
    }

    private func resolveDeviceSyncBinding(
        _ expectedLookup: IOSDeviceSyncLookupIdentity,
        runtime: IOSDeviceSyncRuntime
    ) async -> Result<IOSDeviceSyncBindingResolution?, Error> {
        do {
            return try await .success(runtime.binding(
                expectedLookup.editingToken.documentSession.workingCopyID,
                document.id,
                expectedLookup.structureDigest
            ))
        } catch {
            return .failure(error)
        }
    }

    private func validateDeviceSyncResolution(
        _ resolution: IOSDeviceSyncBindingResolution,
        expectedLookup: IOSDeviceSyncLookupIdentity,
        runtime: IOSDeviceSyncRuntime
    ) async -> Bool {
        deviceSyncSetupState = .configured
        if let descriptor = resolution.descriptor,
           descriptor.workID != resolution.binding.workID || descriptor.sourceDocumentID != document.id {
            resolvedDeviceSyncLookupIdentity = expectedLookup
            deviceSyncState = .blocked
            deviceSyncSetupState = .unavailable(message: "作品の同期情報が一致しません")
            return false
        }
        guard resolution.allowedEpisodeIDs.contains(expectedLookup.editingToken.episodeID) else {
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
        expectedLookup: IOSDeviceSyncLookupIdentity
    ) {
        guard currentDeviceSyncLookupIdentity == expectedLookup,
              deviceSyncLocalRecoveryReview != nil else { return }
        deviceSyncState = .needsReview
        deviceSyncTransferState = .localPending
    }

    private func createIOSDeviceSyncPreparation(
        expectedLookup: IOSDeviceSyncLookupIdentity,
        resolution: IOSDeviceSyncBindingResolution,
        runtime: IOSDeviceSyncRuntime
    ) -> IOSDeviceSyncPreparation {
        let key = EpisodeSyncKey(
            workID: resolution.binding.workID,
            episodeID: expectedLookup.editingToken.episodeID
        )
        let clientResult = deviceSyncClient(
            key: key,
            resolution: resolution,
            runtime: runtime
        )
        let identity = IOSDeviceSyncEpisodeIdentity(
            editingToken: expectedLookup.editingToken,
            structureDigest: expectedLookup.structureDigest,
            localWorkingCopyID: resolution.binding.localWorkingCopyID,
            syncKey: key
        )
        activeDeviceSyncIdentity = identity
        resolvedDeviceSyncLookupIdentity = expectedLookup
        return IOSDeviceSyncPreparation(
            expectedLookup: expectedLookup,
            runtime: runtime,
            binding: resolution.binding,
            client: clientResult.client,
            isNewClient: clientResult.isNew,
            identity: identity,
            content: document.episode(identity.editingToken.episodeID)?.episode.content ?? ""
        )
    }

    private func deviceSyncClient(
        key: EpisodeSyncKey,
        resolution: IOSDeviceSyncBindingResolution,
        runtime: IOSDeviceSyncRuntime
    ) -> (client: IOSDeviceSyncClient, isNew: Bool) {
        let clientKey = IOSDeviceSyncClientKey(
            localWorkingCopyID: resolution.binding.localWorkingCopyID,
            syncKey: key
        )
        if let existing = deviceSyncClients[clientKey] {
            let client = IOSDeviceSyncClient(
                coordinator: existing.coordinator,
                sessionID: existing.sessionID,
                remoteAvailability: resolution.remoteAvailability
            )
            deviceSyncClients[clientKey] = client
            return (client, false)
        }
        let sessionID = SyncEditSessionID()
        let client = IOSDeviceSyncClient(
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

    private func restoreIOSDeviceSyncPreparation(_ preparation: IOSDeviceSyncPreparation) async throws -> Bool {
        preparation.state = preparation.isNewClient
            ? try await preparation.client.coordinator.restore()
            : await preparation.client.coordinator.state
        guard deviceSyncContextIsCurrent(preparation.identity) else { return false }
        guard await flushPendingDeviceSyncEditIntents(),
              deviceSyncContextIsCurrent(preparation.identity) else { return false }
        preparation.content = document.episode(preparation.identity.editingToken.episodeID)?.episode.content ?? ""
        preparation.contentDigest = SyncContentDigest(content: preparation.content)
        try await loadIOSDeviceSyncPreparationMarkers(preparation)
        guard deviceSyncContextIsCurrent(preparation.identity) else { return false }
        guard let marker = newestIOSDeviceSyncPreparationMarker(preparation) else { return true }
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
        try await loadIOSDeviceSyncPreparationMarkers(preparation)
        return deviceSyncContextIsCurrent(preparation.identity)
    }

    private func loadIOSDeviceSyncPreparationMarkers(_ preparation: IOSDeviceSyncPreparation) async throws {
        let identity = preparation.identity
        var persistence = try await preparation.runtime.editIntentStore.loadPersistenceSnapshot(
            workingCopyIdentity: deviceSyncWorkingCopyIdentity(
                for: identity.editingToken.documentSession.workingCopyID
            ),
            documentID: document.id,
            episodeID: identity.editingToken.episodeID
        )
        guard deviceSyncContextIsCurrent(identity) else { return }
        if let marker = persistence.marker,
           marker.replicaID != preparation.runtime.replicaID
           || marker.localWorkingCopyID.map({ $0 != identity.localWorkingCopyID }) == true
           || marker.workID.map({ $0 != identity.syncKey.workID }) == true {
            try await preparation.runtime.editIntentStore.preserveForReview(marker)
            guard deviceSyncContextIsCurrent(identity) else { return }
            persistence = try await preparation.runtime.editIntentStore.loadPersistenceSnapshot(
                workingCopyIdentity: deviceSyncWorkingCopyIdentity(
                    for: identity.editingToken.documentSession.workingCopyID
                ),
                documentID: document.id,
                episodeID: identity.editingToken.episodeID
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
            deviceSyncLocalRecoveryReview = IOSDeviceSyncLocalRecoveryReview(
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

    private func newestIOSDeviceSyncPreparationMarker(
        _ preparation: IOSDeviceSyncPreparation
    ) -> IOSDeviceSyncEditIntentMarker? {
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

    private func reconcileDeviceSyncEditIntents(_ preparation: IOSDeviceSyncPreparation) async throws -> Bool {
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
        _ markers: [IOSDeviceSyncEditIntentMarker],
        preparation: IOSDeviceSyncPreparation
    ) async throws -> Bool {
        for marker in markers where marker.resolvesPreservedSequences == nil {
            try await preparation.runtime.editIntentStore.remove(marker)
            guard deviceSyncContextIsCurrent(preparation.identity) else { return false }
        }
        let episodeID = preparation.identity.editingToken.episodeID
        guard deviceSyncContextIsCurrent(preparation.identity),
              document.episode(episodeID)?.episode.content == preparation.content else {
            deviceSyncLocalDurabilityState = .pending
            return false
        }
        try await loadIOSDeviceSyncPreparationMarkers(preparation)
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
        _ preparation: IOSDeviceSyncPreparation
    ) async throws -> Bool {
        guard preparation.hasPendingEditIntent,
              !preparation.exactMarkers.isEmpty || preparation.packageCheckpointIntent != nil,
              deviceSyncContext(in: preparation.state)?.hasExplicitLocalChanges != true else { return true }
        let episodeID = preparation.identity.editingToken.episodeID
        guard await saveCoordinator.saveNow(),
              deviceSyncContextIsCurrent(preparation.identity),
              document.episode(episodeID)?.episode.content == preparation.content else {
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
        try await loadIOSDeviceSyncPreparationMarkers(preparation)
        return deviceSyncContextIsCurrent(preparation.identity)
    }
}

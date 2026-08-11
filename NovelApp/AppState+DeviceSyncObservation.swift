import Foundation
import NovelSync

extension AppState {
    func refreshSelectedEpisodeDeviceSync() async {
        guard deviceSyncState != .syncing,
              deviceSyncState != .forcing,
              let expectedLookup = currentDeviceSyncLookupIdentity else { return }
        while let inFlight = deviceSyncPreparationTask {
            let observedGeneration = deviceSyncPreparationGeneration
            let observedLookup = deviceSyncPreparationLookup
            await inFlight.value
            if deviceSyncPreparationGeneration == observedGeneration {
                deviceSyncPreparationTask = nil
                deviceSyncPreparationLookup = nil
            }
            guard currentDeviceSyncLookupIdentity == expectedLookup else { return }
            if observedLookup == expectedLookup {
                return
            }
        }
        deviceSyncPreparationGeneration &+= 1
        let generation = deviceSyncPreparationGeneration
        let refresh = Task<Void, Never> { @MainActor [weak self] in
            guard let self else { return }
            await refreshSelectedEpisodeDeviceSyncSerially(for: expectedLookup)
        }
        deviceSyncPreparationTask = refresh
        deviceSyncPreparationLookup = expectedLookup
        await refresh.value
        if deviceSyncPreparationGeneration == generation {
            deviceSyncPreparationTask = nil
            deviceSyncPreparationLookup = nil
        }
    }

    private func refreshSelectedEpisodeDeviceSyncSerially(
        for expectedLookup: DeviceSyncLookupIdentity
    ) async {
        guard currentDeviceSyncLookupIdentity == expectedLookup,
              deviceSyncState != .syncing,
              deviceSyncState != .forcing else { return }
        guard deviceSyncLocalRecoveryReview == nil || deviceSyncLocalRecoveryChoicePending else {
            deviceSyncState = .needsReview
            deviceSyncTransferState = .localPending
            return
        }
        guard let runtime = deviceSyncRuntime,
              let identity = activeDeviceSyncIdentity,
              deviceSyncContextIsCurrent(identity),
              let cachedClient = deviceSyncClient(for: identity) else { return }
        do {
            guard let client = try await revalidatedDeviceSyncClient(
                cachedClient,
                identity: identity,
                expectedLookup: expectedLookup,
                runtime: runtime
            ) else { return }
            var state = await client.coordinator.state
            guard deviceSyncContextIsCurrent(identity) else { return }
            if deviceSyncLocalRecoveryReview != nil {
                await refreshAcceptedLocalRecoveryChoice(
                    state: state,
                    client: client,
                    identity: identity,
                    runtime: runtime
                )
                return
            }
            guard client.remoteSynchronizationAllowed else {
                applyDeviceSyncState(state, client: client, expectedIdentity: identity)
                if case .conflict = deviceSyncState {
                    return
                }
                deviceSyncState = client.remoteAvailability == .temporarilyOffline
                    ? .offlineLocal
                    : .blocked
                return
            }
            state = try await observeRemoteDuringRefreshIfNeeded(
                state,
                identity: identity,
                client: client,
                runtime: runtime
            )
            guard deviceSyncContextIsCurrent(identity) else { return }
            applyDeviceSyncState(state, client: client, expectedIdentity: identity)
            guard shouldSynchronizeLocalFirst(state) else { return }
            deviceSyncTransferState = .uploading
            state = try await client.coordinator.synchronizeLocalFirst(
                expiresAt: runtime.leaseExpiration(),
                createdAt: runtime.now()
            )
            guard deviceSyncContextIsCurrent(identity) else { return }
            applyDeviceSyncState(state, client: client, expectedIdentity: identity)
        } catch EpisodeSyncTransportError.unavailable {
            await applyDeviceSyncRefreshFailure(cachedClient, identity: identity, offline: true)
        } catch {
            await applyDeviceSyncRefreshFailure(cachedClient, identity: identity, offline: false)
        }
    }

    private func refreshAcceptedLocalRecoveryChoice(
        state _: EpisodeSyncState,
        client: DeviceSyncClient,
        identity: DeviceSyncEpisodeIdentity,
        runtime: DeviceSyncRuntime
    ) async {
        guard deviceSyncLocalRecoveryChoicePending,
              client.remoteSynchronizationAllowed else {
            deviceSyncState = .needsReview
            deviceSyncTransferState = .localPending
            return
        }
        do {
            let state = try await client.coordinator.synchronizeLocalFirst(
                expiresAt: runtime.leaseExpiration(),
                createdAt: runtime.now()
            )
            guard deviceSyncContextIsCurrent(identity) else { return }
            if case let .conflicted(_, conflict) = state {
                deviceSyncConflict = conflict
                deviceSyncState = .conflict(conflict)
                return
            }
            if await completeDeviceSyncLocalRecoveryReviewIfConfirmed(
                state: state,
                client: client,
                identity: identity,
                runtime: runtime
            ) == false {
                guard deviceSyncContextIsCurrent(identity) else { return }
                deviceSyncState = .needsReview
                deviceSyncTransferState = .localPending
            }
        } catch {
            guard deviceSyncContextIsCurrent(identity) else { return }
            deviceSyncState = .needsReview
            deviceSyncTransferState = .localPending
        }
    }

    private func revalidatedDeviceSyncClient(
        _ cached: DeviceSyncClient,
        identity: DeviceSyncEpisodeIdentity,
        expectedLookup: DeviceSyncLookupIdentity,
        runtime: DeviceSyncRuntime
    ) async throws -> DeviceSyncClient? {
        let resolution = try await runtime.binding(
            expectedLookup.documentSession,
            expectedLookup.structureDigest
        )
        guard deviceSyncContextIsCurrent(identity) else { return nil }
        let permitsRemote = resolution.map {
            $0.binding.localWorkingCopyID == identity.localWorkingCopyID
                && $0.binding.workID == identity.syncKey.workID
                && $0.allowedEpisodeIDs.contains(identity.episodeID)
                && $0.descriptor?.workID == identity.syncKey.workID
                && $0.descriptor?.sourceDocumentID == document.id
        } == true
        let availability: DeviceSyncRemoteAvailability = if permitsRemote {
            .available
        } else if let resolution,
                  resolution.binding.localWorkingCopyID == identity.localWorkingCopyID,
                  resolution.binding.workID == identity.syncKey.workID,
                  resolution.allowedEpisodeIDs.contains(identity.episodeID) {
            resolution.remoteAvailability
        } else {
            .configurationBlocked
        }
        let refreshed = DeviceSyncClient(
            coordinator: cached.coordinator,
            sessionID: cached.sessionID,
            remoteAvailability: availability
        )
        deviceSyncClients[
            DeviceSyncClientKey(
                localWorkingCopyID: identity.localWorkingCopyID,
                syncKey: identity.syncKey
            )
        ] = refreshed
        return refreshed
    }

    private func observeRemoteDuringRefreshIfNeeded(
        _ state: EpisodeSyncState,
        identity: DeviceSyncEpisodeIdentity,
        client: DeviceSyncClient,
        runtime: DeviceSyncRuntime
    ) async throws -> EpisodeSyncState {
        guard deviceSyncLocalRecoveryReview == nil else { return state }
        let shouldObserve: Bool = if case .unlinked = state {
            true
        } else if let context = deviceSyncContext(in: state) {
            !context.hasExplicitLocalChanges
                && context.pendingMaterialization == nil
                && context.reconciliationStatus != .reviewRequired
        } else {
            false
        }
        guard shouldObserve else { return state }
        return try await client.coordinator.observeRemoteBase(
            localContent: document.episode(identity.episodeID)?.episode.content ?? "",
            createdAt: runtime.now()
        )
    }

    private func applyDeviceSyncRefreshFailure(
        _ client: DeviceSyncClient,
        identity: DeviceSyncEpisodeIdentity,
        offline: Bool
    ) async {
        guard deviceSyncContextIsCurrent(identity) else { return }
        let state = await client.coordinator.state
        guard deviceSyncContextIsCurrent(identity) else { return }
        applyDeviceSyncState(
            state,
            client: client,
            expectedIdentity: identity
        )
        guard deviceSyncContextIsCurrent(identity) else { return }
        deviceSyncState = offline ? .offlineLocal : .blocked
    }

    /// CloudKit/accountの起動完了signalは、binding解決前にも届く。
    /// 既存clientはexact fenceを再照合し、未解決の話はbindingからやり直す。
    func refreshOrPrepareSelectedEpisodeDeviceSync() async {
        let expectedLookup = currentDeviceSyncLookupIdentity
        if let inFlight = deviceSyncPreparationTask {
            let generation = deviceSyncPreparationGeneration
            await inFlight.value
            if deviceSyncPreparationGeneration == generation {
                deviceSyncPreparationTask = nil
                deviceSyncPreparationLookup = nil
            }
        }
        guard currentDeviceSyncLookupIdentity == expectedLookup else { return }
        if activeDeviceSyncIdentity != nil {
            await refreshSelectedEpisodeDeviceSync()
        } else if let lookup = expectedLookup {
            await prepareDeviceSync(for: lookup)
        }
    }

    func startDeviceSyncSignalObservationIfNeeded() {
        guard deviceSyncSignalTask == nil,
              let signals = deviceSyncRuntime?.remoteChangeSignals else { return }
        deviceSyncSignalTask = Task { @MainActor [weak self] in
            for await _ in signals {
                guard !Task.isCancelled else { return }
                await self?.refreshOrPrepareSelectedEpisodeDeviceSync()
            }
        }
    }
}

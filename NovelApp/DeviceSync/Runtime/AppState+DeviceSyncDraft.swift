import Foundation
import NovelCore
import NovelSync

private struct DeviceSyncRecordedDraft {
    let receipt: EpisodeLocalEditReceipt
    let mutationSequence: UInt64?
}

extension AppState {
    func publishDeviceSyncDraft(
        content: String,
        expectedLookup: DeviceSyncLookupIdentity
    ) async {
        guard deviceSyncRuntime != nil,
              currentDeviceSyncLookupIdentity == expectedLookup else { return }
        if resolvedDeviceSyncLookupIdentity != expectedLookup || activeDeviceSyncIdentity == nil {
            await prepareDeviceSync(for: expectedLookup)
        }
        guard !Task.isCancelled,
              let runtime = deviceSyncRuntime,
              let identity = activeDeviceSyncIdentity,
              identity.documentSession == expectedLookup.documentSession,
              identity.episodeID == expectedLookup.episodeID,
              identity.editorContentGeneration == expectedLookup.editorContentGeneration,
              let client = deviceSyncClient(for: identity) else { return }
        guard let recorded = await recordDeviceSyncDraftLocally(
            content,
            expectedLookup: expectedLookup,
            identity: identity,
            client: client,
            runtime: runtime
        ) else {
            guard currentDeviceSyncLookupIdentity == expectedLookup else { return }
            if deviceSyncLocalDurabilityState != .failed {
                deviceSyncLocalDurabilityState = .pending
            }
            return
        }
        await markDeviceSyncLocalEditSavedIfCurrent(
            recorded.receipt,
            content: content,
            expectedIdentity: identity,
            acknowledgedMutationSequence: recorded.mutationSequence
        )
        applyDeviceSyncState(recorded.receipt.state, client: client, expectedIdentity: identity)
        guard !Task.isCancelled else { return }
        await synchronizeRecordedDeviceSyncDraft(client: client, identity: identity, runtime: runtime)
    }

    private func recordDeviceSyncDraftLocally(
        _ content: String,
        expectedLookup: DeviceSyncLookupIdentity,
        identity: DeviceSyncEpisodeIdentity,
        client: DeviceSyncClient,
        runtime: DeviceSyncRuntime
    ) async -> DeviceSyncRecordedDraft? {
        await documentOperationGate.perform { [weak self] in
            guard let self,
                  deviceSyncContextIsCurrent(identity),
                  document.episode(identity.episodeID)?.episode.content == content else { return nil }
            do {
                let sequence = await prepareDeviceSyncDraftIntent(
                    content: content,
                    expectedLookup: expectedLookup,
                    identity: identity,
                    runtime: runtime
                )
                guard deviceSyncContextIsCurrent(identity) else { return nil }
                saveCoordinator.markDirty()
                guard await saveCoordinator.saveNow(),
                      deviceSyncContextIsCurrent(identity) else { return nil }
                guard let sequence else {
                    deviceSyncLocalDurabilityState = .failed
                    return nil
                }
                let receipt = try await client.coordinator.recordLocalEdit(content, createdAt: runtime.now())
                guard deviceSyncContextIsCurrent(identity) else { return nil }
                return DeviceSyncRecordedDraft(receipt: receipt, mutationSequence: sequence)
            } catch {
                guard deviceSyncContextIsCurrent(identity) else { return nil }
                deviceSyncLocalDurabilityState = .failed
                return nil
            }
        }
    }

    private func prepareDeviceSyncDraftIntent(
        content: String,
        expectedLookup: DeviceSyncLookupIdentity,
        identity: DeviceSyncEpisodeIdentity,
        runtime: DeviceSyncRuntime
    ) async -> UInt64? {
        guard await flushPendingDeviceSyncEditIntents(),
              deviceSyncContextIsCurrent(identity) else { return nil }
        let expectedResolutionSequences = deviceSyncLocalRecoveryChoicePending
            ? deviceSyncLocalRecoveryReview?.preservedMarkers.map(\.mutationSequence)
            : nil
        if let sequence = await persistedDeviceSyncDraftIntentSequence(
            content: content,
            expectedResolutionSequences: expectedResolutionSequences,
            identity: identity,
            runtime: runtime
        ) {
            deviceSyncLocalDurabilityState = .pending
            return sequence
        }
        guard deviceSyncContextIsCurrent(identity) else { return nil }
        registerDeviceSyncContentMutation(
            content,
            episodeID: identity.episodeID,
            containsLocalEditIntent: true,
            forcesNewSequence: true
        )
        enqueueDeviceSyncEditIntent(
            content: content,
            expectedLookup: expectedLookup,
            resolvesPreservedSequences: expectedResolutionSequences
        )
        guard await flushPendingDeviceSyncEditIntents(),
              deviceSyncContextIsCurrent(identity) else { return nil }
        return await persistedDeviceSyncDraftIntentSequence(
            content: content,
            expectedResolutionSequences: expectedResolutionSequences,
            identity: identity,
            runtime: runtime
        )
    }

    private func persistedDeviceSyncDraftIntentSequence(
        content: String,
        expectedResolutionSequences: [UInt64]?,
        identity: DeviceSyncEpisodeIdentity,
        runtime: DeviceSyncRuntime
    ) async -> UInt64? {
        do {
            let snapshot = try await runtime.editIntentStore.loadPersistenceSnapshot(
                workingCopyIdentity: deviceSyncWorkingCopyIdentity(for: identity.documentSession),
                documentID: identity.documentSession.documentID,
                episodeID: identity.episodeID
            )
            guard deviceSyncContextIsCurrent(identity),
                  let marker = snapshot.marker,
                  marker.replicaID == runtime.replicaID,
                  marker.localWorkingCopyID == nil || marker.localWorkingCopyID == identity.localWorkingCopyID,
                  marker.workID == nil || marker.workID == identity.syncKey.workID,
                  marker.contentDigest == SyncContentDigest(content: content),
                  marker.content == content,
                  marker.resolvesPreservedSequences == expectedResolutionSequences else { return nil }
            return marker.mutationSequence
        } catch {
            guard deviceSyncContextIsCurrent(identity) else { return nil }
            deviceSyncLocalDurabilityState = .failed
            return nil
        }
    }

    private func synchronizeRecordedDeviceSyncDraft(
        client: DeviceSyncClient,
        identity: DeviceSyncEpisodeIdentity,
        runtime: DeviceSyncRuntime
    ) async {
        guard deviceSyncContextIsCurrent(identity) else { return }
        guard deviceSyncLocalRecoveryReview == nil || deviceSyncLocalRecoveryChoicePending else {
            deviceSyncTransferState = .localPending
            deviceSyncState = .needsReview
            return
        }
        guard client.remoteSynchronizationAllowed else {
            applyDeviceSyncDraftRemoteBlock(client: client)
            return
        }
        deviceSyncTransferState = .uploading
        do {
            let state = try await client.coordinator.synchronizeLocalFirst(
                expiresAt: runtime.leaseExpiration(),
                createdAt: runtime.now()
            )
            guard deviceSyncContextIsCurrent(identity) else {
                await applySettledDeviceSyncDraftToCompatibleSurface(
                    client: client,
                    completedIdentity: identity
                )
                return
            }
            if case let .conflicted(_, conflict) = state {
                deviceSyncConflict = conflict
                deviceSyncState = .conflict(conflict)
                return
            }
            if deviceSyncLocalRecoveryReview != nil {
                guard await completeDeviceSyncLocalRecoveryReviewIfConfirmed(
                    state: state,
                    client: client,
                    identity: identity,
                    runtime: runtime
                ) else {
                    guard deviceSyncContextIsCurrent(identity) else { return }
                    deviceSyncTransferState = .localPending
                    deviceSyncState = .needsReview
                    return
                }
                return
            }
            applyDeviceSyncState(state, client: client, expectedIdentity: identity)
        } catch EpisodeSyncTransportError.unavailable {
            await applyUnavailableDeviceSyncDraft(client: client, identity: identity)
        } catch {
            await applyFailedDeviceSyncDraft(client: client, identity: identity)
        }
    }

    /// A publish may finish after the user leaves and reopens the same episode.
    /// Never apply the old Editor generation directly. If the current surface is
    /// the same working copy and the now-confirmed journal head still exactly
    /// matches its durable package, only converge the current status UI.
    private func applySettledDeviceSyncDraftToCompatibleSurface(
        client: DeviceSyncClient,
        completedIdentity: DeviceSyncEpisodeIdentity
    ) async {
        let observedPreparationGeneration = deviceSyncPreparationGeneration
        if let currentLookup = currentDeviceSyncLookupIdentity,
           deviceSyncPreparationSurfaceMatches(deviceSyncPreparationLookup, currentLookup),
           let inFlightPreparation = deviceSyncPreparationTask {
            await inFlightPreparation.value
        }
        let latest = await client.coordinator.state
        guard deviceSyncPreparationGeneration == observedPreparationGeneration,
              deviceSyncState == .syncing || deviceSyncState == .readOnly,
              deviceSyncLocalRecoveryReview == nil,
              deviceSyncConflict == nil,
              case let .upToDate(context) = latest,
              let currentIdentity = activeDeviceSyncIdentity,
              deviceSyncContextIsCurrent(currentIdentity),
              currentIdentity.documentSession == completedIdentity.documentSession,
              currentIdentity.chapterID == completedIdentity.chapterID,
              currentIdentity.episodeID == completedIdentity.episodeID,
              currentIdentity.structureDigest == completedIdentity.structureDigest,
              currentIdentity.localWorkingCopyID == completedIdentity.localWorkingCopyID,
              currentIdentity.syncKey == completedIdentity.syncKey,
              let currentClient = deviceSyncClient(for: currentIdentity),
              currentClient.sessionID == client.sessionID,
              currentClient.coordinator === client.coordinator,
              currentClient.remoteSynchronizationAllowed,
              let currentContent = document.episode(currentIdentity.episodeID)?.episode.content,
              context.localHead.content == currentContent,
              deviceSyncDurablePackageDigest(
                  for: currentIdentity.episodeID,
                  fallbackContent: currentContent
              ) == context.localHead.contentDigest else { return }
        applyDeviceSyncState(latest, client: currentClient, expectedIdentity: currentIdentity)
    }

    private func applyDeviceSyncDraftRemoteBlock(client: DeviceSyncClient) {
        deviceSyncTransferState = .localPending
        if case .conflict = deviceSyncState {
            return
        }
        deviceSyncState = client.remoteAvailability == .temporarilyOffline
            ? .offlineLocal
            : .blocked
    }

    private func applyUnavailableDeviceSyncDraft(
        client: DeviceSyncClient,
        identity: DeviceSyncEpisodeIdentity
    ) async {
        guard deviceSyncContextIsCurrent(identity) else { return }
        let state = await client.coordinator.state
        guard deviceSyncContextIsCurrent(identity) else { return }
        applyDeviceSyncState(state, client: client, expectedIdentity: identity)
        guard deviceSyncContextIsCurrent(identity) else { return }
        deviceSyncState = .offlineLocal
    }

    private func applyFailedDeviceSyncDraft(
        client: DeviceSyncClient,
        identity: DeviceSyncEpisodeIdentity
    ) async {
        guard deviceSyncContextIsCurrent(identity) else { return }
        let state = await client.coordinator.state
        guard deviceSyncContextIsCurrent(identity) else { return }
        applyDeviceSyncState(state, client: client, expectedIdentity: identity)
        guard deviceSyncContextIsCurrent(identity) else { return }
        if case .conflict = deviceSyncState {
            return
        }
        deviceSyncState = .blocked
    }
}

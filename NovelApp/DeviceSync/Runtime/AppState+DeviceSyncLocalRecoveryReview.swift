import Foundation
import NovelSync

extension AppState {
    func resolveDeviceSyncLocalRecovery(
        using choice: DeviceSyncLocalRecoveryChoice,
        expectedReview: DeviceSyncLocalRecoveryReview
    ) async {
        guard let runtime = deviceSyncRuntime,
              !deviceSyncLocalRecoveryPending,
              let expectedLookup = currentDeviceSyncLookupIdentity,
              deviceSyncLocalRecoveryReview == expectedReview else { return }
        let localResult = await persistDeviceSyncLocalRecoveryChoice(
            choice,
            expectedReview: expectedReview,
            expectedLookup: expectedLookup,
            runtime: runtime
        )
        guard currentDeviceSyncLookupIdentity == expectedLookup,
              deviceSyncLocalRecoveryReview == expectedReview else { return }
        guard let localResult else {
            deviceSyncState = .needsReview
            return
        }
        deviceSyncState = .needsReview
        deviceSyncTransferState = .localPending
        guard let client = localResult.client,
              let identity = localResult.identity else { return }
        Task { @MainActor [weak self] in
            await self?.publishChosenLocalRecoveryContent(
                localResult.content,
                expectedReview: expectedReview,
                client: client,
                identity: identity,
                runtime: runtime
            )
        }
    }

    private func persistDeviceSyncLocalRecoveryChoice(
        _ choice: DeviceSyncLocalRecoveryChoice,
        expectedReview: DeviceSyncLocalRecoveryReview,
        expectedLookup: DeviceSyncLookupIdentity,
        runtime: DeviceSyncRuntime
    ) async -> DeviceSyncLocalReviewPublish? {
        await documentOperationGate.perform { [weak self] in
            guard let self,
                  currentDeviceSyncLookupIdentity == expectedLookup,
                  deviceSyncLocalRecoveryReview == expectedReview,
                  beginDocumentTransition() else { return nil as DeviceSyncLocalReviewPublish? }
            defer { endDocumentTransition() }
            guard let current = committedLocalRecoveryContent(expectedLookup: expectedLookup) else {
                return nil
            }
            let chosen = choice.content(current: current, review: expectedReview)
            guard installChosenLocalRecoveryContent(
                chosen,
                replacing: current,
                expectedLookup: expectedLookup
            ), let updatedLookup = currentDeviceSyncLookupIdentity else { return nil }
            enqueueDeviceSyncEditIntent(
                content: chosen,
                expectedLookup: updatedLookup,
                resolvesPreservedSequences: expectedReview.preservedMarkers.map(\.mutationSequence)
            )
            let intentSaved = await flushPendingDeviceSyncEditIntents()
            guard currentDeviceSyncLookupIdentity == updatedLookup,
                  deviceSyncLocalRecoveryReview == expectedReview else { return nil }
            saveCoordinator.markDirty()
            guard await saveCoordinator.saveNow(), intentSaved else {
                guard currentDeviceSyncLookupIdentity == updatedLookup,
                      deviceSyncLocalRecoveryReview == expectedReview else { return nil }
                deviceSyncLocalDurabilityState = .failed
                return nil
            }
            guard currentDeviceSyncLookupIdentity == updatedLookup,
                  deviceSyncLocalRecoveryReview == expectedReview else { return nil }
            guard let publish = await journalChosenLocalRecoveryContent(
                chosen,
                expectedLookup: updatedLookup,
                runtime: runtime
            ) else { return nil }
            return publish
        }
    }

    private func committedLocalRecoveryContent(
        expectedLookup: DeviceSyncLookupIdentity
    ) -> String? {
        let committed: String
        switch captureCommittedTextForDeviceSync() {
        case let .captured(content):
            committed = content
        case .notActive:
            guard let content = document.episode(expectedLookup.episodeID)?.episode.content else {
                return nil
            }
            committed = content
        case .compositionInProgress:
            return nil
        }
        guard currentDeviceSyncLookupIdentity == expectedLookup,
              document.episode(expectedLookup.episodeID)?.episode.content == committed else {
            return nil
        }
        return committed
    }

    private func installChosenLocalRecoveryContent(
        _ chosen: String,
        replacing current: String,
        expectedLookup: DeviceSyncLookupIdentity
    ) -> Bool {
        guard currentDeviceSyncLookupIdentity == expectedLookup,
              let location = document.episode(expectedLookup.episodeID),
              location.episode.content == current else { return false }
        if chosen != current {
            let previousIdentity = activeDeviceSyncIdentity
            installDeviceSyncEpisodeContent(
                chosen,
                chapterID: location.chapterID,
                episodeID: expectedLookup.episodeID,
                advancesEditorGeneration: true
            )
            if let previousIdentity {
                updateDeviceSyncIdentityAfterRemoteInstall(previousIdentity)
            }
        }
        registerDeviceSyncContentMutation(
            chosen,
            episodeID: expectedLookup.episodeID,
            containsLocalEditIntent: true,
            forcesNewSequence: true
        )
        return document.episode(expectedLookup.episodeID)?.episode.content == chosen
    }

    private func journalChosenLocalRecoveryContent(
        _ content: String,
        expectedLookup: DeviceSyncLookupIdentity,
        runtime: DeviceSyncRuntime
    ) async -> DeviceSyncLocalReviewPublish? {
        guard currentDeviceSyncLookupIdentity == expectedLookup,
              let identity = activeDeviceSyncIdentity,
              deviceSyncContextIsCurrent(identity),
              let client = deviceSyncClient(for: identity) else {
            if currentDeviceSyncLookupIdentity == expectedLookup {
                deviceSyncLocalDurabilityState = .pending
            }
            return DeviceSyncLocalReviewPublish(content: content, client: nil, identity: nil)
        }
        do {
            let sequence = await latestExactDeviceSyncEditIntentSequence(
                content: content,
                identity: identity
            )
            guard deviceSyncContextIsCurrent(identity) else { return nil }
            let receipt = try await client.coordinator.recordLocalEdit(
                content,
                createdAt: runtime.now()
            )
            guard deviceSyncContextIsCurrent(identity) else { return nil }
            await markDeviceSyncLocalEditSavedIfCurrent(
                receipt,
                content: content,
                expectedIdentity: identity,
                acknowledgedMutationSequence: sequence
            )
            guard deviceSyncContextIsCurrent(identity) else { return nil }
            guard deviceSyncLocalDurabilityState == .saved else { return nil }
            applyDeviceSyncState(receipt.state, client: client, expectedIdentity: identity)
            return DeviceSyncLocalReviewPublish(content: content, client: client, identity: identity)
        } catch {
            guard deviceSyncContextIsCurrent(identity) else { return nil }
            deviceSyncLocalDurabilityState = .failed
            return nil
        }
    }

    private func publishChosenLocalRecoveryContent(
        _: String,
        expectedReview: DeviceSyncLocalRecoveryReview,
        client: DeviceSyncClient,
        identity: DeviceSyncEpisodeIdentity,
        runtime: DeviceSyncRuntime
    ) async {
        guard deviceSyncLocalRecoveryReview == expectedReview,
              deviceSyncContextIsCurrent(identity) else { return }
        guard client.remoteSynchronizationAllowed else {
            deviceSyncState = .needsReview
            return
        }
        do {
            let state = try await client.coordinator.synchronizeLocalFirst(
                expiresAt: runtime.leaseExpiration(),
                createdAt: runtime.now()
            )
            guard deviceSyncLocalRecoveryReview == expectedReview,
                  deviceSyncContextIsCurrent(identity) else { return }
            if case let .conflicted(_, conflict) = state {
                deviceSyncConflict = conflict
                deviceSyncState = .conflict(conflict)
                return
            }
            guard await completeDeviceSyncLocalRecoveryReviewIfConfirmed(
                state: state,
                client: client,
                identity: identity,
                runtime: runtime
            ) else {
                guard deviceSyncLocalRecoveryReview == expectedReview,
                      deviceSyncContextIsCurrent(identity) else { return }
                deviceSyncState = .needsReview
                return
            }
        } catch {
            guard deviceSyncLocalRecoveryReview == expectedReview,
                  deviceSyncContextIsCurrent(identity) else { return }
            deviceSyncState = .needsReview
            deviceSyncTransferState = .localPending
        }
    }

    func completeDeviceSyncLocalRecoveryReviewIfConfirmed(
        state: EpisodeSyncState,
        client: DeviceSyncClient,
        identity: DeviceSyncEpisodeIdentity,
        runtime: DeviceSyncRuntime
    ) async -> Bool {
        guard let review = deviceSyncLocalRecoveryReview,
              deviceSyncContextIsCurrent(identity),
              let current = document.episode(identity.episodeID)?.episode.content,
              let context = deviceSyncContext(in: state),
              context.remoteConfirmation == .confirmed,
              context.pendingRevisionCount == 0,
              context.pendingMaterialization == nil,
              context.localHead.contentDigest == SyncContentDigest(content: current),
              await removePreservedLocalRecoveryMarkers(
                  review.preservedMarkers,
                  expectedState: state,
                  client: client,
                  identity: identity,
                  runtime: runtime
              ) else { return false }
        deviceSyncLocalRecoveryReview = nil
        applyDeviceSyncState(state, client: client, expectedIdentity: identity)
        return true
    }

    func removePreservedLocalRecoveryMarkers(
        _ markers: [DeviceSyncEditIntentMarker],
        expectedState: EpisodeSyncState,
        client: DeviceSyncClient,
        identity: DeviceSyncEpisodeIdentity,
        runtime: DeviceSyncRuntime
    ) async -> Bool {
        do {
            guard let lookup = currentDeviceSyncLookupIdentity else { return false }
            let workingCopyIdentity = deviceSyncWorkingCopyIdentity(for: lookup.documentSession)
            let before = try await runtime.editIntentStore.loadPersistenceSnapshot(
                workingCopyIdentity: workingCopyIdentity,
                documentID: lookup.documentSession.documentID,
                episodeID: lookup.episodeID
            )
            guard deviceSyncContextIsCurrent(identity),
                  currentDeviceSyncLookupIdentity == lookup else { return false }
            guard deviceSyncLocalDurabilityState == .saved,
                  let current = document.episode(lookup.episodeID)?.episode.content,
                  let resolvingMarker = before.marker,
                  resolvingMarker.content == current,
                  resolvingMarker.contentDigest == SyncContentDigest(content: current),
                  resolvingMarker.resolvesPreservedSequences == markers.map(\.mutationSequence) else {
                return false
            }
            let coordinatorState = await client.coordinator.state
            guard coordinatorState == expectedState,
                  deviceSyncContextIsCurrent(identity),
                  currentDeviceSyncLookupIdentity == lookup else { return false }
            let snapshot = try await runtime.editIntentStore.removePreservedForReview(
                workingCopyIdentity: workingCopyIdentity,
                documentID: lookup.documentSession.documentID,
                episodeID: lookup.episodeID,
                expected: markers,
                expectedResolvingMarker: resolvingMarker
            )
            guard deviceSyncContextIsCurrent(identity),
                  currentDeviceSyncLookupIdentity == lookup else { return false }
            deviceSyncLocalRecoveryChoicePending = false
            return snapshot.marker == nil && snapshot.preservedMarkers.isEmpty
        } catch DeviceSyncLocalPersistenceError.invalidEditIntent {
            return false
        } catch {
            guard deviceSyncContextIsCurrent(identity) else { return false }
            deviceSyncLocalDurabilityState = .failed
            return false
        }
    }
}

private struct DeviceSyncLocalReviewPublish {
    let content: String
    let client: DeviceSyncClient?
    let identity: DeviceSyncEpisodeIdentity?
}

import Foundation
import NovelSync

extension IOSDocumentStore {
    func resolveDeviceSyncLocalRecovery(
        using choice: IOSDeviceSyncLocalRecoveryChoice,
        expectedReview: IOSDeviceSyncLocalRecoveryReview
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
        _ choice: IOSDeviceSyncLocalRecoveryChoice,
        expectedReview: IOSDeviceSyncLocalRecoveryReview,
        expectedLookup: IOSDeviceSyncLookupIdentity,
        runtime: IOSDeviceSyncRuntime
    ) async -> IOSDeviceSyncLocalReviewPublish? {
        await documentOperationGate.perform { [weak self] in
            guard let self,
                  currentDeviceSyncLookupIdentity == expectedLookup,
                  deviceSyncLocalRecoveryReview == expectedReview,
                  beginDeviceSyncBoundaryTransition() else { return nil as IOSDeviceSyncLocalReviewPublish? }
            defer { endDeviceSyncBoundaryTransition() }
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
        expectedLookup: IOSDeviceSyncLookupIdentity
    ) -> String? {
        let committed: String
        switch editorCommandSession.captureActiveCommittedText() {
        case let .captured(content):
            committed = content
        case .notActive:
            guard let content = document.episode(
                expectedLookup.editingToken.episodeID
            )?.episode.content else { return nil }
            committed = content
        case .compositionInProgress:
            return nil
        }
        guard currentDeviceSyncLookupIdentity == expectedLookup,
              document.episode(expectedLookup.editingToken.episodeID)?.episode.content == committed else {
            return nil
        }
        return committed
    }

    private func installChosenLocalRecoveryContent(
        _ chosen: String,
        replacing current: String,
        expectedLookup: IOSDeviceSyncLookupIdentity
    ) -> Bool {
        let episodeID = expectedLookup.editingToken.episodeID
        guard currentDeviceSyncLookupIdentity == expectedLookup,
              let location = document.episode(episodeID),
              location.episode.content == current else { return false }
        if chosen != current {
            let previousIdentity = activeDeviceSyncIdentity
            installDeviceSyncEpisodeContent(
                chosen,
                chapterID: location.chapterID,
                episodeID: episodeID,
                advancesEditorGeneration: true
            )
            if let previousIdentity {
                updateDeviceSyncIdentityAfterRemoteInstall(previousIdentity)
            }
        }
        registerDeviceSyncContentMutation(
            chosen,
            episodeID: episodeID,
            containsLocalEditIntent: true,
            forcesNewSequence: true
        )
        return document.episode(episodeID)?.episode.content == chosen
    }

    private func journalChosenLocalRecoveryContent(
        _ content: String,
        expectedLookup: IOSDeviceSyncLookupIdentity,
        runtime: IOSDeviceSyncRuntime
    ) async -> IOSDeviceSyncLocalReviewPublish? {
        guard currentDeviceSyncLookupIdentity == expectedLookup,
              let identity = activeDeviceSyncIdentity,
              deviceSyncContextIsCurrent(identity),
              let client = deviceSyncClient(for: identity) else {
            if currentDeviceSyncLookupIdentity == expectedLookup {
                deviceSyncLocalDurabilityState = .pending
            }
            return IOSDeviceSyncLocalReviewPublish(content: content, client: nil, identity: nil)
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
            return IOSDeviceSyncLocalReviewPublish(content: content, client: client, identity: identity)
        } catch {
            guard deviceSyncContextIsCurrent(identity) else { return nil }
            deviceSyncLocalDurabilityState = .failed
            return nil
        }
    }

    private func publishChosenLocalRecoveryContent(
        _: String,
        expectedReview: IOSDeviceSyncLocalRecoveryReview,
        client: IOSDeviceSyncClient,
        identity: IOSDeviceSyncEpisodeIdentity,
        runtime: IOSDeviceSyncRuntime
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
        client: IOSDeviceSyncClient,
        identity: IOSDeviceSyncEpisodeIdentity,
        runtime: IOSDeviceSyncRuntime
    ) async -> Bool {
        let episodeID = identity.editingToken.episodeID
        guard let review = deviceSyncLocalRecoveryReview,
              deviceSyncContextIsCurrent(identity),
              let current = document.episode(episodeID)?.episode.content,
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
        _ markers: [IOSDeviceSyncEditIntentMarker],
        expectedState: EpisodeSyncState,
        client: IOSDeviceSyncClient,
        identity: IOSDeviceSyncEpisodeIdentity,
        runtime: IOSDeviceSyncRuntime
    ) async -> Bool {
        do {
            guard let lookup = currentDeviceSyncLookupIdentity else { return false }
            let workingCopyIdentity = deviceSyncWorkingCopyIdentity(
                for: lookup.editingToken.documentSession.workingCopyID
            )
            let before = try await runtime.editIntentStore.loadPersistenceSnapshot(
                workingCopyIdentity: workingCopyIdentity,
                documentID: document.id,
                episodeID: lookup.editingToken.episodeID
            )
            guard deviceSyncContextIsCurrent(identity),
                  currentDeviceSyncLookupIdentity == lookup else { return false }
            guard deviceSyncLocalDurabilityState == .saved,
                  let current = document.episode(lookup.editingToken.episodeID)?.episode.content,
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
                documentID: document.id,
                episodeID: lookup.editingToken.episodeID,
                expected: markers,
                expectedResolvingMarker: resolvingMarker
            )
            guard deviceSyncContextIsCurrent(identity),
                  currentDeviceSyncLookupIdentity == lookup else { return false }
            deviceSyncLocalRecoveryChoicePending = false
            return snapshot.marker == nil && snapshot.preservedMarkers.isEmpty
        } catch IOSDeviceSyncLocalPersistenceError.invalidEditIntent {
            return false
        } catch {
            guard deviceSyncContextIsCurrent(identity) else { return false }
            deviceSyncLocalDurabilityState = .failed
            return false
        }
    }
}

private struct IOSDeviceSyncLocalReviewPublish {
    let content: String
    let client: IOSDeviceSyncClient?
    let identity: IOSDeviceSyncEpisodeIdentity?
}

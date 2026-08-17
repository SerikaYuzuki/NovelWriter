import Foundation
import NovelCore
import NovelSync

extension AppState {
    func resolveDeviceSyncConflict(
        using choice: EpisodeIntegrationChoice,
        expectedConflict: EpisodeConflict
    ) async {
        guard deviceSyncConflict == expectedConflict,
              case .conflict = deviceSyncState,
              let runtime = deviceSyncRuntime,
              let identity = activeDeviceSyncIdentity,
              let client = deviceSyncClient(for: identity) else { return }
        let submitted = PendingDeviceSyncConflictResolution(
            key: identity.syncKey,
            conflict: expectedConflict,
            content: choice.resolvedContent(for: expectedConflict)
        )
        deviceSyncState = .syncing
        guard await persistAcceptedConflictBridge(
            submitted,
            identity: identity,
            runtime: runtime
        ), deviceSyncContextIsCurrent(identity),
        deviceSyncConflict == expectedConflict else { return }
        pendingDeviceSyncConflictResolution = submitted
        await continueDeviceSyncConflictResolution(
            submitted,
            identity: identity,
            client: client,
            runtime: runtime
        )
    }

    private func persistAcceptedConflictBridge(
        _ resolution: PendingDeviceSyncConflictResolution,
        identity: DeviceSyncEpisodeIdentity,
        runtime: DeviceSyncRuntime
    ) async -> Bool {
        do {
            try await runtime.mergeRecoveryStore.save(
                DeviceSyncMergeRecoveryRecord(
                    localWorkingCopyID: identity.localWorkingCopyID,
                    key: identity.syncKey,
                    conflict: resolution.conflict,
                    content: resolution.content,
                    purpose: .acceptedResolution
                )
            )
            return true
        } catch {
            guard deviceSyncContextIsCurrent(identity),
                  deviceSyncConflict == resolution.conflict else { return false }
            deviceSyncState = .conflict(resolution.conflict)
            return false
        }
    }

    private func continueDeviceSyncConflictResolution(
        _ submitted: PendingDeviceSyncConflictResolution,
        identity: DeviceSyncEpisodeIdentity,
        client: DeviceSyncClient,
        runtime: DeviceSyncRuntime
    ) async {
        let state = await client.coordinator.state
        guard deviceSyncContextIsCurrent(identity),
              deviceSyncConflict == submitted.conflict else { return }
        if await consumeAlreadyIntegratedConflict(
            submitted,
            state: state,
            identity: identity,
            client: client,
            runtime: runtime
        ) {
            return
        }
        guard case let .conflicted(_, conflict) = state else {
            deviceSyncState = .blocked
            return
        }
        guard conflict == submitted.conflict else {
            await rebasePendingDeviceSyncDraft(submitted, to: conflict, identity: identity, runtime: runtime)
            return
        }
        guard let pending = pendingDeviceSyncConflictResolution,
              pending.key == identity.syncKey,
              pending.conflict == conflict else {
            await rebasePendingDeviceSyncDraft(submitted, to: conflict, identity: identity, runtime: runtime)
            return
        }
        await stageAndMaterializeConflictChoice(
            pending,
            identity: identity,
            client: client,
            runtime: runtime
        )
    }

    private func consumeAlreadyIntegratedConflict(
        _ resolution: PendingDeviceSyncConflictResolution,
        state: EpisodeSyncState,
        identity: DeviceSyncEpisodeIdentity,
        client: DeviceSyncClient,
        runtime: DeviceSyncRuntime
    ) async -> Bool {
        guard successfulMergeContext(in: state, resolution: resolution) != nil else { return false }
        do {
            try await runtime.mergeRecoveryStore.remove(
                localWorkingCopyID: identity.localWorkingCopyID,
                key: identity.syncKey
            )
        } catch {
            guard deviceSyncContextIsCurrent(identity),
                  deviceSyncConflict == resolution.conflict else { return true }
            deviceSyncState = .blocked
            return true
        }
        guard deviceSyncContextIsCurrent(identity),
              deviceSyncConflict == resolution.conflict else { return true }
        deviceSyncConflict = nil
        applyDeviceSyncState(state, client: client, expectedIdentity: identity)
        return true
    }

    private func stageAndMaterializeConflictChoice(
        _ resolution: PendingDeviceSyncConflictResolution,
        identity: DeviceSyncEpisodeIdentity,
        client: DeviceSyncClient,
        runtime: DeviceSyncRuntime
    ) async {
        let conflict = resolution.conflict
        do {
            let staged = try await client.coordinator.stageConflictResolutionLocalFirst(
                expectedConflict: conflict,
                choice: .manual(content: resolution.content),
                createdAt: runtime.now()
            )
            guard deviceSyncContextIsCurrent(identity),
                  deviceSyncConflict == conflict else { return }
            try await runtime.mergeRecoveryStore.remove(
                localWorkingCopyID: identity.localWorkingCopyID,
                key: identity.syncKey
            )
            guard deviceSyncContextIsCurrent(identity),
                  deviceSyncConflict == conflict else { return }
            let didInstall = await installResolvedConflictContent(
                staged.chosenRevision.content,
                expectedCurrentDigest: conflict.local.contentDigest,
                expectedIdentity: identity
            )
            guard deviceSyncConflict == conflict else { return }
            guard didInstall,
                  let installed = currentDeviceSyncIdentityAfterSingleInstall(from: identity) else {
                deviceSyncConflict = conflict
                deviceSyncState = .conflict(conflict)
                return
            }
            let state = try await client.coordinator.confirmStagedConflictResolutionMaterialized(
                staged,
                installedContentDigest: staged.chosenRevision.contentDigest
            )
            guard deviceSyncContextIsCurrent(installed) else { return }
            deviceSyncConflict = nil
            applyDeviceSyncState(state, client: client, expectedIdentity: installed)
            synchronizeResolvedConflictInBackground(client: client, identity: installed, runtime: runtime)
        } catch {
            guard deviceSyncContextIsCurrent(identity)
                || currentDeviceSyncIdentityAfterSingleInstall(from: identity) != nil else { return }
            deviceSyncConflict = conflict
            deviceSyncState = .conflict(conflict)
        }
    }

    func synchronizeResolvedConflictInBackground(
        client: DeviceSyncClient,
        identity: DeviceSyncEpisodeIdentity,
        runtime: DeviceSyncRuntime
    ) {
        Task { @MainActor [weak self] in
            do {
                let state = try await client.coordinator.synchronizeLocalFirst(
                    expiresAt: runtime.leaseExpiration(),
                    createdAt: runtime.now()
                )
                if await client.coordinator.conflictResolutionRecovery == nil {
                    try? await runtime.mergeRecoveryStore.remove(
                        localWorkingCopyID: identity.localWorkingCopyID,
                        key: identity.syncKey
                    )
                }
                guard let self else { return }
                if deviceSyncContextIsCurrent(identity) {
                    if await completeDeviceSyncLocalRecoveryReviewIfConfirmed(
                        state: state,
                        client: client,
                        identity: identity,
                        runtime: runtime
                    ) == false {
                        applyDeviceSyncState(state, client: client, expectedIdentity: identity)
                    }
                }
                let remainingRecovery = await client.coordinator.conflictResolutionRecovery
                guard deviceSyncContextIsCurrent(identity) else { return }
                if remainingRecovery == nil {
                    pendingDeviceSyncConflictResolution = nil
                }
            } catch EpisodeSyncTransportError.unavailable {
                guard let self, deviceSyncContextIsCurrent(identity) else { return }
                deviceSyncState = .offlineLocal
            } catch {
                guard let self, deviceSyncContextIsCurrent(identity) else { return }
                let state = await client.coordinator.state
                applyDeviceSyncState(state, client: client, expectedIdentity: identity)
            }
        }
    }

    private func rebasePendingDeviceSyncDraftAfterRemoteChange(
        _ resolution: PendingDeviceSyncConflictResolution,
        client: DeviceSyncClient,
        previousIdentity: DeviceSyncEpisodeIdentity,
        runtime: DeviceSyncRuntime
    ) async {
        guard let currentIdentity = activeDeviceSyncIdentity,
              currentIdentity.localWorkingCopyID == previousIdentity.localWorkingCopyID,
              currentIdentity.syncKey == previousIdentity.syncKey,
              deviceSyncContextIsCurrent(currentIdentity) else {
            deviceSyncState = .blocked
            return
        }
        let state = await client.coordinator.state
        guard deviceSyncContextIsCurrent(currentIdentity),
              deviceSyncConflict == resolution.conflict else { return }
        guard case let .conflicted(_, conflict) = state else {
            deviceSyncState = .blocked
            return
        }
        await rebasePendingDeviceSyncDraft(
            resolution,
            to: conflict,
            identity: currentIdentity,
            runtime: runtime
        )
    }

    private func rebasePendingDeviceSyncDraft(
        _ resolution: PendingDeviceSyncConflictResolution,
        to conflict: EpisodeConflict,
        identity: DeviceSyncEpisodeIdentity,
        runtime: DeviceSyncRuntime
    ) async {
        guard resolution.key == identity.syncKey,
              conflict.local.revisionID == resolution.conflict.local.revisionID else {
            // local parentまで変わった場合は、旧markerを消さず停止する。
            deviceSyncState = .blocked
            return
        }
        let rebased = PendingDeviceSyncConflictResolution(
            key: identity.syncKey,
            conflict: conflict,
            content: resolution.content
        )
        do {
            try await runtime.mergeRecoveryStore.save(
                DeviceSyncMergeRecoveryRecord(
                    localWorkingCopyID: identity.localWorkingCopyID,
                    key: identity.syncKey,
                    conflict: conflict,
                    content: rebased.content
                )
            )
        } catch {
            guard deviceSyncContextIsCurrent(identity),
                  deviceSyncConflict == resolution.conflict else { return }
            deviceSyncState = .blocked
            return
        }
        guard deviceSyncContextIsCurrent(identity),
              deviceSyncConflict == resolution.conflict else { return }
        pendingDeviceSyncConflictResolution = rebased
        deviceSyncConflict = conflict
        deviceSyncState = .conflict(conflict)
    }

    func installResolvedConflictContent(
        _ content: String,
        expectedCurrentDigest: SyncContentDigest,
        expectedIdentity: DeviceSyncEpisodeIdentity
    ) async -> Bool {
        await documentOperationGate.perform { [weak self] in
            guard let self,
                  deviceSyncContextIsCurrent(expectedIdentity),
                  beginDocumentTransition() else { return false }
            defer { endDocumentTransition() }
            guard let committed = capturedCommittedContent(for: expectedIdentity),
                  SyncContentDigest(content: committed) == expectedCurrentDigest,
                  document.episode(expectedIdentity.episodeID)?.episode.content == committed else {
                return false
            }
            saveCoordinator.markDirty()
            let result = await saveCoordinator.performExclusiveAfterFlushing(flushAfter: true) {
                guard deviceSyncContextIsCurrent(expectedIdentity) else { return false }
                installDeviceSyncEpisodeContent(
                    content,
                    chapterID: expectedIdentity.chapterID,
                    episodeID: expectedIdentity.episodeID,
                    advancesEditorGeneration: true
                )
                updateDeviceSyncIdentityAfterRemoteInstall(expectedIdentity)
                return true
            }
            switch result {
            case .saveFailedBeforeOperation:
                return false
            case let .completed(didInstall, savedAfterOperation):
                return didInstall && savedAfterOperation
            }
        }
    }

    private func capturedCommittedContent(for identity: DeviceSyncEpisodeIdentity) -> String? {
        switch captureCommittedTextForDeviceSync() {
        case let .captured(content):
            content
        case .notActive:
            document.episode(identity.episodeID)?.episode.content
        case .compositionInProgress:
            nil
        }
    }

    func updateDeviceSyncIdentityAfterRemoteInstall(_ previous: DeviceSyncEpisodeIdentity) {
        let updated = DeviceSyncEpisodeIdentity(
            documentSession: documentSessionToken,
            chapterID: previous.chapterID,
            episodeID: previous.episodeID,
            editorContentGeneration: editorContentGeneration,
            structureDigest: previous.structureDigest,
            localWorkingCopyID: previous.localWorkingCopyID,
            syncKey: previous.syncKey
        )
        activeDeviceSyncIdentity = updated
        resolvedDeviceSyncLookupIdentity = DeviceSyncLookupIdentity(
            documentSession: updated.documentSession,
            chapterID: updated.chapterID,
            episodeID: updated.episodeID,
            editorContentGeneration: updated.editorContentGeneration,
            structureDigest: updated.structureDigest
        )
    }

    func currentDeviceSyncIdentityAfterSingleInstall(
        from previous: DeviceSyncEpisodeIdentity
    ) -> DeviceSyncEpisodeIdentity? {
        guard let current = activeDeviceSyncIdentity,
              deviceSyncContextIsCurrent(current),
              current.documentSession == previous.documentSession,
              current.chapterID == previous.chapterID,
              current.episodeID == previous.episodeID,
              current.localWorkingCopyID == previous.localWorkingCopyID,
              current.syncKey == previous.syncKey,
              current.editorContentGeneration == previous.editorContentGeneration &+ 1 else { return nil }
        return current
    }

    func mergeRecoveryRecord(
        _ record: DeviceSyncMergeRecoveryRecord,
        matches conflict: EpisodeConflict
    ) -> Bool {
        Set([conflict.local.revisionID, conflict.remote.revisionID]) == record.parentRevisionIDs
    }

    private func successfulMergeContext(
        in state: EpisodeSyncState,
        resolution: PendingDeviceSyncConflictResolution
    ) -> EpisodeSyncContext? {
        guard case let .upToDate(context) = state,
              context.pendingRevisionCount == 0 else { return nil }
        let expectedParents = Set([
            resolution.conflict.local.revisionID,
            resolution.conflict.remote.revisionID
        ])
        guard Set(context.localHead.parentRevisionIDs) == expectedParents,
              context.localHead.contentDigest == SyncContentDigest(content: resolution.content) else { return nil }
        return context
    }
}

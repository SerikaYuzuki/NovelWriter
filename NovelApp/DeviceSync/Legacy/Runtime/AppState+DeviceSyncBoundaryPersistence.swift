import Foundation
import NovelCore
import NovelSync

private struct DeviceSyncBoundarySnapshot {
    let chapterID: ChapterID
    let episodeID: EpisodeID
    let content: String
    let capturedNewMutation: Bool
    let baseContentDigest: SyncContentDigest?
    let previousContentDigest: SyncContentDigest?
}

private enum DeviceSyncBoundaryPersistence {
    case failed
    case packageOnly
    case ready
}

private struct DeviceSyncBoundaryClient {
    let runtime: DeviceSyncRuntime
    let identity: DeviceSyncEpisodeIdentity
    let client: DeviceSyncClient
}

extension AppState {
    @discardableResult
    func flushPreparedDeviceSyncBoundarySerially(
        releaseAuthority: Bool,
        waitForRemote: Bool = true
    ) async -> Bool {
        guard startupState.isReady, editorCommandSession.isDocumentTransitionPrepared else { return false }
        deviceSyncDraftTask?.cancel()
        deviceSyncDraftTask = nil
        if hasCurrentWorkSyncClient {
            guard await captureAndSavePreparedWorkSyncBoundary() else { return false }
            return waitForRemote
                ? await materializePendingWorkSyncAtPreparedBoundary()
                : true
        }
        guard selectedChapterID != nil, selectedEpisodeID != nil else {
            return await saveCoordinator.saveNow()
        }
        guard let snapshot = captureDeviceSyncBoundarySnapshot() else { return false }
        switch await persistDeviceSyncBoundaryPackage(snapshot) {
        case .failed:
            return false
        case .packageOnly:
            deviceSyncLocalDurabilityState = .failed
            return true
        case .ready:
            break
        }
        guard let resolved = resolvedDeviceSyncBoundaryClient(snapshot) else { return true }
        return await reconcileDeviceSyncBoundary(
            snapshot,
            releaseAuthority: releaseAuthority,
            waitForRemote: waitForRemote,
            resolved: resolved
        )
    }

    private func captureAndSavePreparedWorkSyncBoundary() async -> Bool {
        guard editorCommandSession.isDocumentTransitionPrepared else { return false }
        if let chapterID = selectedChapterID, let episodeID = selectedEpisodeID {
            switch captureCommittedTextForDeviceSync() {
            case let .captured(content):
                if document.episode(episodeID)?.episode.content != content {
                    installDeviceSyncEpisodeContent(
                        content,
                        chapterID: chapterID,
                        episodeID: episodeID,
                        advancesEditorGeneration: false
                    )
                }
            case .notActive:
                break
            case .compositionInProgress:
                return false
            }
        }
        return await saveCoordinator.saveNow()
    }

    private func captureDeviceSyncBoundarySnapshot() -> DeviceSyncBoundarySnapshot? {
        guard let chapterID = selectedChapterID, let episodeID = selectedEpisodeID else { return nil }
        switch captureCommittedTextForDeviceSync() {
        case let .captured(content):
            let previousContent = document.episode(episodeID)?.episode.content ?? ""
            let changed = previousContent != content
            if changed {
                installDeviceSyncEpisodeContent(
                    content,
                    chapterID: chapterID,
                    episodeID: episodeID,
                    advancesEditorGeneration: false
                )
            }
            return DeviceSyncBoundarySnapshot(
                chapterID: chapterID,
                episodeID: episodeID,
                content: content,
                capturedNewMutation: changed,
                baseContentDigest: changed ? deviceSyncDurablePackageDigest(
                    for: episodeID,
                    fallbackContent: previousContent
                ) : nil,
                previousContentDigest: changed ? SyncContentDigest(content: previousContent) : nil
            )
        case .notActive:
            guard let content = document.episode(episodeID)?.episode.content else { return nil }
            return DeviceSyncBoundarySnapshot(
                chapterID: chapterID,
                episodeID: episodeID,
                content: content,
                capturedNewMutation: false,
                baseContentDigest: nil,
                previousContentDigest: nil
            )
        case .compositionInProgress:
            return nil
        }
    }

    private func persistDeviceSyncBoundaryPackage(
        _ snapshot: DeviceSyncBoundarySnapshot
    ) async -> DeviceSyncBoundaryPersistence {
        if snapshot.capturedNewMutation, let lookup = currentDeviceSyncLookupIdentity {
            enqueueDeviceSyncEditIntent(
                content: snapshot.content,
                expectedLookup: lookup,
                baseContentDigest: snapshot.baseContentDigest,
                previousContentDigest: snapshot.previousContentDigest
            )
        }
        let journalLaneReady = await flushPendingDeviceSyncEditIntents()
        guard await saveCoordinator.saveNow() else { return .failed }
        return journalLaneReady ? .ready : .packageOnly
    }

    private func resolvedDeviceSyncBoundaryClient(
        _ snapshot: DeviceSyncBoundarySnapshot
    ) -> DeviceSyncBoundaryClient? {
        guard let runtime = deviceSyncRuntime,
              let identity = activeDeviceSyncIdentity,
              identity.documentSession == documentSessionToken,
              identity.chapterID == snapshot.chapterID,
              identity.episodeID == snapshot.episodeID,
              let client = deviceSyncClient(for: identity) else { return nil }
        return DeviceSyncBoundaryClient(runtime: runtime, identity: identity, client: client)
    }

    private func reconcileDeviceSyncBoundary(
        _ snapshot: DeviceSyncBoundarySnapshot,
        releaseAuthority: Bool,
        waitForRemote: Bool,
        resolved: DeviceSyncBoundaryClient
    ) async -> Bool {
        do {
            let state = try await reconcileDeviceSyncBoundaryJournal(
                content: snapshot.content,
                runtime: resolved.runtime,
                identity: resolved.identity,
                client: resolved.client
            )
            applyDeviceSyncState(state, client: resolved.client, expectedIdentity: resolved.identity)
            return await finishDeviceSyncBoundaryReconciliation(
                state: state,
                content: snapshot.content,
                releaseAuthority: releaseAuthority,
                waitForRemote: waitForRemote,
                resolved: resolved
            )
        } catch {
            await applyDeviceSyncState(
                resolved.client.coordinator.state,
                client: resolved.client,
                expectedIdentity: resolved.identity
            )
            deviceSyncLocalDurabilityState = .failed
            return false
        }
    }

    private func reconcileDeviceSyncBoundaryJournal(
        content: String,
        runtime: DeviceSyncRuntime,
        identity: DeviceSyncEpisodeIdentity,
        client: DeviceSyncClient
    ) async throws -> EpisodeSyncState {
        let state = await client.coordinator.state
        let packageIsAhead = deviceSyncContext(in: state).map {
            $0.localHead.contentDigest != SyncContentDigest(content: content)
        } ?? false
        let hasExactIntent = await hasExactDeviceSyncEditIntent(content: content, identity: identity)
        if hasExactIntent || packageIsAhead {
            let sequence = await latestExactDeviceSyncEditIntentSequence(content: content, identity: identity)
            let receipt = try await client.coordinator.recordLocalEdit(content, createdAt: runtime.now())
            await markDeviceSyncLocalEditSavedIfCurrent(
                receipt,
                content: content,
                expectedIdentity: identity,
                acknowledgedMutationSequence: sequence
            )
            return receipt.state
        }
        guard case .unlinked = state else { return state }
        return try await client.coordinator.observeLocalBase(
            localContent: content,
            createdAt: runtime.now()
        )
    }

    private func finishDeviceSyncBoundaryReconciliation(
        state: EpisodeSyncState,
        content: String,
        releaseAuthority: Bool,
        waitForRemote: Bool,
        resolved: DeviceSyncBoundaryClient
    ) async -> Bool {
        if releaseAuthority {
            guard await materializeIntegratedDeviceSyncContentIfSafe(
                client: resolved.client,
                identity: resolved.identity,
                currentContent: content
            ) else { return false }
        }
        guard waitForRemote,
              releaseAuthority,
              resolved.client.remoteSynchronizationAllowed,
              shouldSynchronizeLocalFirst(state) else {
            if !waitForRemote,
               releaseAuthority,
               resolved.client.remoteSynchronizationAllowed,
               shouldSynchronizeLocalFirst(state),
               deviceSyncLocalRecoveryReview == nil {
                // The foreground transition is already complete. Continue the
                // remote lane without making the caller wait for it.
                reconcileDeviceSyncAfterDeparture(
                    client: resolved.client,
                    identity: resolved.identity,
                    runtime: resolved.runtime
                )
            }
            if !resolved.client.remoteSynchronizationAllowed, case .conflict = deviceSyncState {
                return true
            }
            if !resolved.client.remoteSynchronizationAllowed {
                deviceSyncState = resolved.client.remoteAvailability == .temporarilyOffline
                    ? .offlineLocal
                    : .blocked
            }
            return true
        }
        guard deviceSyncLocalRecoveryReview == nil else {
            deviceSyncState = .needsReview
            deviceSyncTransferState = .localPending
            return true
        }
        reconcileDeviceSyncAfterDeparture(
            client: resolved.client,
            identity: resolved.identity,
            runtime: resolved.runtime
        )
        return true
    }
}

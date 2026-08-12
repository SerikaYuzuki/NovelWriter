import EditorKit
import Foundation
import NovelCore
import NovelSync

extension IOSDocumentStore {
    @discardableResult
    func addChapterAfterDeviceSyncDeparture() async -> Bool {
        let previousCount = document.chapters.count
        return await performDeviceSyncDepartureMutation {
            addChapter()
            return document.chapters.count == previousCount + 1
        } ?? false
    }

    @discardableResult
    func addEpisodeAfterDeviceSyncDeparture(to chapterID: ChapterID? = nil) async -> Bool {
        let targetChapterID = chapterID ?? selectedChapterID
        let previousCount = document.chapters.first(where: { $0.id == targetChapterID })?.episodes.count
        return await performDeviceSyncDepartureMutation {
            if let targetChapterID {
                selectChapter(targetChapterID)
            }
            addEpisode()
            guard let targetChapterID, let previousCount else { return false }
            return document.chapters.first(where: { $0.id == targetChapterID })?.episodes.count
                == previousCount + 1
        } ?? false
    }

    @discardableResult
    func deleteEpisodesAfterDeviceSyncDeparture(
        at offsets: IndexSet,
        chapterID: ChapterID
    ) async -> Bool {
        let previousCount = document.chapters.first(where: { $0.id == chapterID })?.episodes.count
        return await performDeviceSyncDepartureMutation {
            deleteEpisodes(at: offsets, chapterID: chapterID)
            guard let previousCount else { return false }
            return document.chapters.first(where: { $0.id == chapterID })?.episodes.count != previousCount
        } ?? false
    }

    @discardableResult
    func moveChaptersAfterDeviceSyncDeparture(
        fromOffsets: IndexSet,
        toOffset: Int
    ) async -> Bool {
        await performDeviceSyncDepartureMutation {
            moveChapters(fromOffsets: fromOffsets, toOffset: toOffset)
            return true
        } ?? false
    }

    @discardableResult
    func moveEpisodesAfterDeviceSyncDeparture(
        in chapterID: ChapterID,
        fromOffsets: IndexSet,
        toOffset: Int
    ) async -> Bool {
        await performDeviceSyncDepartureMutation {
            moveEpisodes(in: chapterID, fromOffsets: fromOffsets, toOffset: toOffset)
            return true
        } ?? false
    }

    @discardableResult
    func flushDeviceSyncForBackground(waitForRemote: Bool = true) async -> Bool {
        let inFlightDraft = deviceSyncDraftTask
        deviceSyncDraftTask = nil
        inFlightDraft?.cancel()
        return await documentOperationGate.perform { [weak self] in
            guard let self, startupState == .ready else { return true }
            // アプリはbackground中で入力を受け付けないため、ここでは
            // document transitionの全画面ロックを立てない。復帰が先に
            // 来ても、UIと入力をロックしたままにしないための境界。
            guard editorCommandSession.prepareForDocumentTransition() else { return false }
            defer { editorCommandSession.resumeAfterDocumentTransition() }
            return await flushPreparedDeviceSyncBoundarySerially(
                releaseAuthority: false,
                waitForRemote: waitForRemote
            )
        }
    }

    @discardableResult
    func prepareForEditorSurfaceDeparture() async -> Bool {
        await documentOperationGate.perform { [weak self] in
            guard let self, startupState == .ready else { return true }
            guard beginDeviceSyncBoundaryTransition() else { return false }
            defer { endDeviceSyncBoundaryTransition() }
            guard await flushPreparedDeviceSyncBoundarySerially(
                releaseAuthority: true,
                waitForRemote: false
            ) else { return false }
            advanceEditorContentGeneration()
            deviceSyncSelectionDidChange()
            return true
        }
    }

    @discardableResult
    func flushDeviceSyncBeforeNavigationDeparture(
        _ departure: IOSWorkspaceEditorDeparture
    ) async -> Bool {
        let didFlush = await documentOperationGate.perform { [weak self] in
            guard let self else { return false }
            isNavigationDepartureInProgress = true
            defer { isNavigationDepartureInProgress = false }
            guard currentDocumentSessionToken == departure.session else { return true }
            let chapterID = departure.chapterID ?? selectedChapterID
            let episodeID = departure.episodeID ?? selectedEpisodeID
            guard chapterID == selectedChapterID, episodeID == selectedEpisodeID else { return true }
            guard beginDeviceSyncBoundaryTransition() else { return false }
            defer { endDeviceSyncBoundaryTransition() }
            return await flushPreparedDeviceSyncBoundaryForNavigation()
        }
        if didFlush, !usesWholeWorkDeviceSync {
            scheduleDeviceSyncDepartureReconciliationIfPossible()
        }
        return didFlush
    }

    private func scheduleDeviceSyncDepartureReconciliationIfPossible() {
        guard deviceSyncLocalDurabilityState != .failed,
              let runtime = deviceSyncRuntime,
              let identity = activeDeviceSyncIdentity,
              deviceSyncContextIsCurrent(identity),
              let client = deviceSyncClient(for: identity) else { return }
        reconcileDeviceSyncAfterDeparture(
            client: client,
            identity: identity,
            runtime: runtime
        )
    }

    @discardableResult
    func selectEpisodeAfterDeviceSyncDeparture(
        chapterID: ChapterID,
        episodeID: EpisodeID
    ) async -> Bool {
        let expectedSession = currentDocumentSessionToken
        let expectedChapterID = selectedChapterID
        let expectedEpisodeID = selectedEpisodeID
        guard chapterID != expectedChapterID || episodeID != expectedEpisodeID else { return true }

        return await documentOperationGate.perform { [weak self] in
            guard let self,
                  currentDocumentSessionToken == expectedSession,
                  selectedChapterID == expectedChapterID,
                  selectedEpisodeID == expectedEpisodeID,
                  beginDeviceSyncBoundaryTransition() else { return false }
            let didFlush = await flushPreparedDeviceSyncBoundarySerially(
                releaseAuthority: true,
                waitForRemote: false
            )
            guard didFlush,
                  currentDocumentSessionToken == expectedSession,
                  selectedChapterID == expectedChapterID,
                  selectedEpisodeID == expectedEpisodeID else {
                endDeviceSyncBoundaryTransition()
                return false
            }
            permitsDeviceSyncSelectionMutationAfterFlush = true
            defer { permitsDeviceSyncSelectionMutationAfterFlush = false }
            selectChapter(chapterID)
            selectEpisode(episodeID)
            endDeviceSyncBoundaryTransition()
            return selectedChapterID == chapterID && selectedEpisodeID == episodeID
        }
    }

    func reconcileDeviceSyncAfterDeparture(
        client: IOSDeviceSyncClient,
        identity: IOSDeviceSyncEpisodeIdentity,
        runtime: IOSDeviceSyncRuntime
    ) {
        guard deviceSyncLocalRecoveryReview == nil || deviceSyncLocalRecoveryChoicePending else { return }
        Task { @MainActor [weak self] in
            do {
                let state = try await client.coordinator.synchronizeLocalFirst(
                    expiresAt: runtime.leaseExpiration(),
                    createdAt: runtime.now()
                )
                guard let self else { return }
                if deviceSyncContextIsCurrent(identity) {
                    applyDeviceSyncState(state, client: client, expectedIdentity: identity)
                } else {
                    await materializeInactiveDeviceSyncContentIfSafe(client: client, identity: identity)
                }
            } catch EpisodeSyncTransportError.unavailable {
                guard let self, deviceSyncContextIsCurrent(identity) else { return }
                deviceSyncState = .offlineLocal
            } catch {
                guard let self, deviceSyncContextIsCurrent(identity) else { return }
                deviceSyncState = .blocked
            }
        }
    }

    private func materializeInactiveDeviceSyncContentIfSafe(
        client: IOSDeviceSyncClient,
        identity: IOSDeviceSyncEpisodeIdentity
    ) async {
        await documentOperationGate.perform { [weak self] in
            guard let self,
                  currentDocumentSessionToken == identity.editingToken.documentSession,
                  selectedEpisodeID != identity.editingToken.episodeID,
                  let pending = await client.coordinator.integrationAwaitingMaterialization else { return }
            let state = await client.coordinator.state
            guard let context = deviceSyncContext(in: state),
                  context.pendingMaterialization == pending,
                  context.localHead.revisionID == pending.workingRevisionID,
                  let episodeLocation = document.episode(identity.editingToken.episodeID) else { return }
            let current = episodeLocation.episode.content
            guard context.localHead.contentDigest == SyncContentDigest(content: current) else { return }
            let currentChapterID = episodeLocation.chapterID
            installDeviceSyncEpisodeContent(
                pending.integratedRevision.content,
                chapterID: currentChapterID,
                episodeID: identity.editingToken.episodeID,
                advancesEditorGeneration: false
            )
            guard document.episode(identity.editingToken.episodeID)?.episode.content
                == pending.integratedRevision.content,
                await saveCoordinator.saveNow(),
                document.episode(identity.editingToken.episodeID)?.episode.content
                == pending.integratedRevision.content else {
                installDeviceSyncEpisodeContent(
                    current,
                    chapterID: currentChapterID,
                    episodeID: identity.editingToken.episodeID,
                    advancesEditorGeneration: false
                )
                return
            }
            _ = try? await client.coordinator.confirmIntegratedContentMaterialized(
                pending,
                installedContentDigest: pending.integratedRevision.contentDigest
            )
        }
    }

    func materializeIntegratedDeviceSyncContentIfSafe(
        client: IOSDeviceSyncClient,
        identity: IOSDeviceSyncEpisodeIdentity,
        currentContent: String
    ) async -> Bool {
        guard let pending = await client.coordinator.integrationAwaitingMaterialization else { return true }
        let state = await client.coordinator.state
        guard let context = deviceSyncContext(in: state),
              context.pendingMaterialization == pending,
              context.localHead.revisionID == pending.workingRevisionID,
              context.localHead.contentDigest == SyncContentDigest(content: currentContent),
              document.episode(identity.editingToken.episodeID)?.episode.content == currentContent,
              deviceSyncContextIsCurrent(identity) else {
            return true
        }

        guard let currentChapterID = document.episode(identity.editingToken.episodeID)?.chapterID else { return true }
        let integrated = pending.integratedRevision
        installDeviceSyncEpisodeContent(
            integrated.content,
            chapterID: currentChapterID,
            episodeID: identity.editingToken.episodeID,
            advancesEditorGeneration: false
        )
        guard document.episode(identity.editingToken.episodeID)?.episode.content == integrated.content,
              await saveCoordinator.saveNow(),
              document.episode(identity.editingToken.episodeID)?.episode.content == integrated.content else {
            installDeviceSyncEpisodeContent(
                currentContent,
                chapterID: currentChapterID,
                episodeID: identity.editingToken.episodeID,
                advancesEditorGeneration: false
            )
            return false
        }

        do {
            let confirmed = try await client.coordinator.confirmIntegratedContentMaterialized(
                pending,
                installedContentDigest: integrated.contentDigest
            )
            if let runtime = deviceSyncRuntime,
               await completeDeviceSyncLocalRecoveryReviewIfConfirmed(
                   state: confirmed,
                   client: client,
                   identity: identity,
                   runtime: runtime
               ) == false {
                applyDeviceSyncState(confirmed, client: client, expectedIdentity: identity)
            }
        } catch {
            // Keep the exact pending marker for restart recovery.
        }
        return true
    }

    func beginDeviceSyncBoundaryTransition() -> Bool {
        guard !isDocumentTransitionInProgress else { return false }
        isDocumentTransitionInProgress = true
        guard editorCommandSession.prepareForDocumentTransition() else {
            isDocumentTransitionInProgress = false
            operationErrorMessage = "日本語入力を確定できませんでした。変換を確定してから、もう一度お試しください。"
            return false
        }
        return true
    }

    func endDeviceSyncBoundaryTransition() {
        guard isDocumentTransitionInProgress else { return }
        editorCommandSession.resumeAfterDocumentTransition()
        isDocumentTransitionInProgress = false
    }

    private func releaseDeviceSyncAuthorityForBoundary(
        client: IOSDeviceSyncClient,
        identity: IOSDeviceSyncEpisodeIdentity,
        releaseAuthority: Bool
    ) async -> Bool {
        guard releaseAuthority else { return true }
        do {
            let released = try await client.coordinator.releaseEditingAuthority()
            applyDeviceSyncState(released, client: client, expectedIdentity: identity)
            return true
        } catch EpisodeSyncTransportError.unavailable {
            deviceSyncState = .offlineLocal
            return true
        } catch {
            deviceSyncState = .offlineLocal
            return true
        }
    }

    private func performDeviceSyncDepartureMutation<Value>(
        operation: () -> Value
    ) async -> Value? {
        let sourceSession = currentDocumentSessionToken
        let sourceChapterID = selectedChapterID
        let sourceEpisodeID = selectedEpisodeID

        return await documentOperationGate.perform { [weak self] in
            guard let self,
                  currentDocumentSessionToken == sourceSession,
                  selectedChapterID == sourceChapterID,
                  selectedEpisodeID == sourceEpisodeID,
                  beginDeviceSyncBoundaryTransition() else { return nil }
            defer { endDeviceSyncBoundaryTransition() }

            let didFlush = await flushPreparedDeviceSyncBoundarySerially(
                releaseAuthority: true,
                waitForRemote: false
            )
            guard didFlush,
                  currentDocumentSessionToken == sourceSession,
                  selectedChapterID == sourceChapterID,
                  selectedEpisodeID == sourceEpisodeID else { return nil }

            permitsDeviceSyncSelectionMutationAfterFlush = true
            defer { permitsDeviceSyncSelectionMutationAfterFlush = false }
            return operation()
        }
    }
}

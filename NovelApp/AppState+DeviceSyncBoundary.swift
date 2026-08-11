import Foundation
import NovelCore
import NovelSync

extension AppState {
    @discardableResult
    func addChapterAfterDeviceSyncDeparture() async -> Bool {
        let previousCount = document.chapters.count
        return await performDeviceSyncDepartureMutation {
            addChapter()
            return document.chapters.count == previousCount + 1
        } ?? false
    }

    @discardableResult
    func addEpisodeAfterDeviceSyncDeparture(
        to chapterID: ChapterID? = nil,
        title: String? = nil
    ) async -> Bool {
        let targetChapterID = chapterID ?? selectedChapterID
        guard let targetChapterID else { return false }
        let previousCount = document.chapters.first(where: { $0.id == targetChapterID })?.episodes.count
        return await performDeviceSyncDepartureMutation {
            addEpisode(to: targetChapterID, title: title)
            guard let previousCount else { return false }
            return document.chapters.first(where: { $0.id == targetChapterID })?.episodes.count == previousCount + 1
        } ?? false
    }

    @discardableResult
    func deleteChapterAfterDeviceSyncDeparture(
        id: ChapterID,
        expectedSession: DocumentSessionToken
    ) async -> Bool {
        await performDeviceSyncDepartureMutation(expectedSession: expectedSession) {
            deleteChapter(id: id, expectedSession: expectedSession)
        } ?? false
    }

    @discardableResult
    func deleteEpisodeAfterDeviceSyncDeparture(
        id: EpisodeID,
        from chapterID: ChapterID,
        expectedSession: DocumentSessionToken
    ) async -> Bool {
        await performDeviceSyncDepartureMutation(expectedSession: expectedSession) {
            deleteEpisode(
                id: id,
                from: chapterID,
                expectedSession: expectedSession
            )
        } ?? false
    }

    @discardableResult
    func moveEpisodeAfterDeviceSyncDeparture(
        id: EpisodeID,
        from sourceChapterID: ChapterID,
        to destinationChapterID: ChapterID,
        before targetEpisodeID: EpisodeID? = nil
    ) async -> Bool {
        await performDeviceSyncDepartureMutation {
            moveEpisode(
                id: id,
                from: sourceChapterID,
                to: destinationChapterID,
                before: targetEpisodeID
            )
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
    func selectPlotOutlineAfterDeviceSyncDeparture(_ selection: PlotOutlineSelection) async -> Bool {
        await performDeviceSyncDepartureMutation {
            selectPlotOutline(selection)
            return plotOutlineSelection == selection
        } ?? false
    }

    @discardableResult
    func movePlotCardFromOutlineAfterDeviceSyncDeparture(
        id: PlotCardID,
        to selection: PlotOutlineSelection
    ) async -> Bool {
        await performDeviceSyncDepartureMutation {
            movePlotCardFromOutline(id: id, to: selection)
        } ?? false
    }

    @discardableResult
    func selectProjectSectionAfterDeviceSyncDeparture(_ section: ProjectSection) async -> Bool {
        guard workspaceSelection.section != section else { return true }
        return await performDeviceSyncDepartureMutation {
            permitsDeviceSyncProjectSectionMutationAfterFlush = true
            defer { permitsDeviceSyncProjectSectionMutationAfterFlush = false }
            advanceEditorContentGenerationForSurfaceTransition()
            deviceSyncSelectionDidChange()
            selectProjectSection(section)
            return workspaceSelection.section == section
        } ?? false
    }

    /// Scene離脱時はIMEを確定し、packageを先に保存してからjournalへ退避する。
    /// ネットワーク同期はbest effortで、失敗しても端末内の2つの保存を巻き戻さない。
    @discardableResult
    func flushDeviceSyncForBackground() async -> Bool {
        // CloudKit transport can remain suspended after cancellation. Do not wait for it
        // before committing marked text and the local package during sleep/backgrounding.
        let inFlightDraft = deviceSyncDraftTask
        deviceSyncDraftTask = nil
        inFlightDraft?.cancel()
        return await documentOperationGate.perform { [weak self] in
            guard let self, startupState.isReady else { return true }
            guard beginDocumentTransition() else { return false }
            defer { endDocumentTransition() }
            return await flushPreparedDeviceSyncBoundarySerially(releaseAuthority: false)
        }
    }

    @discardableResult
    func selectChapterAfterDeviceSyncDeparture(_ id: ChapterID?) async -> Bool {
        let expectedSession = documentSessionToken
        let expectedChapterID = selectedChapterID
        let expectedEpisodeID = selectedEpisodeID
        guard id != expectedChapterID else { return true }

        return await documentOperationGate.perform { [weak self] in
            guard let self,
                  documentSessionToken == expectedSession,
                  selectedChapterID == expectedChapterID,
                  selectedEpisodeID == expectedEpisodeID,
                  beginDocumentTransition() else { return false }
            defer { endDocumentTransition() }
            let didFlush = await flushPreparedDeviceSyncBoundarySerially(releaseAuthority: true)
            guard didFlush,
                  documentSessionToken == expectedSession,
                  selectedChapterID == expectedChapterID,
                  selectedEpisodeID == expectedEpisodeID else { return false }
            permitsDeviceSyncSelectionMutationAfterFlush = true
            defer { permitsDeviceSyncSelectionMutationAfterFlush = false }
            selectChapter(id)
            return selectedChapterID == id
        }
    }

    @discardableResult
    func selectEpisodeAfterDeviceSyncDeparture(
        _ id: EpisodeID?,
        in chapterID: ChapterID? = nil
    ) async -> Bool {
        let expectedSession = documentSessionToken
        let expectedChapterID = selectedChapterID
        let expectedEpisodeID = selectedEpisodeID
        let targetChapterID = chapterID ?? expectedChapterID
        guard targetChapterID != expectedChapterID || id != expectedEpisodeID else { return true }

        return await documentOperationGate.perform { [weak self] in
            guard let self,
                  documentSessionToken == expectedSession,
                  selectedChapterID == expectedChapterID,
                  selectedEpisodeID == expectedEpisodeID,
                  beginDocumentTransition() else { return false }
            defer { endDocumentTransition() }
            let didFlush = await flushPreparedDeviceSyncBoundarySerially(releaseAuthority: true)
            guard didFlush,
                  documentSessionToken == expectedSession,
                  selectedChapterID == expectedChapterID,
                  selectedEpisodeID == expectedEpisodeID else { return false }
            permitsDeviceSyncSelectionMutationAfterFlush = true
            defer { permitsDeviceSyncSelectionMutationAfterFlush = false }
            selectEpisode(id, in: targetChapterID)
            return selectedChapterID == targetChapterID && selectedEpisodeID == id
        }
    }

    func reconcileDeviceSyncAfterDeparture(
        client: DeviceSyncClient,
        identity: DeviceSyncEpisodeIdentity,
        runtime: DeviceSyncRuntime
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
        client: DeviceSyncClient,
        identity: DeviceSyncEpisodeIdentity
    ) async {
        await documentOperationGate.perform { [weak self] in
            guard let self,
                  documentSessionToken == identity.documentSession,
                  selectedEpisodeID != identity.episodeID,
                  let pending = await client.coordinator.integrationAwaitingMaterialization else { return }
            let state = await client.coordinator.state
            guard let context = deviceSyncContext(in: state),
                  context.pendingMaterialization == pending,
                  context.localHead.revisionID == pending.workingRevisionID,
                  let episodeLocation = document.episode(identity.episodeID) else { return }
            let current = episodeLocation.episode.content
            guard context.localHead.contentDigest == SyncContentDigest(content: current) else { return }
            let currentChapterID = episodeLocation.chapterID
            installDeviceSyncEpisodeContent(
                pending.integratedRevision.content,
                chapterID: currentChapterID,
                episodeID: identity.episodeID,
                advancesEditorGeneration: false
            )
            guard document.episode(identity.episodeID)?.episode.content == pending.integratedRevision.content,
                  await saveCoordinator.saveNow(),
                  document.episode(identity.episodeID)?.episode.content == pending.integratedRevision.content else {
                installDeviceSyncEpisodeContent(
                    current,
                    chapterID: currentChapterID,
                    episodeID: identity.episodeID,
                    advancesEditorGeneration: false
                )
                saveCoordinator.markDirty()
                return
            }
            _ = try? await client.coordinator.confirmIntegratedContentMaterialized(
                pending,
                installedContentDigest: pending.integratedRevision.contentDigest
            )
        }
    }

    /// The native editor is frozen by the prepared departure transition here.
    /// Remote integration is never installed from a CloudKit callback while the
    /// surface is active; a stale working revision simply remains journaled.
    func materializeIntegratedDeviceSyncContentIfSafe(
        client: DeviceSyncClient,
        identity: DeviceSyncEpisodeIdentity,
        currentContent: String
    ) async -> Bool {
        guard let pending = await client.coordinator.integrationAwaitingMaterialization else { return true }
        let state = await client.coordinator.state
        guard let context = deviceSyncContext(in: state),
              context.pendingMaterialization == pending,
              context.localHead.revisionID == pending.workingRevisionID,
              context.localHead.contentDigest == SyncContentDigest(content: currentContent),
              document.episode(identity.episodeID)?.episode.content == currentContent,
              deviceSyncContextIsCurrent(identity) else {
            return true
        }

        guard let currentChapterID = document.episode(identity.episodeID)?.chapterID else { return true }
        let integrated = pending.integratedRevision
        installDeviceSyncEpisodeContent(
            integrated.content,
            chapterID: currentChapterID,
            episodeID: identity.episodeID,
            advancesEditorGeneration: false
        )
        guard document.episode(identity.episodeID)?.episode.content == integrated.content,
              await saveCoordinator.saveNow(),
              document.episode(identity.episodeID)?.episode.content == integrated.content else {
            installDeviceSyncEpisodeContent(
                currentContent,
                chapterID: currentChapterID,
                episodeID: identity.episodeID,
                advancesEditorGeneration: false
            )
            saveCoordinator.markDirty()
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
            // The integrated package is already durable. Keep the exact journal
            // marker so a restart can confirm without deleting either parent.
        }
        return true
    }

    private func releaseDeviceSyncAuthorityForBoundary(
        client: DeviceSyncClient,
        identity: DeviceSyncEpisodeIdentity,
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
        expectedSession: DocumentSessionToken? = nil,
        operation: () -> Value
    ) async -> Value? {
        let sourceSession = documentSessionToken
        let sourceChapterID = selectedChapterID
        let sourceEpisodeID = selectedEpisodeID
        if let expectedSession, expectedSession != sourceSession {
            return nil
        }

        return await documentOperationGate.perform { [weak self] in
            guard let self,
                  documentSessionToken == sourceSession,
                  selectedChapterID == sourceChapterID,
                  selectedEpisodeID == sourceEpisodeID,
                  beginDocumentTransition() else { return nil }
            defer { endDocumentTransition() }
            let didFlush = await flushPreparedDeviceSyncBoundarySerially(releaseAuthority: true)
            guard didFlush,
                  documentSessionToken == sourceSession,
                  selectedChapterID == sourceChapterID,
                  selectedEpisodeID == sourceEpisodeID else { return nil }

            permitsDeviceSyncSelectionMutationAfterFlush = true
            defer { permitsDeviceSyncSelectionMutationAfterFlush = false }
            return operation()
        }
    }
}

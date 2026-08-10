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
        let inFlightDraft = deviceSyncDraftTask
        deviceSyncDraftTask = nil
        inFlightDraft?.cancel()
        await inFlightDraft?.value
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

    /// document operation gateとEditor transitionを取得済みの呼び出し専用。
    /// lock順を gate -> editor -> save に固定する。
    @discardableResult
    func flushPreparedDeviceSyncBoundarySerially(releaseAuthority: Bool) async -> Bool {
        guard startupState.isReady, editorCommandSession.isDocumentTransitionPrepared else { return false }
        deviceSyncDraftTask?.cancel()
        deviceSyncDraftTask = nil

        guard let chapterID = selectedChapterID, let episodeID = selectedEpisodeID else {
            saveCoordinator.markDirty()
            return await saveCoordinator.saveNow()
        }
        let content: String
        switch captureCommittedTextForDeviceSync() {
        case let .captured(committed):
            content = committed
            if document.episode(episodeID)?.episode.content != committed {
                installDeviceSyncEpisodeContent(
                    committed,
                    chapterID: chapterID,
                    episodeID: episodeID,
                    advancesEditorGeneration: false
                )
            }
        case .notActive:
            guard let modelContent = document.episode(episodeID)?.episode.content else { return false }
            content = modelContent
        case .compositionInProgress:
            return false
        }

        saveCoordinator.markDirty()
        guard await saveCoordinator.saveNow() else { return false }
        guard let runtime = deviceSyncRuntime,
              let identity = activeDeviceSyncIdentity,
              identity.documentSession == documentSessionToken,
              identity.chapterID == chapterID,
              identity.episodeID == episodeID,
              let client = deviceSyncClient(for: identity) else { return true }

        let initialState = await client.coordinator.state
        if case .synchronizing = initialState {
            // draft publishは同じdocument gateで先にjoinされる。mergeなど
            // gate外の操作が残る場合は、完了前に旧sessionを手放さない。
            return false
        }
        guard ownsDeviceSyncAuthority(in: initialState, client: client, runtime: runtime) else {
            applyDeviceSyncState(initialState, client: client, expectedIdentity: identity)
            return true
        }

        if case .conflict = deviceSyncState {
            return await releaseDeviceSyncAuthorityForBoundary(
                client: client,
                identity: identity,
                releaseAuthority: releaseAuthority
            )
        }
        guard deviceSyncState == .writer || deviceSyncState == .offlineLocal else { return false }

        do {
            let recorded = try await client.coordinator.recordLocalContent(content, createdAt: runtime.now())
            applyDeviceSyncState(recorded, client: client, expectedIdentity: identity)
            let synchronized = try await client.coordinator.synchronize()
            applyDeviceSyncState(synchronized, client: client, expectedIdentity: identity)

            if case .offlineFork = synchronized {
                deviceSyncState = .offlineLocal
                return true
            }
            guard case .upToDate = synchronized else { return false }
            return await releaseDeviceSyncAuthorityForBoundary(
                client: client,
                identity: identity,
                releaseAuthority: releaseAuthority
            )
        } catch EpisodeSyncTransportError.unavailable {
            deviceSyncState = .offlineLocal
            return true
        } catch {
            let current = await client.coordinator.state
            applyDeviceSyncState(current, client: client, expectedIdentity: identity)
            return false
        }
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
        if let expectedSession, expectedSession != sourceSession { return nil }

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

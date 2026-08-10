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
            return document.chapters.first(where: { $0.id == targetChapterID })?.episodes.count == previousCount + 1
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
    func flushDeviceSyncForBackground() async -> Bool {
        // A cancelled CloudKit request may not finish before the background task expires.
        // Commit IME text and the local package first; remote synchronization is best effort.
        let inFlightDraft = deviceSyncDraftTask
        deviceSyncDraftTask = nil
        inFlightDraft?.cancel()
        return await documentOperationGate.perform { [weak self] in
            guard let self, startupState == .ready else { return true }
            guard beginDeviceSyncBoundaryTransition() else { return false }
            defer { endDeviceSyncBoundaryTransition() }
            return await flushPreparedDeviceSyncBoundarySerially(releaseAuthority: false)
        }
    }

    /// iPadのsection/size-class切替でEditorをunmountする前に、本文を永続化して
    /// authorityを解放し、旧UITextView callbackが新surfaceへ届かない世代へ進める。
    @discardableResult
    func prepareForEditorSurfaceDeparture() async -> Bool {
        await documentOperationGate.perform { [weak self] in
            guard let self, startupState == .ready else { return true }
            guard beginDeviceSyncBoundaryTransition() else { return false }
            defer { endDeviceSyncBoundaryTransition() }
            guard await flushPreparedDeviceSyncBoundarySerially(releaseAuthority: true) else { return false }
            advanceEditorContentGeneration()
            deviceSyncSelectionDidChange()
            return true
        }
    }

    @discardableResult
    func flushDeviceSyncBeforeNavigationDeparture(
        _ departure: IOSWorkspaceEditorDeparture
    ) async -> Bool {
        await documentOperationGate.perform { [weak self] in
            guard let self else { return false }
            guard currentDocumentSessionToken == departure.session else { return true }
            let chapterID = departure.chapterID ?? selectedChapterID
            let episodeID = departure.episodeID ?? selectedEpisodeID
            guard chapterID == selectedChapterID, episodeID == selectedEpisodeID else { return true }
            guard beginDeviceSyncBoundaryTransition() else { return false }
            defer { endDeviceSyncBoundaryTransition() }
            return await flushPreparedDeviceSyncBoundarySerially(releaseAuthority: true)
        }
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

            let didFlush = await flushPreparedDeviceSyncBoundarySerially(releaseAuthority: true)
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

    @discardableResult
    func flushPreparedDeviceSyncBoundarySerially(releaseAuthority: Bool) async -> Bool {
        guard startupState == .ready, editorCommandSession.isDocumentTransitionPrepared else { return false }
        deviceSyncDraftTask?.cancel()
        deviceSyncDraftTask = nil

        guard let chapterID = selectedChapterID, let episodeID = selectedEpisodeID else {
            return await saveCoordinator.saveNow()
        }
        let content: String
        switch editorCommandSession.captureActiveCommittedText() {
        case let .captured(committed):
            content = committed
            if document.episode(episodeID)?.episode.content != committed {
                document.updateEpisodeContent(committed, for: episodeID, in: chapterID)
            }
            // `prepareForDocumentTransition()` の同期callbackは、遷移flagを立てた後に
            // modelを最新化する。この間は通常のdirty通知を拒否するため、本文が既に
            // modelと一致していても、取得したUITextViewの全文をpackageへ必ずflushする。
            saveCoordinator.markDirty()
        case .notActive:
            guard let modelContent = document.episode(episodeID)?.episode.content else { return false }
            content = modelContent
            // Editorが既に非表示でも、遷移直前のlifecycle callbackがmodelだけを
            // 最新化してdirty通知を抑止した可能性がある。旧作品を離れる前に
            // modelの確定本文をpackageへ必ず反映する。
            saveCoordinator.markDirty()
        case .compositionInProgress:
            return false
        }

        guard await saveCoordinator.saveNow() else { return false }
        guard let runtime = deviceSyncRuntime,
              let identity = activeDeviceSyncIdentity,
              identity.editingToken.documentSession == currentDocumentSessionToken,
              identity.editingToken.chapterID == chapterID,
              identity.editingToken.episodeID == episodeID,
              let client = deviceSyncClient(for: identity) else { return true }

        let initialState = await client.coordinator.state
        if case .synchronizing = initialState {
            // backgroundではnetwork完了を待たず、最新本文だけを既存sealed publishの
            // tailとしてjournalへ先に退避する。selection departure等は旧sessionの
            // publish完了前にauthorityを手放せないため、従来どおり停止する。
            guard !releaseAuthority else { return false }
            do {
                let recorded = try await client.coordinator.recordLocalContent(
                    content,
                    createdAt: runtime.now()
                )
                applyDeviceSyncState(recorded, client: client, expectedIdentity: identity)
                return true
            } catch {
                let current = await client.coordinator.state
                applyDeviceSyncState(current, client: client, expectedIdentity: identity)
                return false
            }
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

            let didFlush = await flushPreparedDeviceSyncBoundarySerially(releaseAuthority: true)
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

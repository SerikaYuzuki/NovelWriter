import Foundation
import NovelCore

extension Notification.Name {
    static let toggleWritingInspector = Notification.Name("dev.serikayuzuki.fuminiwa.toggleWritingInspector")
    static let presentChapterTitleEditor = Notification.Name("dev.serikayuzuki.fuminiwa.presentChapterTitleEditor")
    static let presentChapterMemo = Notification.Name("dev.serikayuzuki.fuminiwa.presentChapterMemo")
    static let presentAttachmentImporter = Notification.Name("dev.serikayuzuki.fuminiwa.presentAttachmentImporter")
    static let presentSnapshotSyncConflict = Notification.Name("dev.serikayuzuki.fuminiwa.presentSnapshotSyncConflict")
}

/// macOSの作品操作をv2のWorkID sessionとDocumentOperationGateへ集約する。
///
/// ここではパッケージURLを通常保存のidentityにしない。パッケージcodecを呼ぶのは
/// 明示的な取り込み／書き出しだけで、編集・選択・自動保存はSQLite checkpointへ
/// 委譲する。
extension AppState {
    var supportsAttachments: Bool {
        snapshotSyncV2Application != nil
    }

    func flushSaveImmediately() {
        Task { @MainActor [weak self] in
            _ = await self?.saveNow()
        }
    }

    func permitsEditorSynchronization(expectedSession: DocumentSessionToken?) -> Bool {
        permitsDocumentInteraction && (expectedSession == nil || expectedSession == documentSessionToken)
    }

    func permitsMutation(expectedSession: DocumentSessionToken?) -> Bool {
        permitsEditorSynchronization(expectedSession: expectedSession)
    }

    func setSelection(chapterID: ChapterID?, episodeID: EpisodeID?) {
        selectedChapterID = chapterID
        selectedEpisodeID = episodeID
        if let chapterID {
            plotOutlineSelection = .chapter(chapterID)
        } else {
            plotOutlineSelection = .unassigned
        }
    }

    func preferredEpisodeID(in chapterID: ChapterID) -> EpisodeID? {
        document.chapters.first(where: { $0.id == chapterID })?.episodes.first?.id
    }

    func normalizedChapterTitle(_ title: String) -> String {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "無題の章" : trimmed
    }

    func normalizedEpisodeTitle(_ title: String) -> String {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "無題の話" : trimmed
    }

    static func nilIfBlank(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    func selectProjectSectionAfterTransition(_ section: ProjectSection) async -> Bool {
        await documentOperationGate.perform { [weak self] in
            guard let self,
                  editorCommandSession.prepareForDocumentTransition() else { return false }
            defer { editorCommandSession.resumeAfterDocumentTransition() }
            isDocumentTransitionInProgress = true
            defer { isDocumentTransitionInProgress = false }
            workspaceSelection = WorkspaceSelection(section: section)
            if section == .worldbuilding {
                ensureWorldNoteSelection()
            }
            return await saveNow()
        }
    }

    func selectEpisodeAfterTransition(_ episodeID: EpisodeID, in chapterID: ChapterID) async -> Bool {
        await documentOperationGate.perform { [weak self] in
            guard let self,
                  editorCommandSession.prepareForDocumentTransition() else { return false }
            defer { editorCommandSession.resumeAfterDocumentTransition() }
            isDocumentTransitionInProgress = true
            defer { isDocumentTransitionInProgress = false }
            guard document.chapters.contains(where: { chapter in
                chapter.id == chapterID && chapter.episodes.contains(where: { $0.id == episodeID })
            }) else { return false }
            selectedChapterID = chapterID
            selectedEpisodeID = episodeID
            plotOutlineSelection = .chapter(chapterID)
            return await saveNow()
        }
    }

    func selectChapterAfterTransition(_ chapterID: ChapterID) async -> Bool {
        await documentOperationGate.perform { [weak self] in
            guard let self,
                  editorCommandSession.prepareForDocumentTransition() else { return false }
            defer { editorCommandSession.resumeAfterDocumentTransition() }
            isDocumentTransitionInProgress = true
            defer { isDocumentTransitionInProgress = false }
            guard document.chapters.contains(where: { $0.id == chapterID }) else { return false }
            selectedChapterID = chapterID
            selectedEpisodeID = preferredEpisodeID(in: chapterID)
            plotOutlineSelection = .chapter(chapterID)
            return await saveNow()
        }
    }

    func addChapterAfterTransition() async -> Bool {
        guard permitsDocumentChoice else { return false }
        return await documentOperationGate.perform { [weak self] in
            guard let self,
                  editorCommandSession.prepareForDocumentTransition() else { return false }
            defer { editorCommandSession.resumeAfterDocumentTransition() }
            isDocumentTransitionInProgress = true
            defer { isDocumentTransitionInProgress = false }
            let title = "第\(document.chapters.count + 1)章"
            let chapterID = document.addChapter(title: title)
            setSelection(chapterID: chapterID, episodeID: nil)
            saveCoordinator.markDirty()
            return await saveNow()
        }
    }

    func addEpisodeAfterTransition(to chapterID: ChapterID? = nil) async -> Bool {
        guard permitsDocumentChoice else { return false }
        return await documentOperationGate.perform { [weak self] in
            guard let self,
                  editorCommandSession.prepareForDocumentTransition() else { return false }
            defer { editorCommandSession.resumeAfterDocumentTransition() }
            isDocumentTransitionInProgress = true
            defer { isDocumentTransitionInProgress = false }
            let targetChapterID = chapterID ?? selectedChapterID
            guard let targetChapterID,
                  let chapter = document.chapters.first(where: { $0.id == targetChapterID }) else {
                return false
            }
            let title = "第\(chapter.episodes.count + 1)話"
            guard let episodeID = document.addEpisode(to: targetChapterID, title: title) else {
                return false
            }
            setSelection(chapterID: targetChapterID, episodeID: episodeID)
            saveCoordinator.markDirty()
            return await saveNow()
        }
    }

    func deleteChapterAfterTransition(
        id: ChapterID,
        expectedSession: DocumentSessionToken
    ) async -> Bool {
        guard documentSessionToken == expectedSession else { return false }
        return await documentOperationGate.perform { [weak self] in
            guard let self,
                  editorCommandSession.prepareForDocumentTransition() else { return false }
            defer { editorCommandSession.resumeAfterDocumentTransition() }
            isDocumentTransitionInProgress = true
            defer { isDocumentTransitionInProgress = false }
            guard document.chapters.count > 1,
                  let originalIndex = document.chapters.firstIndex(where: { $0.id == id }),
                  document.removeChapter(id: id) != nil else { return false }
            if selectedChapterID == id {
                let fallbackIndex = min(originalIndex, document.chapters.count - 1)
                let fallbackID = document.chapters.indices.contains(fallbackIndex)
                    ? document.chapters[fallbackIndex].id
                    : nil
                setSelection(chapterID: fallbackID, episodeID: fallbackID.flatMap(preferredEpisodeID(in:)))
            }
            if case let .chapter(focusedID) = plotOutlineSelection, focusedID == id {
                plotOutlineSelection = selectedChapterID.map { .chapter($0) } ?? .unassigned
            }
            saveCoordinator.markDirty()
            return await saveNow()
        }
    }

    func deleteEpisodeAfterTransition(
        id: EpisodeID,
        from chapterID: ChapterID,
        expectedSession: DocumentSessionToken
    ) async -> Bool {
        guard documentSessionToken == expectedSession else { return false }
        return await documentOperationGate.perform { [weak self] in
            guard let self,
                  editorCommandSession.prepareForDocumentTransition() else { return false }
            defer { editorCommandSession.resumeAfterDocumentTransition() }
            isDocumentTransitionInProgress = true
            defer { isDocumentTransitionInProgress = false }
            guard let sourceChapter = document.chapters.first(where: { $0.id == chapterID }),
                  let originalIndex = sourceChapter.episodes.firstIndex(where: { $0.id == id }),
                  document.removeEpisode(id: id, from: chapterID) != nil else { return false }
            if selectedEpisodeID == id {
                let remaining = document.chapters.first(where: { $0.id == chapterID })?.episodes ?? []
                let fallbackIndex = min(originalIndex, max(remaining.count - 1, 0))
                let fallbackID = remaining.indices.contains(fallbackIndex) ? remaining[fallbackIndex].id : nil
                setSelection(chapterID: chapterID, episodeID: fallbackID)
            }
            saveCoordinator.markDirty()
            return await saveNow()
        }
    }

    func moveChaptersAfterTransition(fromOffsets: IndexSet, toOffset: Int) async {
        guard permitsDocumentInteraction else { return }
        moveChapters(fromOffsets: fromOffsets, toOffset: toOffset)
        _ = await saveNow()
    }

    func moveEpisodesAfterTransition(
        in chapterID: ChapterID,
        fromOffsets: IndexSet,
        toOffset: Int
    ) async {
        guard permitsDocumentInteraction else { return }
        moveEpisodes(in: chapterID, fromOffsets: fromOffsets, toOffset: toOffset)
        _ = await saveNow()
    }

    func moveEpisodeAfterTransition(
        id episodeID: EpisodeID,
        from sourceChapterID: ChapterID,
        to destinationChapterID: ChapterID,
        before targetEpisodeID: EpisodeID? = nil
    ) async -> Bool {
        guard permitsDocumentInteraction,
              moveEpisode(
                  id: episodeID,
                  from: sourceChapterID,
                  to: destinationChapterID,
                  before: targetEpisodeID
              ) else { return false }
        return await saveNow()
    }

    func selectPlotOutlineAfterTransition(_ selection: PlotOutlineSelection) async {
        guard permitsDocumentInteraction else { return }
        selectPlotOutline(selection)
        _ = await saveNow()
    }

    func movePlotCardFromOutlineAfterTransition(
        id: PlotCardID,
        to selection: PlotOutlineSelection
    ) async -> Bool {
        guard permitsDocumentInteraction,
              movePlotCardFromOutline(id: id, to: selection) else { return false }
        return await saveNow()
    }

    func createNewDocument(expectedSession: DocumentSessionToken? = nil) async -> Bool {
        guard expectedSession == nil || expectedSession == documentSessionToken else { return false }
        await createNewV2Document()
        return true
    }

    func openDocument(at url: URL, expectedSession: DocumentSessionToken? = nil) async -> Bool {
        guard expectedSession == nil || expectedSession == documentSessionToken else { return false }
        return await openExternalDocument(at: url)
    }

    func importExternalDocument(at url: URL, expectedSession: DocumentSessionToken? = nil) async -> Bool {
        await openDocument(at: url, expectedSession: expectedSession)
    }

    func exportDocumentPackage(
        to destination: URL,
        expectedSession: DocumentSessionToken? = nil
    ) async throws {
        guard permitsDocumentInteraction,
              expectedSession == nil || expectedSession == documentSessionToken else {
            throw CancellationError()
        }
        guard await saveNow() else { throw CancellationError() }
        try await portableBridge.exportExplicitPackage(
            document: document,
            attachments: snapshotSyncV2Attachments,
            documentCreatedAt: snapshotSyncV2DocumentCreatedAt.map(Self.normalizedSnapshotSyncV2Date),
            resources: snapshotSyncV2Resources,
            to: destination
        )
    }
}

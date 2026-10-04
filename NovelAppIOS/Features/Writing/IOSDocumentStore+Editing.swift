import Foundation
import NovelCore
import NovelWorkspace

/// 執筆画面からの選択・作品編集を、起動と保存のcomposition rootから分離する。
/// すべての操作は従来どおり`markDocumentChanged()`へ集約し、保存・同期境界は変えない。
extension IOSDocumentStore {
    var selectedChapter: Chapter? {
        guard let selectedChapterID else { return nil }
        return document.chapters.first(where: { $0.id == selectedChapterID })
    }

    var selectedEpisode: Episode? {
        guard let selectedChapter, let selectedEpisodeID else { return nil }
        return selectedChapter.episodes.first(where: { $0.id == selectedEpisodeID })
    }

    func selectChapter(_ chapterID: ChapterID?) {
        _ = OutlineCommands(host: self).selectChapter(chapterID, preservingEpisode: true)
    }

    func selectEpisode(_ episodeID: EpisodeID?) {
        guard selectedEpisodeID != episodeID, let chapterID = selectedChapterID else { return }
        _ = OutlineCommands(host: self).selectEpisode(episodeID, in: chapterID, validate: false)
    }

    func updateDocumentTitle(_ title: String) {
        guard permitsSyncSelectionMutation,
              document.title != title else { return }
        document.title = title
        markDocumentChanged()
    }

    func updateDocumentSynopsis(_ synopsis: String) {
        guard permitsSyncSelectionMutation,
              document.synopsis != synopsis else { return }
        document.synopsis = synopsis
        markDocumentChanged()
    }

    func updateChapterTitle(_ title: String, chapterID: ChapterID) {
        OutlineCommands(host: self).renameChapter(title, id: chapterID)
    }

    func updateEpisodeTitle(
        _ title: String, chapterID: ChapterID, episodeID: EpisodeID,
        expectedSession: WorkspaceSessionToken? = nil,
        expectedAccountScope: WorkspaceAccountScope? = nil
    ) {
        OutlineCommands(host: self).renameEpisode(title, id: episodeID, in: chapterID,
                                                  expectedSession: expectedSession, expectedAccount: expectedAccountScope)
    }

    func updateEpisodeContent(
        _ content: String,
        chapterID: ChapterID,
        episodeID: EpisodeID,
        expectedEditingToken: IOSEpisodeEditingToken? = nil
    ) {
        guard permitsSyncSelectionMutation else { return }
        if let expectedEditingToken {
            guard currentEpisodeEditingToken == expectedEditingToken else { return }
        }
        guard selectedChapterID == chapterID, selectedEpisodeID == episodeID else { return }
        guard let previousContent = document.episode(episodeID)?.episode.content,
              previousContent != content else { return }
        if let workID = syncV2ActiveWorkID {
            writingProgress.manualChange(document: document, workID: workID.rawValue, episodeID: episodeID, content: content, previousContent: previousContent)
        }
        if let application = snapshotSyncV2Application, let workID = syncV2ActiveWorkID {
            Task { await application.recordBodyEdit(workID: workID) }
        }
        document.updateEpisodeContent(content, for: episodeID, in: chapterID)
        markDocumentChanged(progressAlreadyTracked: true)
    }

    func addChapter() {
        _ = OutlineCommands(host: self).addChapter(includingFirstEpisode: true)
    }

    func addEpisode() {
        _ = OutlineCommands(host: self).addEpisode(to: selectedChapterID, firstTitle: Episode.defaultTitle)
    }

    func deleteEpisodes(at offsets: IndexSet, chapterID: ChapterID) {
        guard let chapter = document.chapters.first(where: { $0.id == chapterID }) else { return }
        let ids = Set(offsets.compactMap { chapter.episodes.indices.contains($0) ? chapter.episodes[$0].id : nil })
        _ = OutlineCommands(host: self).deleteEpisodes(ids, in: chapterID, repair: .first)
    }

    func moveChapters(fromOffsets: IndexSet, toOffset: Int) {
        OutlineCommands(host: self).moveChapters(fromOffsets: fromOffsets, toOffset: toOffset)
    }

    func moveEpisodes(in chapterID: ChapterID, fromOffsets: IndexSet, toOffset: Int) {
        OutlineCommands(host: self).moveEpisodes(in: chapterID, fromOffsets: fromOffsets, toOffset: toOffset)
    }

    func updateEpisodeMemo(_ memo: String, chapterID: ChapterID, episodeID: EpisodeID) {
        guard permitsSyncSelectionMutation,
              document.episode(episodeID)?.episode.memo != memo else { return }
        document.updateEpisodeMemo(memo, for: episodeID, in: chapterID)
        markDocumentChanged()
    }

    private var permitsSyncSelectionMutation: Bool {
        startupState == .ready
            && syncV2ActiveWorkID != nil
            && !isDocumentTransitionInProgress
            && !syncV2AccountTransitionInProgress
            && syncV2KeepBothPendingWorkID == nil
    }
}

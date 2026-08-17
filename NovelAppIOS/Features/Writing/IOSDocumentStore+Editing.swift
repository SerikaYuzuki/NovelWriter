import Foundation
import NovelCore

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
        guard chapterID == selectedChapterID || permitsSyncSelectionMutation else { return }
        selectedChapterID = chapterID
        guard let chapterID else {
            selectedEpisodeID = nil
            return
        }
        let chapter = document.chapters.first(where: { $0.id == chapterID })
        guard let chapter else {
            selectedEpisodeID = nil
            return
        }
        if !chapter.episodes.contains(where: { $0.id == selectedEpisodeID }) {
            selectedEpisodeID = chapter.episodes.first?.id
        }
    }

    func selectEpisode(_ episodeID: EpisodeID?) {
        guard selectedEpisodeID != episodeID else { return }
        guard permitsSyncSelectionMutation else { return }
        selectedEpisodeID = episodeID
    }

    func updateDocumentTitle(_ title: String) {
        guard document.title != title else { return }
        document.title = title
        markDocumentChanged()
    }

    func updateDocumentSynopsis(_ synopsis: String) {
        guard document.synopsis != synopsis else { return }
        document.synopsis = synopsis
        markDocumentChanged()
    }

    func updateChapterTitle(_ title: String, chapterID: ChapterID) {
        guard document.chapters.first(where: { $0.id == chapterID })?.title != title else { return }
        document.updateTitle(title, for: chapterID)
        markDocumentChanged()
    }

    func updateEpisodeTitle(_ title: String, chapterID: ChapterID, episodeID: EpisodeID) {
        guard document.episode(episodeID)?.episode.title != title else { return }
        document.updateEpisodeTitle(title, for: episodeID, in: chapterID)
        markDocumentChanged()
    }

    func updateEpisodeContent(
        _ content: String,
        chapterID: ChapterID,
        episodeID: EpisodeID,
        expectedEditingToken: IOSEpisodeEditingToken? = nil
    ) {
        if let expectedEditingToken {
            guard currentEpisodeEditingToken == expectedEditingToken else { return }
        }
        guard selectedChapterID == chapterID, selectedEpisodeID == episodeID else { return }
        guard let previousContent = document.episode(episodeID)?.episode.content,
              previousContent != content else { return }
        document.updateEpisodeContent(content, for: episodeID, in: chapterID)
        markDocumentChanged()
    }

    func addChapter() {
        guard permitsSyncSelectionMutation else { return }
        let number = document.chapters.count + 1
        let chapterID = document.addChapter(title: "第\(number)章")
        let episodeID = document.addEpisode(to: chapterID)
        selectedChapterID = chapterID
        selectedEpisodeID = episodeID
        markDocumentChanged()
    }

    func addEpisode() {
        guard permitsSyncSelectionMutation else { return }
        guard let selectedChapterID else { return }
        let count = selectedChapter?.episodes.count ?? 0
        let title = count == 0 ? Episode.defaultTitle : "第\(count + 1)話"
        let previousEpisodeID = selectedEpisodeID
        selectedEpisodeID = document.addEpisode(to: selectedChapterID, title: title)
        if selectedEpisodeID != previousEpisodeID {}
        markDocumentChanged()
    }

    func deleteEpisodes(at offsets: IndexSet, chapterID: ChapterID) {
        guard let chapter = document.chapters.first(where: { $0.id == chapterID }) else { return }
        let removedIDs = offsets.compactMap { chapter.episodes.indices.contains($0) ? chapter.episodes[$0].id : nil }
        if removedIDs.contains(where: { $0 == selectedEpisodeID }) {
            guard permitsSyncSelectionMutation else { return }
        }
        for episodeID in removedIDs {
            _ = document.removeEpisode(id: episodeID, from: chapterID)
        }
        if removedIDs.contains(where: { $0 == selectedEpisodeID }) {
            selectedEpisodeID = document.chapters
                .first(where: { $0.id == chapterID })?
                .episodes.first?.id
        }
        markDocumentChanged()
    }

    func moveChapters(fromOffsets: IndexSet, toOffset: Int) {
        document.moveChapters(fromOffsets: fromOffsets, toOffset: toOffset)
        markDocumentChanged()
    }

    func moveEpisodes(in chapterID: ChapterID, fromOffsets: IndexSet, toOffset: Int) {
        document.moveEpisodes(in: chapterID, fromOffsets: fromOffsets, toOffset: toOffset)
        markDocumentChanged()
    }

    func updateEpisodeMemo(_ memo: String, chapterID: ChapterID, episodeID: EpisodeID) {
        guard document.episode(episodeID)?.episode.memo != memo else { return }
        document.updateEpisodeMemo(memo, for: episodeID, in: chapterID)
        markDocumentChanged()
    }

    private var permitsSyncSelectionMutation: Bool {
        true
    }
}

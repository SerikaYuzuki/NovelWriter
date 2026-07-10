import Foundation

/// `NovelDocument` に対する話の追加・編集・並べ替え操作。
///
/// 章をまたぐ移動を含む話の順序変更をCoreに閉じ込め、AppStateと将来のUIが
/// 保存形式や配列操作の細部を持たないようにする。
public extension NovelDocument {
    /// 指定した章の末尾に空の話を追加する。
    @discardableResult
    mutating func addEpisode(to chapterID: ChapterID, title: String = Episode.defaultTitle) -> EpisodeID? {
        guard let chapterIndex = chapters.firstIndex(where: { $0.id == chapterID }) else { return nil }
        let episode = Episode(title: title)
        chapters[chapterIndex].episodes.append(episode)
        return episode.id
    }

    /// 指定した話のタイトルを更新する。
    mutating func updateEpisodeTitle(_ title: String, for episodeID: EpisodeID, in chapterID: ChapterID) {
        guard let chapterIndex = chapterIndex(for: chapterID) else { return }
        guard let episodeIndex = chapters[chapterIndex].episodes.firstIndex(where: { $0.id == episodeID }) else {
            return
        }
        chapters[chapterIndex].episodes[episodeIndex].title = title
    }

    /// 指定した話の本文を更新する。
    mutating func updateEpisodeContent(_ content: String, for episodeID: EpisodeID, in chapterID: ChapterID) {
        guard let chapterIndex = chapterIndex(for: chapterID) else { return }
        guard let episodeIndex = chapters[chapterIndex].episodes.firstIndex(where: { $0.id == episodeID }) else {
            return
        }
        chapters[chapterIndex].episodes[episodeIndex].content = content
    }

    /// 指定した話のメモを更新する。
    mutating func updateEpisodeMemo(_ memo: String, for episodeID: EpisodeID, in chapterID: ChapterID) {
        guard let chapterIndex = chapterIndex(for: chapterID) else { return }
        guard let episodeIndex = chapters[chapterIndex].episodes.firstIndex(where: { $0.id == episodeID }) else {
            return
        }
        chapters[chapterIndex].episodes[episodeIndex].memo = memo
    }

    /// 指定した話を削除し、元の位置を返す。
    @discardableResult
    mutating func removeEpisode(id episodeID: EpisodeID, from chapterID: ChapterID) -> (episode: Episode, index: Int)? {
        guard let chapterIndex = chapterIndex(for: chapterID) else { return nil }
        guard let episodeIndex = chapters[chapterIndex].episodes.firstIndex(where: { $0.id == episodeID }) else {
            return nil
        }
        return (chapters[chapterIndex].episodes.remove(at: episodeIndex), episodeIndex)
    }

    /// 章内の話を並べ替える。
    mutating func moveEpisodes(in chapterID: ChapterID, fromOffsets: IndexSet, toOffset: Int) {
        guard let chapterIndex = chapterIndex(for: chapterID) else { return }
        let episodes = chapters[chapterIndex].episodes
        guard fromOffsets.allSatisfy({ episodes.indices.contains($0) }),
              episodes.indices.contains(toOffset) || toOffset == episodes.count else
        {
            return
        }

        let itemsToMove = fromOffsets.map { episodes[$0] }
        for index in fromOffsets.sorted(by: >) {
            chapters[chapterIndex].episodes.remove(at: index)
        }
        let removedBeforeDestination = fromOffsets.count(where: { $0 < toOffset })
        let adjustedDestination = toOffset - removedBeforeDestination
        chapters[chapterIndex].episodes.insert(contentsOf: itemsToMove, at: adjustedDestination)
    }

    /// 話を同じ章内または別章へ移動する。`before` が nil の場合は末尾へ追加する。
    @discardableResult
    mutating func moveEpisode(
        id episodeID: EpisodeID,
        from sourceChapterID: ChapterID,
        to destinationChapterID: ChapterID,
        before targetEpisodeID: EpisodeID? = nil
    ) -> Bool {
        guard let sourceChapterIndex = chapterIndex(for: sourceChapterID) else { return false }
        guard let sourceEpisodeIndex = chapters[sourceChapterIndex].episodes.firstIndex(where: { $0.id == episodeID }) else {
            return false
        }
        guard chapterIndex(for: destinationChapterID) != nil else {
            return false
        }
        if let targetEpisodeID, targetEpisodeID == episodeID {
            return false
        }

        let episode = chapters[sourceChapterIndex].episodes.remove(at: sourceEpisodeIndex)
        guard let destinationChapterIndex = chapterIndex(for: destinationChapterID) else { return false }

        let destinationIndex: Int = if let targetEpisodeID,
                                       let targetIndex = chapters[destinationChapterIndex].episodes.firstIndex(where: { $0.id == targetEpisodeID })
        {
            targetIndex
        } else {
            chapters[destinationChapterIndex].episodes.count
        }
        chapters[destinationChapterIndex].episodes.insert(episode, at: destinationIndex)
        return true
    }

    /// 話IDから所属章と話を探す。
    func episode(_ episodeID: EpisodeID) -> (chapterID: ChapterID, episode: Episode)? {
        for chapter in chapters {
            if let episode = chapter.episodes.first(where: { $0.id == episodeID }) {
                return (chapter.id, episode)
            }
        }
        return nil
    }

    private func chapterIndex(for chapterID: ChapterID) -> Int? {
        chapters.firstIndex(where: { $0.id == chapterID })
    }
}

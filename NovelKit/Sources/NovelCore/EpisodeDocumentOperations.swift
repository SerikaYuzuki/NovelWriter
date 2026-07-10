import Foundation

/// `NovelDocument` に対する話の追加・編集・並べ替え操作。
public extension NovelDocument {
    /// 指定した章の末尾に空の話を追加する。
    @discardableResult
    mutating func addEpisode(to chapterID: ChapterID, title: String = Episode.defaultTitle) -> EpisodeID? {
        guard let chapterIndex = chapters.firstIndex(where: { $0.id == chapterID }) else { return nil }
        let episode = Episode(title: title)
        chapters[chapterIndex].episodes.append(episode)
        return episode.id
    }

    /// 話のメタデータを更新する。
    mutating func updateEpisodeTitle(_ title: String, for episodeID: EpisodeID, in chapterID: ChapterID) {
        guard let chapterIndex = chapters.firstIndex(where: { $0.id == chapterID }) else { return }
        guard let episodeIndex = chapters[chapterIndex].episodes.firstIndex(where: { $0.id == episodeID }) else {
            return
        }
        chapters[chapterIndex].episodes[episodeIndex].title = title
    }

    /// 話の本文を更新する。
    mutating func updateEpisodeContent(_ content: String, for episodeID: EpisodeID, in chapterID: ChapterID) {
        guard let chapterIndex = chapters.firstIndex(where: { $0.id == chapterID }) else { return }
        guard let episodeIndex = chapters[chapterIndex].episodes.firstIndex(where: { $0.id == episodeID }) else {
            return
        }
        chapters[chapterIndex].episodes[episodeIndex].content = content
    }

    /// 話のメモを更新する。
    mutating func updateEpisodeMemo(_ memo: String, for episodeID: EpisodeID, in chapterID: ChapterID) {
        guard let chapterIndex = chapters.firstIndex(where: { $0.id == chapterID }) else { return }
        guard let episodeIndex = chapters[chapterIndex].episodes.firstIndex(where: { $0.id == episodeID }) else {
            return
        }
        chapters[chapterIndex].episodes[episodeIndex].memo = memo
    }

    /// 指定した話を削除し、元の位置を返す。
    @discardableResult
    mutating func removeEpisode(id episodeID: EpisodeID, from chapterID: ChapterID) -> (episode: Episode, index: Int)? {
        guard let chapterIndex = chapters.firstIndex(where: { $0.id == chapterID }) else { return nil }
        guard let episodeIndex = chapters[chapterIndex].episodes.firstIndex(where: { $0.id == episodeID }) else {
            return nil
        }
        return (chapters[chapterIndex].episodes.remove(at: episodeIndex), episodeIndex)
    }

    /// 章内の話を並べ替える。
    mutating func moveEpisodes(in chapterID: ChapterID, fromOffsets: IndexSet, toOffset: Int) {
        guard let chapterIndex = chapters.firstIndex(where: { $0.id == chapterID }) else { return }
        let episodes = chapters[chapterIndex].episodes
        let validDestination = episodes.indices.contains(toOffset) || toOffset == episodes.count
        guard fromOffsets.allSatisfy({ episodes.indices.contains($0) }), validDestination else { return }

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
        guard let sourceChapterIndex = chapters.firstIndex(where: { $0.id == sourceChapterID }) else { return false }
        let sourceEpisodes = chapters[sourceChapterIndex].episodes
        guard let sourceEpisodeIndex = sourceEpisodes.firstIndex(where: { $0.id == episodeID }) else {
            return false
        }
        guard let destinationChapterIndex = chapters.firstIndex(where: { $0.id == destinationChapterID }) else {
            return false
        }
        guard targetEpisodeID != episodeID else { return false }

        let episode = chapters[sourceChapterIndex].episodes.remove(at: sourceEpisodeIndex)
        let destinationIndex = targetEpisodeID.flatMap { targetID in
            chapters[destinationChapterIndex].episodes.firstIndex(where: { $0.id == targetID })
        } ?? chapters[destinationChapterIndex].episodes.count
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
}

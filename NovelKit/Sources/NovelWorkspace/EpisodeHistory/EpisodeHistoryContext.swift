import NovelCore

public struct EpisodeHistoryContext {
    public let chapterID: ChapterID
    public let episodeID: EpisodeID
    public let heading: String

    public init?(document: NovelDocument, episodeID: EpisodeID?) {
        guard let episodeID, let found = document.episode(episodeID),
              let index = document.chapters.flatMap(\.episodes).firstIndex(where: { $0.id == episodeID }) else { return nil }
        chapterID = found.chapterID
        self.episodeID = episodeID
        heading = "第\(index + 1)話「\(found.episode.title)」"
    }
}

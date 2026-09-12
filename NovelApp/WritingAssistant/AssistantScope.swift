import Foundation
import NovelCore

/// Scope identifiers stay local; only explicitly selected titles and text are sent.
enum AssistantScope: Hashable {
    case current
    case chapter(ChapterID)
    case episode(EpisodeID)

    func capture(chapters: [Chapter], currentID: EpisodeID?, current: () throws -> AssistantManuscript) throws -> AssistantManuscript {
        switch self {
        case .current: return try current()
        case let .episode(id):
            guard let episode = chapters.flatMap(\.episodes).first(where: { $0.id == id }) else { throw AssistantError.emptyContent }
            return try text(episode, currentID: currentID, current: current)
        case let .chapter(id):
            guard let chapter = chapters.first(where: { $0.id == id }), !chapter.episodes.isEmpty else { throw AssistantError.emptyContent }
            let episodes = try chapter.episodes.map { try text($0, currentID: currentID, current: current) }
            guard episodes.contains(where: { !$0.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) else { throw AssistantError.emptyContent }
            return AssistantManuscript(title: chapter.title, content: episodes.map { "# \($0.title)\n\($0.content)" }.joined(separator: "\n\n"))
        }
    }

    private func text(_ episode: Episode, currentID: EpisodeID?, current: () throws -> AssistantManuscript) throws -> AssistantManuscript {
        if episode.id == currentID {
            return try current()
        }
        return AssistantManuscript(title: episode.title, content: episode.content)
    }
}

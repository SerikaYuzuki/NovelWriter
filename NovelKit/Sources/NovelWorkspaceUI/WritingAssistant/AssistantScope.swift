import Foundation
import NovelCore

/// Scope identifiers stay local; only explicitly selected titles and text are sent.
public enum AssistantScope: Hashable {
    case current
    case chapter(ChapterID)
    case episode(EpisodeID)
    case episodes(Set<EpisodeID>)

    public func forPurpose(_ purpose: AssistantPurpose) -> AssistantScope {
        purpose == .proofreading ? .current : self
    }

    public func selectedEpisodeIDs(chapters: [Chapter], currentID: EpisodeID?) -> Set<EpisodeID> {
        switch self {
        case .current: Set(currentID.map { [$0] } ?? [])
        case let .chapter(id): Set(chapters.first(where: { $0.id == id })?.episodes.map(\.id) ?? [])
        case let .episode(id): [id]
        case let .episodes(ids): ids
        }
    }

    public mutating func setSelected(_ ids: Set<EpisodeID>, to selected: Bool, chapters: [Chapter], currentID: EpisodeID?) {
        var result = selectedEpisodeIDs(chapters: chapters, currentID: currentID)
        if selected {
            result.formUnion(ids)
        } else {
            result.subtract(ids)
        }
        self = currentID.map { result == [$0] } == true ? .current : .episodes(result)
    }

    public func capture(chapters: [Chapter], currentID: EpisodeID?, current: () throws -> AssistantManuscript) throws -> AssistantManuscript {
        switch self {
        case let .episodes(ids):
            return try captureSelection(ids, chapters: chapters, currentID: currentID, current: current)
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

    private func captureSelection(
        _ ids: Set<EpisodeID>, chapters: [Chapter], currentID: EpisodeID?,
        current: () throws -> AssistantManuscript
    ) throws -> AssistantManuscript {
        let groups = chapters.compactMap { chapter -> (Chapter, [Episode])? in
            let selected = chapter.episodes.filter { ids.contains($0.id) }
            return selected.isEmpty ? nil : (chapter, selected)
        }
        guard !ids.isEmpty, groups.reduce(0, { $0 + $1.1.count }) == ids.count else { throw AssistantError.emptyContent }
        if ids.count == 1, let episode = groups.first?.1.first {
            return try text(episode, currentID: currentID, current: current)
        }
        var hasContent = false
        let content = try groups.map { chapter, episodes in
            let manuscripts = try episodes.map { try text($0, currentID: currentID, current: current) }
            hasContent = hasContent || manuscripts.contains { !$0.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            return "# \(chapter.title)\n\n" + manuscripts.map { "## \($0.title)\n\($0.content)" }.joined(separator: "\n\n")
        }.joined(separator: "\n\n")
        guard hasContent else { throw AssistantError.emptyContent }
        return AssistantManuscript(title: "選択した\(ids.count)話", content: content)
    }

    private func text(_ episode: Episode, currentID: EpisodeID?, current: () throws -> AssistantManuscript) throws -> AssistantManuscript {
        if episode.id == currentID {
            return try current()
        }
        return AssistantManuscript(title: episode.title, content: episode.content)
    }
}

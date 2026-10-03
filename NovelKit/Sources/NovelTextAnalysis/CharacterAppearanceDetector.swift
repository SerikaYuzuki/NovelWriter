import Foundation
import NovelCore

public struct CharacterAppearance: Identifiable, Equatable, Sendable {
    public let chapterID: ChapterID
    public let episodeID: EpisodeID
    public let chapterTitle: String
    public let episodeTitle: String
    public let source: String
    public let query: String
    public let range: NSRange
    public let count: Int
    public var id: EpisodeID {
        episodeID
    }
}

public enum CharacterAppearanceDetector {
    public static func appearances(for character: NovelCore.Character,
                                   in document: NovelDocument) -> [CharacterAppearance] {
        document.chapters.flatMap { chapter in
            chapter.episodes.flatMap { appearances(
                for: character,
                in: $0,
                chapterID: chapter.id,
                chapterTitle: chapter.title
            ) }
        }
    }

    public static func appearances(for character: NovelCore.Character, in episode: Episode,
                                   chapterID: ChapterID, chapterTitle: String) -> [CharacterAppearance] {
        var seen: Set<String> = []
        let queries = [
            NovelDocument.normalizedCharacterName(character.name),
            character.kana.trimmingCharacters(in: .whitespacesAndNewlines)
        ]
        .filter { !$0.isEmpty && seen.insert($0).inserted }
        let matches = queries.flatMap { query in WorkTextSearch.ranges(query: query, in: episode.content).map { (
            query,
            $0
        ) } }
        // 同じ場所の名前／読みは一度だけ数える。部分的な重なりも一つの登場として扱う。
        let ordered = matches
            .sorted { $0.1.location == $1.1.location ? $0.1.length > $1.1.length : $0.1.location < $1.1.location }
        var unique: [(String, NSRange)] = []
        for match in ordered {
            if let last = unique.last, NSMaxRange(last.1) > match.1.location {
                continue
            }
            unique.append(match)
        }
        guard let first = unique.first else { return [] }
        return [CharacterAppearance(chapterID: chapterID, episodeID: episode.id, chapterTitle: chapterTitle,
                                    episodeTitle: episode.title, source: episode.content, query: first.0,
                                    range: first.1,
                                    count: unique.count)]
    }

    public static func summary(_ appearances: [CharacterAppearance]) -> String {
        guard let first = appearances.first, let last = appearances.last else { return "本文にまだ登場していません" }
        return "登場 \(appearances.count)話 · 最初 \(first.chapterTitle) \(first.episodeTitle) · 最後 \(last.chapterTitle) \(last.episodeTitle)"
    }
}

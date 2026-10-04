import Foundation
import NovelCore

public struct WorkTextMatch: Identifiable, Equatable, Sendable {
    public let range: NSRange
    public let context: String
    public var id: Int {
        range.location
    }
}

public struct EpisodeTextMatches: Identifiable, Equatable, Sendable {
    public let chapterID: ChapterID
    public let episodeID: EpisodeID
    public let chapterTitle: String
    public let episodeTitle: String
    public let source: String
    public let matches: [WorkTextMatch]
    public var id: EpisodeID {
        episodeID
    }
}

public struct EpisodeTextChange: Equatable, Sendable {
    public let chapterID: ChapterID
    public let episodeID: EpisodeID
    public let before: String
    public let after: String
    public let count: Int

    public init(chapterID: ChapterID, episodeID: EpisodeID, before: String, after: String, count: Int) {
        self.chapterID = chapterID
        self.episodeID = episodeID
        self.before = before
        self.after = after
        self.count = count
    }

    public var inverse: Self {
        Self(chapterID: chapterID, episodeID: episodeID, before: after, after: before, count: count)
    }

    public func matches(_ document: NovelDocument) -> Bool {
        guard let content = document.chapters.first(where: { $0.id == chapterID })?.episodes
            .first(where: { $0.id == episodeID })?.content else { return false }
        return WorkTextSearch.sameText(content, before)
    }
}

/// FoundationのcaseInsensitive照合とUTF-16範囲はEditorKit.TextSearchと同じ。
public enum WorkTextSearch {
    public static func sameText(_ lhs: String, _ rhs: String) -> Bool {
        lhs.utf8.elementsEqual(rhs.utf8)
    }

    public static func ranges(query: String, in text: String) -> [NSRange] {
        guard !query.isEmpty else { return [] }
        let text = text as NSString
        var result: [NSRange] = [], location = 0
        while location < text.length {
            if Task.isCancelled {
                return []
            }
            let match = text.range(
                of: query,
                options: [.caseInsensitive],
                range: NSRange(location: location, length: text.length - location)
            )
            guard match.location != NSNotFound, match.length > 0 else { break }
            result.append(match)
            location = NSMaxRange(match)
        }
        return result
    }

    public static func search(query: String, in document: NovelDocument) -> [EpisodeTextMatches] {
        guard !query.isEmpty else { return [] }
        return document.chapters.flatMap { chapter in
            chapter.episodes.compactMap { episode in
                guard !Task.isCancelled else { return nil }
                let matches = ranges(query: query, in: episode.content).map {
                    WorkTextMatch(range: $0, context: context(in: episode.content, range: $0))
                }
                guard !matches.isEmpty else { return nil }
                return EpisodeTextMatches(chapterID: chapter.id, episodeID: episode.id,
                                          chapterTitle: chapter.title, episodeTitle: episode.title,
                                          source: episode.content, matches: matches)
            }
        }
    }

    /// 前後20書記素。絵文字・結合文字を途中で分断しない。
    public static func context(in text: String, range: NSRange, radius: Int = 20) -> String {
        let nsText = text as NSString
        guard range.location >= 0, range.length > 0, NSMaxRange(range) <= nsText.length else { return "" }
        let expanded = nsText.rangeOfComposedCharacterSequences(for: range)
        guard let swiftRange = Range(expanded, in: text) else { return "" }
        let start = text.index(swiftRange.lowerBound, offsetBy: -max(0, radius), limitedBy: text.startIndex) ?? text
            .startIndex
        let end = text.index(swiftRange.upperBound, offsetBy: max(0, radius), limitedBy: text.endIndex) ?? text.endIndex
        return (start > text.startIndex ? "…" : "") + String(text[start ..< end]) + (end < text.endIndex ? "…" : "")
    }

    public static func replacements(results: [EpisodeTextMatches], replacement: String,
                                    excluded: [EpisodeID: Set<Int>] = [:]) -> [EpisodeTextChange] {
        results.compactMap { result in
            let selected = result.matches.filter { !(excluded[result.id] ?? []).contains($0.id) }
            guard !selected.isEmpty else { return nil }
            let text = NSMutableString(string: result.source)
            for match in selected.reversed() {
                guard !Task.isCancelled else { return nil }
                text.replaceCharacters(in: match.range, with: replacement)
            }
            guard !sameText(text as String, result.source) else { return nil }
            return EpisodeTextChange(chapterID: result.chapterID, episodeID: result.id,
                                     before: result.source, after: text as String, count: selected.count)
        }
    }
}

import Foundation
import NovelCore

public enum TextCheckRule: String, CaseIterable, Sendable {
    case oddLeader, oddDash, punctuationSpace, periodBeforeBracket, halfWidthPunctuation, duplicatePunctuation, indentation
    case dictionaryVariation, readingVariation, characterTypo

    public var title: String {
        switch self {
        case .oddLeader: "三点リーダーは2個1組"
        case .oddDash: "ダッシュは2個1組"
        case .punctuationSpace: "！・？の後の全角スペース"
        case .periodBeforeBracket: "閉じ括弧の前の句点"
        case .halfWidthPunctuation: "半角の !・?"
        case .duplicatePunctuation: "句読点の重複"
        case .indentation: "地の文の字下げ"
        case .dictionaryVariation: "表記ゆれ（辞書）"
        case .readingVariation: "表記ゆれ（同じ読み）"
        case .characterTypo: "人物名に似た表記"
        }
    }
}

public struct TextCheckOptions: Equatable, Sendable {
    public var excludeDialogue: Bool
    public init(excludeDialogue: Bool = false) {
        self.excludeDialogue = excludeDialogue
    }
}

public struct TextCheckVariant: Equatable, Sendable {
    public let text: String
    public let count: Int
}

public struct TextCheckOccurrence: Identifiable, Equatable, Sendable {
    public let result: EpisodeTextMatches
    public var match: WorkTextMatch {
        result.matches[0]
    }

    public var id: String {
        "\(result.episodeID)-\(match.range.location)-\(match.range.length)"
    }
}

public struct TextCheckIssue: Identifiable, Equatable, Sendable {
    public let id: String
    public let rule: TextCheckRule
    public let title: String
    /// 件数降順。同数なら表記順。多数派を正解とは扱わない。
    public let variants: [TextCheckVariant]
    public let occurrences: [TextCheckOccurrence]

    public init(id: String, rule: TextCheckRule, title: String, variants: [TextCheckVariant], occurrences: [TextCheckOccurrence]) {
        self.id = id; self.rule = rule; self.title = title; self.variants = variants; self.occurrences = occurrences
    }

    public var replacement: (query: String, replacement: String)? {
        guard rule == .dictionaryVariation || rule == .readingVariation,
              let majority = variants.first, let minority = variants.last,
              majority.count > minority.count else { return nil }
        return (minority.text, majority.text)
    }
}

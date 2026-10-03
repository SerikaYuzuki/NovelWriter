import Foundation
import NovelCore

/// 不変の本文snapshotだけを解析する。通信・保存・本文編集の能力を持たない。
public struct TextChecker: Sendable {
    private let tokenizer: any JapaneseTextTokenizing
    public init(tokenizer: any JapaneseTextTokenizing = AppleJapaneseTokenizer()) {
        self.tokenizer = tokenizer
    }

    private struct AnalyzedEpisode {
        let chapter: Chapter
        let episode: Episode
        let masks: TextCheckMasks
        let tokens: [JapaneseTextToken]
        let tokenRanges: Set<NSRange>

        func occurrence(_ range: NSRange) -> TextCheckOccurrence {
            TextCheckOccurrence(result: EpisodeTextMatches(
                chapterID: chapter.id, episodeID: episode.id, chapterTitle: chapter.title,
                episodeTitle: episode.title, source: episode.content,
                matches: [WorkTextMatch(range: range, context: WorkTextSearch.context(in: episode.content, range: range))]
            ))
        }
    }

    public func check(_ document: NovelDocument, episodeID: EpisodeID? = nil,
                      options: TextCheckOptions = TextCheckOptions()) -> [TextCheckIssue] {
        var episodes: [AnalyzedEpisode] = []
        var issues: [TextCheckIssue] = []
        for chapter in document.chapters {
            for episode in chapter.episodes where episodeID == nil || episode.id == episodeID {
                guard !Task.isCancelled else { return [] }
                let masks = TextCheckMasks(episode.content)
                let tokens = tokenizer.tokens(in: episode.content).filter { masks.includes($0.range, excludeDialogue: options.excludeDialogue) }
                let analyzed = AnalyzedEpisode(chapter: chapter, episode: episode, masks: masks, tokens: tokens, tokenRanges: Set(tokens.map(\.range)))
                episodes.append(analyzed)
                for hit in TextCheckSymbols.hits(in: episode.content, masks: masks) {
                    let occurrence = analyzed.occurrence(hit.range)
                    // 文脈を含めることで、同じ位置の別の本文を誤って無視しない。
                    let id = "\(hit.rule.rawValue):\(occurrence.id):\(occurrence.match.context)"
                    issues.append(TextCheckIssue(id: id, rule: hit.rule, title: hit.rule.title,
                                                 variants: [], occurrences: [occurrence]))
                }
            }
        }
        guard !Task.isCancelled else { return [] }
        issues += dictionaryIssues(episodes, options: options)
        issues += readingIssues(episodes)
        issues += characterIssues(document.characters, episodes: episodes, options: options)
        guard !Task.isCancelled else { return [] }
        let order = Dictionary(uniqueKeysWithValues: episodes.enumerated().map { ($0.element.episode.id, $0.offset) })
        return issues.map { issue in
            TextCheckIssue(id: issue.id, rule: issue.rule, title: issue.title, variants: issue.variants,
                           occurrences: issue.occurrences.sorted {
                               let leftEpisodeIndex = order[$0.result.episodeID, default: 0]
                               let rightEpisodeIndex = order[$1.result.episodeID, default: 0]
                               return leftEpisodeIndex == rightEpisodeIndex
                                   ? $0.match.range.location < $1.match.range.location
                                   : leftEpisodeIndex < rightEpisodeIndex
                           })
        }
    }

    private struct Location {
        let episodeIndex: Int
        let range: NSRange
    }

    private func occurrences(_ locations: [Location], in episodes: [AnalyzedEpisode]) -> [TextCheckOccurrence] {
        locations.map { episodes[$0.episodeIndex].occurrence($0.range) }
    }

    private func dictionaryIssues(_ episodes: [AnalyzedEpisode], options: TextCheckOptions) -> [TextCheckIssue] {
        TextCheckDictionary.pairs.compactMap { first, second in
            if Task.isCancelled {
                return nil
            }
            var found: [String: [Location]] = [:]
            for (index, episode) in episodes.enumerated() {
                for text in [first, second] {
                    for range in WorkTextSearch.ranges(query: text, in: episode.episode.content) {
                        guard episode.masks.includes(range, excludeDialogue: options.excludeDialogue) else { continue }
                        // 一字の漢字を「仕事」「時間」等の内部で拾わない。
                        if text.count == 1, !episode.tokenRanges.contains(range) {
                            continue
                        }
                        found[text, default: []].append(Location(episodeIndex: index, range: range))
                    }
                }
            }
            guard found[first] != nil, found[second] != nil else { return nil }
            return variation(rule: .dictionaryVariation, key: "\(first)/\(second)", found: found.mapValues { occurrences($0, in: episodes) })
        }
    }

    private func readingIssues(_ episodes: [AnalyzedEpisode]) -> [TextCheckIssue] {
        let particles: Set = ["から", "まで", "ので", "のに", "だけ", "ほど", "より", "とか", "って", "ても", "でも", "では", "には", "とは", "なら"]
        var readings: [String: [String: [Location]]] = [:]
        for (index, episode) in episodes.enumerated() {
            for token in episode.tokens {
                guard !Task.isCancelled else { return [] }
                guard token.text.count >= 2, !particles.contains(token.text),
                      token.text.unicodeScalars.allSatisfy({ Self.isJapaneseLetter($0) }),
                      let reading = token.reading, !reading.isEmpty else { continue }
                readings[reading, default: [:]][token.text, default: []].append(Location(episodeIndex: index, range: token.range))
            }
        }
        let dictionarySets = TextCheckDictionary.pairs.map { Set([$0.0, $0.1]) }
        return readings.keys.sorted().compactMap { reading in
            let found = readings[reading, default: [:]].filter { $0.value.count >= 2 }
            guard found.count >= 2, found.keys.contains(where: Self.containsKanji) else { return nil }
            // 同じ組を辞書と読み一致で二重報告しない。
            if dictionarySets.contains(Set(found.keys)) {
                return nil
            }
            return variation(rule: .readingVariation, key: reading + ":" + found.keys.sorted().joined(separator: "/"), found: found.mapValues { occurrences($0, in: episodes) })
        }
    }

    private func variation(rule: TextCheckRule, key: String, found: [String: [TextCheckOccurrence]]) -> TextCheckIssue {
        let variants = found.map { TextCheckVariant(text: $0.key, count: $0.value.count) }.sorted {
            $0.count == $1.count ? $0.text < $1.text : $0.count > $1.count
        }
        let occurrences = found.values.flatMap { $0 }
        return TextCheckIssue(id: "\(rule.rawValue):\(key)", rule: rule,
                              title: variants.map { "\($0.text) \($0.count)件" }.joined(separator: " / "), variants: variants,
                              occurrences: occurrences)
    }

    private func characterIssues(_ characters: [NovelCore.Character], episodes: [AnalyzedEpisode],
                                 options: TextCheckOptions) -> [TextCheckIssue] {
        let names = Set(characters.flatMap { [$0.name.trimmingCharacters(in: .whitespacesAndNewlines), $0.kana.trimmingCharacters(in: .whitespacesAndNewlines)] })
        var candidates: [String: [Location]] = [:]
        for (index, episode) in episodes.enumerated() {
            var seen: Set<NSRange> = []
            // OS辞書が未知のカタカナ名を分割しても、連続した名前を照合できる。
            let regex = try? NSRegularExpression(pattern: "[ァ-ヺー]+")
            let ranges = episode.tokens.map(\.range) + (regex?.matches(in: episode.episode.content, range: NSRange(location: 0, length: episode.episode.content.utf16.count)).map(\.range) ?? [])
            for range in ranges where seen.insert(range).inserted {
                guard episode.masks.includes(range, excludeDialogue: options.excludeDialogue) else { continue }
                let text = (episode.episode.content as NSString).substring(with: range)
                guard text.count >= 2, Self.script(text) != nil else { continue }
                candidates[text, default: []].append(Location(episodeIndex: index, range: range))
            }
        }
        var issues: [TextCheckIssue] = []
        for name in names.sorted() where name.count >= 2 {
            guard let script = Self.script(name), script != .hiragana || characters.contains(where: { $0.kana == name }) else { continue }
            var correctCount = 0
            for episode in episodes {
                correctCount += WorkTextSearch.ranges(query: name, in: episode.episode.content)
                    .count(where: { episode.masks.includes($0, excludeDialogue: options.excludeDialogue) })
            }
            let nameLetters = Array(name)
            for candidate in candidates.keys.sorted() {
                guard !Task.isCancelled else { return [] }
                guard !names.contains(candidate), candidate.count == name.count, Self.script(candidate) == script,
                      zip(nameLetters, Array(candidate)).count(where: { $0 != $1 }) == 1,
                      let occurrences = candidates[candidate], occurrences.count < correctCount else { continue }
                issues.append(TextCheckIssue(id: "characterTypo:\(name)/\(candidate)", rule: .characterTypo,
                                             title: "『\(name)』に似た『\(candidate)』（\(correctCount)件 / \(occurrences.count)件）",
                                             variants: [], occurrences: self.occurrences(occurrences, in: episodes)))
            }
        }
        return issues
    }

    private enum Script { case kanji, katakana, hiragana }
    private static func script(_ text: String) -> Script? {
        if text.unicodeScalars.allSatisfy({ (0x30A1 ... 0x30FA).contains($0.value) || $0.value == 0x30FC }) {
            return .katakana
        }
        if text.unicodeScalars.allSatisfy({ (0x3041 ... 0x3096).contains($0.value) }) {
            return .hiragana
        }
        if text.unicodeScalars.allSatisfy({ isKanji($0) }) {
            return .kanji
        }
        return nil
    }

    private static func isKanji(_ scalar: UnicodeScalar) -> Bool {
        (0x3400 ... 0x9FFF).contains(scalar.value) || (0x20000 ... 0x3134F).contains(scalar.value) || scalar.value == 0x3005
    }

    private static func containsKanji(_ text: String) -> Bool {
        text.unicodeScalars.contains(where: isKanji)
    }

    private static func isJapaneseLetter(_ scalar: UnicodeScalar) -> Bool {
        isKanji(scalar) || (0x3041 ... 0x3096).contains(scalar.value) || (0x30A1 ... 0x30FA).contains(scalar.value) || scalar.value == 0x30FC
    }
}

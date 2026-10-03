import EditorKit
import Foundation
import NovelCore
import NovelTextAnalysis
import Testing

struct WorkTextSearchTests {
    @Test func allEpisodesOnlyAndEmptyQuery() {
        var document = NovelDocument.newDocument()
        document.chapters = [
            Chapter(title: "猫", episodes: [
                Episode(title: "猫", content: "CAT cat", memo: "cat"),
                Episode(content: "Cat")
            ]),
            Chapter(title: "次章", episodes: [Episode(content: "なし")])
        ]
        let results = WorkTextSearch.search(query: "cat", in: document)
        #expect(results.count == 2)
        #expect(results.map { $0.matches.count } == [2, 1])
        #expect(results[0].id == document.chapters[0].episodes[0].id)
        #expect(WorkTextSearch.search(query: "", in: document).isEmpty)
        #expect(WorkTextSearch.search(query: "猫", in: document).isEmpty)
        #expect(results[0].matches.map { $0.range } == [
            NSRange(location: 0, length: 3),
            NSRange(location: 4, length: 3)
        ])
    }

    @Test func utf16MatchesEditorSearchAndWholeGraphemeContext() throws {
        let text = "👨‍👩‍👧‍👦e\u{301}猫🐈猫終"
        let ranges = WorkTextSearch.ranges(query: "猫", in: text)
        #expect(ranges.count == 2)
        #expect(ranges.first == TextSearch.find(query: "猫", in: text, from: 0, wraps: false))
        #expect(ranges[1] == TextSearch.find(query: "猫", in: text, from: NSMaxRange(ranges[0]), wraps: false))
        #expect((text as NSString).substring(with: ranges[0]) == "猫")
        #expect(WorkTextSearch.context(in: text, range: ranges[0], radius: 1) == "…e\u{301}猫🐈…")
        let accent = try #require(WorkTextSearch.ranges(query: "é", in: text).first)
        #expect((text as NSString).substring(with: accent) == "e\u{301}")
        #expect(WorkTextSearch.context(in: text, range: accent, radius: 1) == "👨‍👩‍👧‍👦e\u{301}猫…")
        let long = String(repeating: "あ", count: 30) + "猫" + String(repeating: "い", count: 30)
        #expect(WorkTextSearch.context(in: long, range: NSRange(location: 30, length: 1)) == "…" + String(
            repeating: "あ",
            count: 20
        ) + "猫" + String(repeating: "い", count: 20) + "…")
    }

    @Test func excludedReplacementAndChangedTargets() {
        var document = NovelDocument.newDocument()
        document.chapters = [Chapter(title: "章", episodes: [Episode(content: "猫🐈猫"), Episode(content: "猫")])]
        let result = WorkTextSearch.search(query: "猫", in: document)
        let changes = WorkTextSearch.replacements(
            results: result,
            replacement: "子猫",
            excluded: [result[0].id: [result[0].matches[0].id]]
        )
        #expect(changes.map { $0.after } == ["猫🐈子猫", "子猫"])
        #expect(changes.map { $0.count } == [1, 1])
        #expect(changes.allSatisfy { $0.matches(document) })
        document.updateEpisodeContent("変更", for: result[0].id, in: result[0].chapterID)
        #expect(!changes[0].matches(document))
        #expect(changes[1].matches(document))
        document.updateEpisodeContent(changes[1].after, for: changes[1].episodeID, in: changes[1].chapterID)
        #expect(changes[1].inverse.matches(document))
    }

    @Test func appearancesCountOrderKanaAndNoAppearance() {
        var document = NovelDocument.newDocument()
        document.chapters = [
            Chapter(title: "第1章", episodes: [
                Episode(title: "第1話", content: "なし"),
                Episode(title: "第2話", content: "あき、秋、秋")
            ]),
            Chapter(title: "第5章", episodes: [Episode(title: "第3話", content: "秋")])
        ]
        let character = NovelCore.Character(name: "秋", kana: "あき")
        let appearances = CharacterAppearanceDetector.appearances(for: character, in: document)
        #expect(appearances.map { $0.count } == [3, 1])
        #expect(appearances.first?.query == "あき")
        #expect(appearances.first?.range == NSRange(location: 0, length: 2))
        #expect(CharacterAppearanceDetector.summary(appearances) == "登場 2話 · 最初 第1章 第2話 · 最後 第5章 第3話")
        #expect(CharacterAppearanceDetector.summary(CharacterAppearanceDetector.appearances(
            for: NovelCore.Character(name: "冬"),
            in: document
        )) == "本文にまだ登場していません")
        let overlapping = CharacterAppearanceDetector.appearances(
            for: NovelCore.Character(name: "CAT", kana: "cat"),
            in: Episode(content: "cat CAT"),
            chapterID: ChapterID(),
            chapterTitle: "章"
        )
        #expect(overlapping.first?.count == 2)
        #expect(CharacterAppearanceDetector.appearances(
            for: NovelCore.Character(name: "秋", kana: "秋山"),
            in: Episode(content: "秋山"),
            chapterID: ChapterID(),
            chapterTitle: "章"
        ).first?.count == 1)
    }
}

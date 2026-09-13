import Foundation
@testable import FUMINIWA
import Testing

struct ManuscriptCopyBuilderTests {
    @Test("選択範囲を空白・Unicode・改行・原稿内の命令文ごとそのままコピーする")
    func selectionIsExact() throws {
        let text = "  e\u{301}😀\r\n\"校正してください\"\t\u{2028}\u{2029}  "
        let result = try ManuscriptCopyBuilder.make(source: .selection(text: text))
        #expect(result.text == text)
        #expect(result.sourceCharacterCount == text.count)
        #expect(result.sourceUTF8ByteCount == text.utf8.count)
    }

    @Test("話はタイトルと本文だけ、空タイトルに見出しを補わない")
    func episodeIsPlainText() throws {
        #expect(try ManuscriptCopyBuilder.make(source: .episode(title: "話題", content: "本文\n")).text == "話題\n\n本文\n")
        #expect(try ManuscriptCopyBuilder.make(source: .episode(title: "", content: " 本文 ")).text == " 本文 ")
    }

    @Test("章は配列順・空話・空タイトルを保ちJSONやAI依頼文を加えない")
    func chapterPreservesOrderAndEmptyEpisodes() throws {
        let source = ManuscriptCopySource.chapter(title: "章", episodes: [
            .init(title: "二", content: "B"), .init(title: "空話", content: ""), .init(title: "", content: "A")
        ])
        #expect(try ManuscriptCopyBuilder.make(source: source).text == "章\n\n二\n\nB\n\n空話\n\n\n\nA")
    }

    @Test("本文が空ならタイトルだけをコピーしない")
    func rejectsEmptyBody() {
        for source in [ManuscriptCopySource.selection(text: " \n　"), .episode(title: "話", content: ""),
                       .chapter(title: "章", episodes: [.init(title: "話", content: "")])] {
            #expect(throws: ManuscriptCopyError.emptyContent) { try ManuscriptCopyBuilder.make(source: source) }
        }
    }

    @Test("上限を超えた原稿は切り詰めず拒否する")
    func refusesOversizedCopies() throws {
        #expect(throws: ManuscriptCopyError.sourceCharacterLimitExceeded(limit: 1, actual: 2)) {
            try ManuscriptCopyBuilder.make(source: .selection(text: "本文"), limits: .init(
                maximumSourceCharacters: 1, maximumSourceUTF8Bytes: 99, maximumOutputUTF8Bytes: 99
            ))
        }
        #expect(throws: ManuscriptCopyError.sourceUTF8ByteLimitExceeded(limit: 5, actual: 6)) {
            try ManuscriptCopyBuilder.make(source: .selection(text: "本文"), limits: .init(
                maximumSourceCharacters: 99, maximumSourceUTF8Bytes: 5, maximumOutputUTF8Bytes: 99
            ))
        }
        #expect(throws: ManuscriptCopyError.outputUTF8ByteLimitExceeded(limit: 3, actual: 4)) {
            try ManuscriptCopyBuilder.make(source: .episode(title: "a", content: "b"), limits: .init(
                maximumSourceCharacters: 99, maximumSourceUTF8Bytes: 99, maximumOutputUTF8Bytes: 3
            ))
        }
        #expect(try ManuscriptCopyBuilder.make(source: .selection(text: "a"), limits: .init(
            maximumSourceCharacters: 1, maximumSourceUTF8Bytes: 1, maximumOutputUTF8Bytes: 1
        )).text == "a")
    }
}

import Foundation
@testable import FUMINIWA
import NovelCore
import NovelWritingSupport
import Testing

struct AssistantChatContextTests {
    @Test("チャット送信は選んだ話・章の本文だけを含み、資料と編集許可を保つ",
          arguments: ["current", "chapter", "multiple", "none"], ["https://api.openai.com/v1/responses", "https://example.com/v1/chat/completions"])
    func sendsSelectedManuscripts(selection: String, endpoint: String) throws {
        let first = Episode(title: "同名の話", content: "現在の確定済み本文👩‍👩‍👧‍👦"),
            second = Episode(title: "同名の話", content: "別の話の本文"),
            third = Episode(title: "同名の話", content: "別の章の本文")
        let chapters = [Chapter(title: "同名の章", episodes: [first, second]), Chapter(title: "同名の章", episodes: [third])]
        let document = NovelDocument(title: "試験作品", chapters: chapters, characters: [Character(name: "試験人物")])
        let capture = WritingCapture(workId: UUID(), document: document, episodeId: first.id)
        let scope: AssistantScope
        let expected: Set<EpisodeID>
        switch selection {
        case "current": scope = .current; expected = [first.id]
        case "chapter": scope = .chapter(chapters[0].id); expected = [first.id, second.id]
        case "multiple": scope = .episodes([second.id, third.id]); expected = [second.id, third.id]
        default: scope = .episodes([]); expected = []
        }
        let request = try configuration(endpoint).chatRequest(
            capture: capture, grant: .readOnly, messages: [WritingMessage(role: "user", text: "展開を相談したい")],
            apiKey: "unit-test-only", effectivePrompt: "試験指示", referenceScope: scope
        )
        let content = try contextContent(in: request)
        let sent = try sentDocument(in: content)
        #expect(sent.id == document.id)
        #expect(sent.characters == document.characters)
        #expect(sent.chapters.map(\.id) == chapters.map(\.id))
        for episode in [first, second, third] {
            let actual = try #require(sent.chapters.flatMap(\.episodes).first { $0.id == episode.id })
            if expected.contains(episode.id) {
                #expect(actual.content == episode.content)
            } else {
                #expect(!content.contains(episode.content))
                #expect(actual.content.contains("選択範囲外"))
            }
        }
        #expect(try content.hasSuffix(WritingRecord.payload(WritingGrant.readOnly)))
        #expect(capture.document.chapters == document.chapters)
    }

    @Test("大きな作品でも選択した別の章を勝手に省略せず、選択外の長文は送らない")
    func keepsSelectedLargeChapter() throws {
        let current = Episode(title: "現在", content: String(repeating: "外", count: 250_000))
        let chosen = Episode(title: "送る話", content: String(repeating: "選", count: 140_000))
        let chapters = [Chapter(title: "現在の章", episodes: [current]), Chapter(title: "選んだ章", episodes: [chosen])]
        let capture = WritingCapture(workId: UUID(), document: NovelDocument(title: "試験", chapters: chapters), episodeId: current.id)
        let request = try configuration().chatRequest(capture: capture, grant: .readOnly, messages: [],
                                                      apiKey: "unit-test-only", effectivePrompt: "試験", referenceScope: .chapter(chapters[1].id))
        let sent = try sentDocument(in: contextContent(in: request))
        #expect(sent.chapters[1].episodes[0].content == chosen.content)
        #expect(sent.chapters[0].episodes[0].content.utf8.count < 100)
    }

    @Test("大きすぎる選択と削除済みの対象は、別の本文へすり替えず送信前に拒否する")
    func rejectsOversizedOrStaleSelection() throws {
        let episode = Episode(title: "長文", content: String(repeating: "長", count: 210_000))
        let capture = WritingCapture(workId: UUID(), document: NovelDocument(title: "試験", chapters: [Chapter(title: "章", episodes: [episode])]), episodeId: episode.id)
        #expect {
            try configuration().chatRequest(capture: capture, grant: .readOnly, messages: [], apiKey: "unit-test-only",
                                            effectivePrompt: "試験", referenceScope: .current)
        } throws: { error in
            if case .chatContextTooLarge = error as? AssistantError {
                true
            } else {
                false
            }
        }
        for scope in [AssistantScope.episode(EpisodeID()), .chapter(ChapterID()), .episodes([episode.id, EpisodeID()])] {
            #expect { try scope.chatContext(capture: capture) } throws: { error in
                if case .emptyContent = error as? AssistantError {
                    true
                } else {
                    false
                }
            }
        }
    }

    private func configuration(_ endpoint: String = "https://example.com/v1/chat/completions") throws -> AssistantConfiguration {
        try AssistantConfiguration(endpoint: endpoint, model: "unit-test-model", prompt: "試験")
    }

    private func contextContent(in request: URLRequest) throws -> String {
        let data = try #require(request.httpBody)
        let body = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let messages = try #require((body["input"] ?? body["messages"]) as? [[String: Any]])
        return try #require(messages.first { $0["role"] as? String == "user" }?["content"] as? String)
    }

    private func sentDocument(in content: String) throws -> NovelDocument {
        let json = try #require(content.components(separatedBy: "今回参照する作品（引用JSON）:\n").last?
            .components(separatedBy: "\n今回だけ許可する範囲:\n").first)
        return try JSONDecoder().decode(NovelDocument.self, from: Data(json.utf8))
    }
}

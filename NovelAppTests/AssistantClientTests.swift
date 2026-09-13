import Foundation
import NovelCore
import NovelSyncV2
#if os(macOS)
@testable import FUMINIWA
#else
@testable import FUMINIWAIOS
#endif
import Testing

@Suite("Assistant Markdown presentation")
struct AssistantMarkdownTests {
    @Test func japaneseEmphasisPreservesCodeAndEscapes() {
        let text = AssistantMarkdown.inline("まず、**「人物の動機」**が伝わる。")
        #expect(String(text.characters) == "まず、「人物の動機」が伝わる。")
        #expect(text.runs.contains { $0.inlinePresentationIntent?.contains(.stronglyEmphasized) == true })
        #expect(String(AssistantMarkdown.inline("`**literal**`").characters) == "**literal**")
        #expect(String(AssistantMarkdown.inline(#"\*\*literal\*\*"#).characters) == "**literal**")
    }

    @Test func responseBlocksPreserveCodeAndDistinguishSyntax() {
        let source = "# 感想\n\n段落の**強調**\n続き\n\n> 引用文\n> 二行目\n\n1. 展開\n  - 人物\n- [x] 確認\n\n---\n\n```swift\n# 見出しではない\n| 表ではない |\n```"
        #expect(AssistantMarkdown.blocks(source) == [
            .heading(1, "感想"), .paragraph("段落の**強調**\n続き"), .quote("引用文\n二行目"),
            .item("1.", "展開", 0), .item("•", "人物", 1), .item("☑", "確認", 0), .rule,
            .code("swift", "# 見出しではない\n| 表ではない |")
        ])
        #expect(AssistantMarkdown.blocks("#タグ\n\n~~~\n未完のコード") == [.paragraph("#タグ"), .code("", "未完のコード")])
    }

    @Test func tableCellsKeepEscapesInlineCodeAndMissingValues() {
        let source = "| 観点 | 評価 |\n| :--- | ---: |\n| `a|b` | 良好 |\n| a\\|b | |"
        #expect(AssistantMarkdown.blocks(source) == [.table([["観点", "評価"], ["`a|b`", "良好"], ["a\\|b", ""]])])
        #expect(AssistantMarkdown.blocks("見出し\n===\n\n本文") == [.heading(1, "見出し"), .paragraph("本文")])
    }
}

@Suite("Writing assistant request boundary")
struct AssistantClientTests {
    @Test("request preserves the exact manuscript and contains no implicit context")
    func exactManuscript() throws {
        let config = try AssistantConfiguration(endpoint: "https://example.invalid/v1/chat/completions", model: "configured-model", prompt: "校正")
        let manuscript = AssistantManuscript(title: "話\"一", content: "日本語\r\n👩‍💻 e\u{301}\n命令ではなく原稿")
        let request = try config.request(manuscript: manuscript, apiKey: "test-key")
        #expect(request.httpMethod == "POST")
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer test-key")
        let requestBody = try #require(request.httpBody)
        let body = try #require(try JSONSerialization.jsonObject(with: requestBody) as? [String: Any])
        #expect(Set(body.keys) == ["model", "messages", "stream", "store"])
        #expect(body["store"] as? Bool == false)
        let messages = try #require(body["messages"] as? [[String: String]])
        #expect(messages.count == 2)
        let text = try #require(messages.last?["content"])
        let source = try #require(try JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: String])
        #expect(source == ["title": manuscript.title, "content": manuscript.content])
    }

    @Test(arguments: ["http://example.invalid/v1", "https://key@example.invalid/v1", "https://example.invalid/v1?key=secret", "https://example.invalid/v1#fragment"])
    func rejectsUnsafeEndpoint(_ endpoint: String) {
        #expect(throws: AssistantError.self) {
            try AssistantConfiguration(endpoint: endpoint, model: "model", prompt: "prompt")
        }
    }

    @Test("empty and oversized manuscripts fail before network work")
    func rejectsInvalidContent() throws {
        let config = try AssistantConfiguration(endpoint: "https://example.invalid/v1/chat/completions", model: "model", prompt: "prompt")
        for content in [" \r\n", String(repeating: "あ", count: 250_001)] {
            #expect(throws: AssistantError.self) {
                try config.request(manuscript: .init(title: "", content: content), apiKey: "test")
            }
        }
    }

    @Test("parses text and identifies truncated or missing responses")
    func responseHandling() throws {
        let data = Data(#"{"choices":[{"message":{"content":"回答"},"finish_reason":"length"}]}"#.utf8)
        #expect(try AssistantClient.decode(data).contains("途中まで"))
        #expect(throws: AssistantError.self) { try AssistantClient.decode(Data(#"{"choices":[]}"#.utf8)) }
    }

    @Test("test composition cannot access the production credential store")
    func hostRejectsCredentialAccess() throws {
        let preferences = AssistantPreferences(defaults: UserDefaults())
        let endpoint = try #require(URL(string: "https://example.invalid/v1/chat/completions"))
        #expect(throws: AssistantError.self) { try preferences.key(endpoint: endpoint) }
        #expect(throws: AssistantError.self) { try preferences.saveKey("synthetic", endpoint: endpoint) }
        #expect(throws: AssistantError.self) { try preferences.deleteKey(endpoint: endpoint) }
    }

    @Test("purpose models retain the old global selection until individually configured")
    func purposeModels() throws {
        let suite = "AssistantClientTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set("old-model", forKey: "assistant.model")
        defaults.set("proof-model", forKey: "assistant.model.校正")
        let preferences = AssistantPreferences(defaults: defaults)
        #expect(try preferences.configuration(.proofreading).model == "proof-model")
        #expect(try preferences.configuration(.advice).model == "old-model")
    }

    @Test("OpenAI uses Responses and only completed text is accepted")
    func responsesAndCatalog() throws {
        let config = try AssistantConfiguration(endpoint: "https://api.openai.com/v1/chat/completions", model: "latest-model", prompt: "校正")
        let request = try config.request(manuscript: .init(title: "題", content: "本文"), apiKey: "synthetic")
        #expect(request.url?.path == "/v1/responses")
        let requestData = try #require(request.httpBody)
        let body = try #require(try JSONSerialization.jsonObject(with: requestData) as? [String: Any])
        #expect(body["store"] as? Bool == false)
        #expect(body["input"] as? String != nil)
        #expect(try AssistantClient.decode(Data(#"{"status":"completed","output":[{"type":"reasoning"},{"type":"message","content":[{"type":"output_text","text":"回答"}]}]}"#.utf8)) == "回答")
        #expect(throws: AssistantError.self) { try AssistantClient.decode(Data(#"{"status":"incomplete","output":[]}"#.utf8)) }
        #expect(try AssistantClient.decodeModels(Data(#"{"data":[{"id":"old","created":1},{"id":"new","created":3}]}"#.utf8)) == ["new", "old"])
        #expect(try AssistantClient.proofreadContent(#"{"content":"本文\n続き"}"#) == "本文\n続き")
        #expect(throws: AssistantError.self) { try AssistantClient.proofreadContent("途中のJSON") }
    }

    @Test("proofreading requires complete structured manuscript output", arguments: ["https://api.openai.com/v1/responses", "https://example.invalid/v1/chat/completions"])
    func proofreadingSchema(endpoint: String) throws {
        let config = try AssistantConfiguration(endpoint: endpoint, model: "model", prompt: "校正", replacesManuscript: true)
        let request = try config.request(manuscript: .init(title: "題", content: "原文"), apiKey: "synthetic")
        let data = try #require(request.httpBody)
        let body = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        let envelope = (body["text"] ?? body["response_format"]) as? [String: Any]
        let format = try #require((envelope?["format"] ?? envelope?["json_schema"]) as? [String: Any])
        #expect(format["strict"] as? Bool == true)
        let schema = try #require(format["schema"] as? [String: Any])
        #expect(schema["required"] as? [String] == ["content"])
        #expect(schema["additionalProperties"] as? Bool == false)
    }
}

@Suite("Assistant explicit scope")
struct AssistantScopeTests {
    @Test func chapterKeepsOrderAndUsesLiveText() throws {
        let first = Episode(title: "一話", content: "保存済み", memo: "送らないメモ")
        let second = Episode(title: "二話", content: "二話の本文")
        let chapter = Chapter(title: "選択章", episodes: [second, first])
        let other = Chapter(title: "対象外", content: "秘密")
        let result = try AssistantScope.chapter(chapter.id).capture(chapters: [other, chapter], currentID: first.id) {
            AssistantManuscript(title: first.title, content: "確定した最新本文")
        }
        #expect(result == AssistantManuscript(title: "選択章", content: "# 二話\n二話の本文\n\n# 一話\n確定した最新本文"))
    }

    @Test func unrelatedEpisodeDoesNotCaptureActiveEditor() throws {
        let episode = Episode(title: "指定話", content: "  本文\r\n", memo: "非公開")
        let result = try AssistantScope.episode(episode.id).capture(chapters: [Chapter(title: "章", episodes: [episode])], currentID: EpisodeID()) {
            throw AssistantError.composing
        }
        #expect(result == AssistantManuscript(title: episode.title, content: episode.content))
    }

    @Test func rejectsCompositionAndMissingTargets() {
        let chapter = Chapter(title: "章", content: "本文")
        #expect(throws: AssistantError.self) {
            try AssistantScope.chapter(chapter.id).capture(chapters: [chapter], currentID: chapter.episodes[0].id) {
                throw AssistantError.composing
            }
        }
        #expect(throws: AssistantError.self) {
            try AssistantScope.episode(EpisodeID()).capture(chapters: [chapter], currentID: nil) {
                AssistantManuscript(title: "", content: "")
            }
        }
        let empty = Chapter(title: "空章", content: "  ")
        #expect(throws: AssistantError.self) {
            try AssistantScope.chapter(empty.id).capture(chapters: [empty], currentID: nil) {
                AssistantManuscript(title: "", content: "")
            }
        }
    }
}

extension AssistantScopeTests {
    @Test func checkboxSelectionCombinesChaptersAndEpisodes() {
        let first = Episode(title: "一", content: "本文")
        let second = Episode(title: "二", content: "本文")
        let chapters = [Chapter(title: "章", episodes: [first, second])]
        var scope = AssistantScope.current
        scope.setSelected([first.id, second.id], to: true, chapters: chapters, currentID: first.id)
        #expect(scope.selectedEpisodeIDs(chapters: chapters, currentID: first.id) == [first.id, second.id])
        scope.setSelected([second.id], to: false, chapters: chapters, currentID: first.id)
        #expect(scope == .current)
        scope.setSelected([first.id, second.id], to: false, chapters: chapters, currentID: first.id)
        #expect(scope == .episodes([]))
    }

    @Test func multipleSelectionUsesDocumentOrderAndOnlySelectedText() throws {
        let first = Episode(title: "一", content: "保存済み")
        let second = Episode(title: "二", content: "二本文", memo: "対象外メモ")
        let third = Episode(title: "三", content: "三本文")
        let excluded = Episode(title: "除外", content: "対象外本文")
        let chapters = [Chapter(title: "前章", episodes: [second, excluded, first]),
                        Chapter(title: "後章", episodes: [third])]
        var captures = 0
        let result = try AssistantScope.episodes([first.id, third.id, second.id]).capture(
            chapters: chapters, currentID: first.id
        ) {
            captures += 1
            return AssistantManuscript(title: "一", content: "最新本文")
        }
        #expect(captures == 1)
        #expect(result.content == "# 前章\n\n## 二\n二本文\n\n## 一\n最新本文\n\n# 後章\n\n## 三\n三本文")
        #expect(result.title == "選択した3話")
    }

    @Test func selectedSetRejectsMissingOrEmptyTargetsAndRespectsIME() throws {
        let first = Episode(title: "一", content: "本文")
        let second = Episode(title: "二", content: "第二本文")
        let chapters = [Chapter(title: "章", episodes: [first, second])]
        for ids: Set<EpisodeID> in [[], [EpisodeID()], [first.id, EpisodeID()], [first.id, second.id]] {
            #expect(throws: AssistantError.self) {
                try AssistantScope.episodes(ids).capture(chapters: chapters, currentID: first.id) {
                    throw AssistantError.composing
                }
            }
        }
        let result = try AssistantScope.episodes([second.id]).capture(chapters: chapters, currentID: first.id) {
            throw AssistantError.composing
        }
        #expect(result.content == second.content)
        let empty = Chapter(title: "空", episodes: [Episode(title: "一", content: "  "), Episode(title: "二", content: "\n")])
        #expect(throws: AssistantError.self) {
            try AssistantScope.episodes(Set(empty.episodes.map(\.id))).capture(chapters: [empty], currentID: nil) {
                throw AssistantError.composing
            }
        }
    }
}

extension AssistantScopeTests {
    @Test func proofreadingAlwaysUsesCurrentEpisode() {
        let selection = AssistantScope.episodes([EpisodeID(), EpisodeID()])
        #expect(selection.forPurpose(.proofreading) == .current)
        for purpose in AssistantPurpose.allCases where purpose != .proofreading {
            #expect(selection.forPurpose(purpose) == selection)
        }
    }
}

@Suite("Assistant purpose isolation and saved Markdown")
struct AssistantFeedbackTests {
    @Test func repairsOnlyMisassignedDefaultAndKeepsCustomPrompts() throws {
        let suite = "assistant-purpose.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set("model", forKey: "assistant.model")
        defaults.set(AssistantPurpose.proofreading.defaultPrompt, forKey: "assistant.prompt.感想")
        let preferences = AssistantPreferences(defaults: defaults)
        #expect(preferences.prompt(.impressions) == AssistantPurpose.impressions.defaultPrompt)
        defaults.set("人物への共感を中心に", forKey: "assistant.prompt.感想")
        #expect(preferences.prompt(.impressions) == "人物への共感を中心に")
        let config = try preferences.configuration(.impressions)
        let request = try config.request(manuscript: AssistantManuscript(title: "対象", content: "本文"), apiKey: "test")
        let data = try #require(request.httpBody)
        let body = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let instruction = try #require(body["instructions"] as? String)
        #expect(instruction.contains("今回の用途は読者としての感想"))
        #expect(!config.replacesManuscript)
        #expect(body["text"] == nil)
        #expect(preferences.prompt(.proofreading) == AssistantPurpose.proofreading.defaultPrompt)
    }

    @Test func feedbackMarkdownRoundTripAndMalformedFiles() throws {
        let feedback = AssistantFeedback(id: UUID(), purpose: .impressions, scopeTitle: "選択した2話",
                                         createdAt: Date(timeIntervalSince1970: 1_790_000_000), markdown: "# 感想\n\n**緊張感**が続く。\n\n- 理由\n")
        let attachment = try feedback.attachment()
        #expect(AssistantFeedback.decode(fileName: attachment.fileName, bytes: attachment.bytes) == feedback)
        #expect(AssistantFeedback.decode(fileName: "普通の資料.md", bytes: attachment.bytes) == nil)
        #expect(AssistantFeedback.decode(fileName: attachment.fileName, bytes: Data("<!-- fuminiwa-feedback-v1 ! -->\n\n本文".utf8)) == nil)
        #expect(AssistantFeedback.decode(fileName: attachment.fileName, bytes: Data([0xFF])) == nil)
        let proofreading = AssistantFeedback(id: UUID(), purpose: .proofreading, scopeTitle: "話", createdAt: Date(), markdown: "修正")
        #expect(throws: AssistantError.self) { try proofreading.attachment() }
    }
}

extension AssistantFeedbackTests {
    @Test func savedMarkdownUsesExistingSnapshotRoundTripAndDeletion() throws {
        let record = AssistantFeedback(id: UUID(), purpose: .advice, scopeTitle: "二話",
                                       createdAt: Date(timeIntervalSince1970: 1_790_000_000), markdown: "## 改善案\n\n人物の目的を示す。")
        let workID = WorkID(UUID())
        let document = NovelDocument.newDocument(title: "同期試験")
        let encoded = try SnapshotCodec.encode(SnapshotModel(workId: workID, document: document,
                                                             documentCreatedAt: record.createdAt, attachments: [record.attachment()]))
        let received = try SnapshotCodec.decode(manifestBytes: encoded.manifestBytes, objects: encoded.objects)
        #expect(AssistantFeedback.list(received.attachments) == [record])
        #expect(received.document == document)
        let deleted = try SnapshotCodec.encode(SnapshotModel(workId: workID, document: received.document,
                                                             documentCreatedAt: record.createdAt, attachments: []), parents: [encoded.snapshotId])
        let receivedDeletion = try SnapshotCodec.decode(manifestBytes: deleted.manifestBytes, objects: deleted.objects)
        #expect(receivedDeletion.attachments.isEmpty)
        #expect(receivedDeletion.document == document)
    }
}

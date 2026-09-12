import Foundation
#if os(macOS)
@testable import FUMINIWA
#else
@testable import FUMINIWAIOS
#endif
import Testing

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
        let defaults = makeIsolatedTestUserDefaults()
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
}

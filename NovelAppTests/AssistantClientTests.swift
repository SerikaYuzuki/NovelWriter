import Foundation
import NovelWorkspaceUI
#if os(macOS)
@testable import FUMINIWA
#else
@testable import FUMINIWAIOS
#endif
import Testing

struct AssistantPreferencesTests {
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
}

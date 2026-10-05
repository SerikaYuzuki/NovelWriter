import Foundation
import NovelCore
import NovelWorkspaceUI
import NovelWritingSupport
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

@MainActor
struct AssistantDeliveryTests {
    @Test func proofreadingChecksExactTextAndEpisodeBeforeEditing() async throws {
        let work = UUID(), episode = Episode(title: "話", content: "元の本文"), other = Episode(title: "別の話", content: "別本文")
        var document = NovelDocument(title: "合成", chapters: [Chapter(title: "章", episodes: [episode, other])])
        var selected = episode.id, edits = 0
        let center = AssistantRequestCenter()
        let host = WritingAssistantHost(contextID: "session", workID: work, accountID: "account", requestCenter: center,
                                        capture: { WritingCapture(workId: work, document: document, episodeId: selected) },
                                        records: { _ in [] }, append: { _ in }, synchronize: {}, apply: { _, _ in edits += 1 }, undo: { _ in })
        let metadata = AssistantRequestRecord(purpose: .proofreading, documentId: document.id, episodeId: episode.id, scope: "話", permission: "校正")
        let config = try AssistantConfiguration(endpoint: "https://example.invalid/responses", model: "synthetic", prompt: "指示", replacesManuscript: true)
        let input = try host.savedInput(config.request(manuscript: AssistantManuscript(title: "話", content: episode.content), apiKey: "synthetic"))
        let result = #"{"changes":[{"before":"元","after":"新","reason":"誤字","check":"typo"}]}"#
        selected = other.id
        await #expect(throws: WritingError.self) { try await host.applyProofreadingResult(metadata: metadata, input: input, raw: result, id: UUID()) }
        selected = episode.id; document.chapters[0].episodes[0].content = "手で変えた本文"
        await #expect(throws: WritingError.self) { try await host.applyProofreadingResult(metadata: metadata, input: input, raw: result, id: UUID()) }
        #expect(edits == 0)
    }

    @Test func preflightFailureCanRetryWithoutDuplicatingInputs() async throws {
        let suite = "assistant-preflight.\(UUID())", defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let work = UUID(), document = NovelDocument(title: "合成", chapters: [])
        var records: [WritingEnvelope] = [], sends = 0, failures = 1
        let center = AssistantRequestCenter()
        var host = WritingAssistantHost(contextID: "session", workID: work, requestCenter: center,
                                        capture: { WritingCapture(workId: work, document: document, episodeId: nil) }, records: { _ in records },
                                        append: { record in
                                            if record.kind == "request", failures > 0 {
                                                failures -= 1; throw WritingError.unavailable
                                            }
                                            if !records.contains(where: { $0.id == record.id }) {
                                                records.append(WritingEnvelope(record: record))
                                            }
                                        }, synchronize: {}, apply: { _, _ in }, undo: { _ in })
        host.transmit = { _, _, _, _, _ in sends += 1; return "合成の感想" }
        let metadata = AssistantRequestRecord(purpose: .impressions, documentId: document.id, episodeId: nil, scope: "全話", permission: "感想")
        let key = host.requestKey(purpose: .impressions)
        _ = host.startRequest(metadata: metadata, input: "固定入力", defaults: defaults)
        while center.statuses[key]?.inFlight == true {
            await Task.yield()
        }
        #expect(sends == 0)
        try await host.retryLatest(key: key, defaults: defaults)
        while center.statuses[key]?.inFlight == true {
            await Task.yield()
        }
        #expect(sends == 1)
        #expect(records.count(where: { $0.record.kind == "request" }) == 2)
        #expect(host.recordedFeedback(records).count == 1)
    }

    @Test func crashAfterApplyingDoesNotOfferDuplicateExecution() async throws {
        let suite = "assistant-crash.\(UUID())", defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let work = UUID(), document = NovelDocument(title: "合成", chapters: []), id = UUID()
        let metadata = AssistantRequestRecord(purpose: .advice, documentId: document.id, episodeId: nil, conversationId: UUID(), scope: "本文なし", permission: "相談だけ")
        let sent = try WritingRecord(workId: work, kind: "request", key: id.uuidString.lowercased(), payload: WritingRecord.payload(metadata))
        var records = [WritingEnvelope(record: sent)]
        defaults.set([sent.key], forKey: WritingAssistantHost.localRequestsKey)
        var host = WritingAssistantHost(contextID: "session", workID: work, capture: { WritingCapture(workId: work, document: document, episodeId: nil) },
                                        records: { _ in records }, append: { records.append(WritingEnvelope(record: $0)) }, synchronize: {}, apply: { _, _ in }, undo: { _ in })
        host.editState = { _ in "applied" }
        let recovered = try await host.recoverInterruptedRequests(records, defaults: defaults)
        #expect(try AssistantRequestRecord.latest(recovered).first?.record.decoded(AssistantRequestRecord.self).state == "completed")
        await #expect(throws: WritingError.self) { try await host.retry(sent, entries: records, defaults: defaults) }
    }

    @Test func proofreadingResultStaysLocalWithoutFullBodyAndSurvivesRelaunch() async throws {
        let suite = "assistant-local-proof.\(UUID())", defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let work = UUID(), episode = Episode(title: "話", content: "元の本文" + String(repeating: "保存しない本文", count: 1000))
        let document = NovelDocument(title: "合成", chapters: [Chapter(title: "章", episodes: [episode])])
        var records: [WritingEnvelope] = [], applied: WritingEdit?
        let center = AssistantRequestCenter()
        var host = WritingAssistantHost(contextID: "session", workID: work, defaults: defaults, requestCenter: center,
                                        capture: { WritingCapture(workId: work, document: document, episodeId: episode.id) },
                                        records: { _ in records }, append: { records.append(WritingEnvelope(record: $0)) }, synchronize: {}, apply: { _, _ in }, undo: { _ in })
        host.transmit = { _, _, _, _, _ in #"{"changes":[{"before":"元","after":"新","reason":"誤字","check":"typo"}]}"# }
        host.applyExactProofreading = { edit, _, _, _ in applied = edit }
        let config = try AssistantConfiguration(endpoint: "https://example.invalid/responses", model: "synthetic", prompt: "指示", replacesManuscript: true)
        let input = try host.savedInput(config.request(manuscript: AssistantManuscript(title: "話", content: episode.content), apiKey: "synthetic"))
        let id = UUID(), metadata = AssistantRequestRecord(purpose: .proofreading, documentId: document.id, episodeId: episode.id, scope: "話", permission: "校正")
        #expect(host.startRequest(metadata: metadata, input: input, defaults: defaults, id: id))
        while center.statuses[host.requestKey(purpose: .proofreading)]?.inFlight == true {
            await Task.yield()
        }
        #expect(applied?.changes.count == 1)
        #expect(records.allSatisfy { $0.record.kind == "request" })
        #expect(!records.contains { $0.record.payload.contains("保存しない本文") })
        #expect(host.proofreadingEditIDs(defaults: defaults) == [id])
        let saved = try #require(host.proofreadingResult(id: id, defaults: defaults))
        let localData = try JSONEncoder().encode(saved)
        #expect(localData.count < 1000)
        #expect(saved.matches(episode.content))
        #expect(!saved.matches(episode.content + "変更"))
        let reloaded = try JSONDecoder().decode(AssistantLocalProofreading.self, from: localData)
        let display = try reloaded.display(on: episode.content + "変更", completed: false)
        #expect(display.accepted.isEmpty)
        #expect(display.rejected.count == 1)
    }

    @Test func relaunchedChatRebuildsCurrentContextWithoutDuplicatingQuestionOrReply() async throws {
        let suite = "assistant-chat-relaunch.\(UUID())", defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set("synthetic", forKey: "assistant.model")
        let work = UUID(), conversation = UUID(), oldRequest = UUID(), episode = Episode(title: "Episode", content: "current manuscript")
        let document = NovelDocument(title: "Synthetic", chapters: [Chapter(title: "Chapter", episodes: [episode])])
        let metadata = AssistantRequestRecord(purpose: .advice, documentId: document.id, episodeId: episode.id,
                                              conversationId: conversation, scope: "current", permission: "read-only")
        var records = try [
            WritingRecord(id: conversation, workId: work, kind: "conversation", key: "conversation",
                          payload: WritingRecord.payload(WritingConversation(title: "Question", documentId: document.id, readConsent: true))),
            WritingRecord(workId: work, kind: "message", key: conversation.uuidString.lowercased(),
                          payload: WritingRecord.payload(WritingMessage(role: "user", text: "Question", requestId: oldRequest))),
            WritingRecord(workId: work, kind: "request", key: oldRequest.uuidString.lowercased(), payload: WritingRecord.payload(metadata))
        ].map { WritingEnvelope(record: $0) }
        defaults.set([oldRequest.uuidString.lowercased()], forKey: WritingAssistantHost.localRequestsKey)
        var transmitted = ""
        let center = AssistantRequestCenter()
        var host = WritingAssistantHost(contextID: "relaunched", workID: work, defaults: defaults, requestCenter: center,
                                        capture: { WritingCapture(workId: work, document: document, episodeId: episode.id) },
                                        records: { _ in records }, append: { records.append(WritingEnvelope(record: $0)) }, synchronize: {}, apply: { _, _ in }, undo: { _ in })
        host.transmit = { input, _, _, _, _ in transmitted = input; return "Reply" }
        let recovered = try await host.recoverInterruptedRequests(records, defaults: defaults)
        let interrupted = try #require(AssistantRequestRecord.latest(recovered).first)
        #expect(try interrupted.record.decoded(AssistantRequestRecord.self).state == "interrupted")
        #expect(try await !host.retry(interrupted.record, entries: records, defaults: defaults))
        let history = WritingConversation.messages(records, conversation: conversation)
        #expect(try host.sendChat(question: history[0].text, conversation: conversation, isNew: false, history: [],
                                  scope: .advice, reference: .current, defaults: defaults, reusingQuestion: true))
        while center.statuses[host.requestKey(purpose: .advice, conversation: conversation)]?.inFlight == true {
            await Task.yield()
        }
        #expect(transmitted.contains("current manuscript"))
        #expect(!transmitted.contains("writing_turn"))
        let messages = WritingConversation.messages(records, conversation: conversation)
        #expect(messages.count(where: { $0.role == "user" }) == 1)
        #expect(messages.count(where: { $0.role == "assistant" }) == 1)
        #expect(records.count(where: { $0.record.kind == "message" }) == 2)
        #expect(!records.contains { $0.record.payload.contains("current manuscript") })
    }

    @Test func largeChatEditRemainsInPersistentHistory() async throws {
        let work = UUID(), document = NovelDocument(title: "合成", chapters: [])
        var records: [WritingEnvelope] = []
        let host = WritingAssistantHost(contextID: "session", workID: work, capture: { WritingCapture(workId: work, document: document, episodeId: nil) },
                                        records: { _ in records }, append: { records.append(WritingEnvelope(record: $0)) }, synchronize: {}, apply: { _, _ in }, undo: { _ in })
        let edit = WritingEdit(workId: work, documentId: document.id, changes: [WritingChange(path: ["synopsis"], before: .string(String(repeating: "前", count: 200_000)),
                                                                                              after: .string(String(repeating: "後", count: 200_000)))])
        try await host.appendEdit(edit)
        let record = try #require(records.first(where: { $0.record.kind == "edit" }))
        #expect(try host.decodedEdit(record.record, entries: records) == edit)
        #expect(records.allSatisfy { $0.record.payload.utf8.count <= 1_000_000 })
    }

    @Test func backgroundDeliveryRetryKeepsInputOnlyInMemory() async throws {
        let suite = "assistant-delivery.\(UUID())", defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let work = UUID(), document = NovelDocument(title: "合成", chapters: [])
        var records: [WritingEnvelope] = [], sentInputs: [String] = []
        let center = AssistantRequestCenter()
        var host = WritingAssistantHost(contextID: "session", workID: work, accountID: "account", requestCenter: center,
                                        capture: { WritingCapture(workId: work, document: document, episodeId: nil) },
                                        records: { _ in records }, append: { records.append(WritingEnvelope(record: $0)) }, synchronize: {}, apply: { _, _ in }, undo: { _ in })
        host.transmit = { input, _, _, _, heartbeat in
            sentInputs.append(input); heartbeat(AssistantProgress(phase: .working))
            if sentInputs.count == 1 {
                throw URLError(.networkConnectionLost)
            }
            return "合成の感想"
        }
        let metadata = AssistantRequestRecord(purpose: .impressions, documentId: document.id, episodeId: nil, scope: "全話", permission: "感想")
        let input = #"{"instructions":"合成指示","input":"固定した本文"}"#
        #expect(host.startRequest(metadata: metadata, input: input, defaults: defaults))
        #expect(!host.startRequest(metadata: metadata, input: "重複", defaults: defaults))
        let key = host.requestKey(purpose: .impressions)
        while center.statuses[key]?.inFlight == true {
            await Task.yield()
        }
        let failed = try #require(AssistantRequestRecord.latest(records).first)
        #expect(try failed.record.decoded(AssistantRequestRecord.self).state == "interrupted")
        #expect(center.statuses[key]?.failure?.contains("ネットワーク") == true)
        #expect(host.interrupted(failed.record, defaults: defaults))
        try await host.retry(failed.record, entries: records, defaults: defaults)
        while center.statuses[key]?.inFlight == true {
            await Task.yield()
        }
        #expect(sentInputs == [input, input])
        #expect(!records.contains { $0.record.payload.contains("固定した本文") })
        let relaunched = WritingAssistantHost(contextID: "new-session", workID: work, accountID: "account", requestCenter: AssistantRequestCenter(),
                                              capture: { WritingCapture(workId: work, document: document, episodeId: nil) },
                                              records: { _ in records }, append: { _ in }, synchronize: {}, apply: { _, _ in }, undo: { _ in })
        #expect(try await !relaunched.retry(failed.record, entries: records, defaults: defaults))
        #expect(host.recordedFeedback(records).count == 1)
        #expect(host.recordedFeedback(records).first?.markdown == "合成の感想")
        #expect(records.count(where: { $0.record.kind == "request" }) == 4)
    }
}

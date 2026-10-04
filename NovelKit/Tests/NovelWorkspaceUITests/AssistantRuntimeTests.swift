import Foundation
import NovelCore
@testable import NovelWorkspaceUI
import NovelWritingSupport
import Testing

struct AssistantRuntimeTests {
    @Test func responsesEventsAndTerminalFailures() throws {
        var stream = AssistantStream()
        #expect(try stream.consume(line: ": keepalive"))
        try frame(#"{"type":"response.in_progress"}"#, into: &stream)
        #expect(stream.progress.phase == .working)
        try frame(#"{"type":"response.output_text.delta","delta":"回答👩‍👩‍👧‍👦"}"#, into: &stream)
        #expect(stream.progress.characters == 3)
        #expect(stream.result == nil)
        #expect(throws: AssistantError.self) { try stream.completed() }
        try frame(#"{"type":"response.completed","response":{"status":"completed","output":[{"type":"message","content":[{"type":"output_text","text":"最終回答"}]}]}}"#, into: &stream)
        #expect(try stream.completed() == "最終回答")
        for type in ["response.failed", "error", "response.incomplete"] {
            var failed = AssistantStream()
            #expect(throws: AssistantError.self) {
                try frame("{\"type\":\"\(type)\",\"response\":{\"status\":\"incomplete\",\"incomplete_details\":{\"reason\":\"max_output_tokens\"},\"output\":[]}}", into: &failed)
            }
            #expect(failed.result == nil)
        }
    }

    @Test(arguments: ["stop", "length", "content_filter"])
    func chatRequiresDoneAndFinishReason(reason: String) throws {
        var stream = AssistantStream()
        try frame(#"{"choices":[{"index":0,"delta":{"role":"assistant"},"finish_reason":null}]}"#, into: &stream)
        #expect(stream.progress.phase == .working)
        try frame(#"{"choices":[{"index":0,"delta":{"content":"回答"},"finish_reason":null}]}"#, into: &stream)
        #expect(throws: AssistantError.self) { try stream.completed() }
        if reason == "content_filter" {
            #expect(throws: AssistantError.self) { try frame("{\"choices\":[{\"index\":0,\"delta\":{},\"finish_reason\":\"\(reason)\"}]}", into: &stream) }
        } else {
            try frame("{\"choices\":[{\"index\":0,\"delta\":{},\"finish_reason\":\"\(reason)\"}]}", into: &stream)
            #expect(stream.result == nil)
            try frame("[DONE]", into: &stream)
            #expect(try stream.completed().hasPrefix("回答"))
            #expect(try stream.completed().contains("途中まで") == (reason == "length"))
        }
    }

    @Test func streamingFallbackIsNarrow() {
        let unsupported = Data(#"{"error":{"param":"stream","message":"unsupported"}}"#.utf8)
        #expect(AssistantStream.rejectsStreaming(status: 400, data: unsupported))
        #expect(!AssistantStream.rejectsStreaming(status: 429, data: unsupported))
        #expect(!AssistantStream.rejectsStreaming(status: 400, data: Data(#"{"error":{"param":"model","message":"invalid model"}}"#.utf8)))
    }

    @Test @MainActor func singleFlightWatchdogWaitAndCancellation() async throws {
        let defaults = try #require(UserDefaults(suiteName: "assistant-runtime.\(UUID())"))
        let timing = AssistantRuntimeTiming(defaults: defaults, purpose: .advice)
        let center = AssistantRequestCenter(), key = AssistantRequestKey(work: UUID(), account: "test", lane: "chat")
        let id = UUID(), now = ContinuousClock.now
        let firstStarted = center.start(key: key, id: id, timing: timing, operation: { _, _ in try await Task.sleep(for: .seconds(3600)) })
        #expect(firstStarted)
        let duplicateStarted = center.start(key: key, timing: timing, operation: { _, _ in Issue.record("duplicate request") })
        #expect(!duplicateStarted)
        center.tick(key: key, id: id, timing: timing, now: now + .seconds(61))
        #expect(center.statuses[key]?.stalled == true)
        center.wait(key); #expect(center.statuses[key]?.stalled == false)
        center.heartbeat(key: key, id: id, progress: AssistantProgress(phase: .receiving, characters: 1234))
        #expect(center.statuses[key]?.progress.characters == 1234)
        center.tick(key: key, id: id, timing: timing, now: now + .seconds(181))
        while center.statuses[key]?.inFlight == true {
            await Task.yield()
        }
        #expect(center.statuses[key]?.failure?.contains("制限時間") == true)
        let retryStarted = center.start(key: key, timing: timing, operation: { _, _ in })
        #expect(retryStarted)
        while center.statuses[key]?.inFlight == true {
            await Task.yield()
        }
        #expect(center.statuses[key]?.failure == nil)
    }

    @Test @MainActor func elapsedOnlyAndTunables() async throws {
        let suite = "assistant-timing.\(UUID())", defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(9, forKey: AssistantRuntimeTiming.Key.stall)
        defaults.set(40, forKey: AssistantRuntimeTiming.Key.reviewMax)
        let timing = AssistantRuntimeTiming(defaults: defaults, purpose: .proofreading)
        #expect(timing.stallSeconds == 9); #expect(timing.maxSeconds == 40)
        let center = AssistantRequestCenter(), key = AssistantRequestKey(work: UUID(), account: "a", lane: "校正"), id = UUID()
        center.start(key: key, id: id, timing: timing, operation: { _, _ in try await Task.sleep(for: .seconds(3600)) })
        center.heartbeat(key: key, id: id, progress: AssistantProgress(phase: .elapsedOnly))
        center.tick(key: key, id: id, timing: timing, now: .now + .seconds(10))
        #expect(center.statuses[key]?.stalled == false)
        center.cancelAll()
        while center.statuses[key]?.inFlight == true {
            await Task.yield()
        }
    }

    @Test func requestChunksCannotBecomeConversationMessages() throws {
        let work = UUID(), conversation = UUID()
        let chunks = try AssistantRecordChunks.records(text: "保存された結果", key: "result:\(conversation.uuidString)", work: work)
        let message = try WritingRecord(workId: work, kind: "message", key: conversation.uuidString.lowercased(),
                                        payload: WritingRecord.payload(WritingMessage(role: "user", text: "質問")))
        let entries = (chunks + [message]).map { WritingEnvelope(record: $0) }
        let messages = WritingConversation.messages(entries, conversation: conversation)
        #expect(messages.count == 1)
        #expect(messages.first?.text == "質問")
    }

    @Test func unicodeChunksAndConversationRename() throws {
        let text = String(repeating: "日本語\n👩‍👩‍👧‍👦", count: 20000)
        let records = try AssistantRecordChunks.records(text: text, key: "result:test", work: UUID())
        #expect(records.count > 1)
        #expect(records.allSatisfy { $0.payload.utf8.count <= 1_000_000 })
        let entries = records.map { WritingEnvelope(record: $0) }
        #expect(try AssistantRecordChunks.text(entries: entries, key: "result:test") == text)
        #expect(throws: WritingError.self) { try AssistantRecordChunks.text(entries: Array(entries.dropFirst()), key: "result:test") }
        let originalID = UUID(), recoveredID = UUID()
        var recovered = try AssistantRecordChunks.records(text: text, key: "result:\(originalID.uuidString.lowercased())", work: UUID())
        for index in recovered.indices {
            recovered[index].key = recoveredID.uuidString.lowercased()
            var payload = try #require(JSONSerialization.jsonObject(with: Data(recovered[index].payload.utf8)) as? [String: Any])
            payload["requestId"] = recoveredID.uuidString.lowercased()
            recovered[index].payload = try String(decoding: JSONSerialization.data(withJSONObject: payload), as: UTF8.self)
        }
        #expect(try AssistantRecordChunks.text(entries: recovered.map { WritingEnvelope(record: $0) }, key: "result:\(recoveredID.uuidString.lowercased())") == text)
        let capture = WritingCapture(workId: UUID(), document: NovelDocument(title: "例", chapters: []), episodeId: nil)
        let root = try WritingConversation.recordForSending(selectedID: nil, conversations: [], capture: capture)
        let renamed = try WritingRecord(workId: capture.workId, kind: "conversation", key: root.id.uuidString.lowercased(), parentId: root.id,
                                        payload: WritingRecord.payload(WritingConversation(title: "新しい名前", documentId: capture.document.id, readConsent: true)))
        let displayed = WritingConversation.displayed([WritingEnvelope(record: root), WritingEnvelope(record: renamed)])
        #expect(displayed.count == 1); #expect(displayed.first?.id == root.id)
        #expect(try displayed.first?.record.decoded(WritingConversation.self).title == "新しい名前")
    }

    private func frame(_ data: String, into stream: inout AssistantStream) throws {
        _ = try stream.consume(line: "data: \(data)")
        _ = try stream.consume(line: "")
    }
}

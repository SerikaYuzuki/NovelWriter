import Foundation
@testable import FUMINIWA
import NovelCore
import NovelSyncV2
import NovelSyncV2Application
import NovelSyncV2Runtime
import NovelWritingSupport
import Testing

@MainActor
struct WritingAssistantIntegrationTests {
    @Test func appendingLocalRecordWakesSharedSchedulerAfterPersistence() async throws {
        let configuration = try TestRuntimeConfiguration(account: nil)
        let application = try await SnapshotSyncV2Runtime.makeApplication(mode: .test(configuration))
        let state = AppState(dependencies: AppDependencies(userDefaults: makeIsolatedTestUserDefaults()), initialStartupState: .ready)
        state.snapshotSyncV2Application = application
        let document = NovelDocument.newDocument(title: "同期wake"), work = WorkID(UUID())
        state.installV2Document(document, workID: work, createdAt: Date())
        #expect(await state.checkpointSnapshotSyncV2(document))
        let host = try #require(state.writingAssistantHost)
        let scheduler = try #require(host.syncScheduler)
        var calls = 0
        var waiter: CheckedContinuation<Void, Never>?
        scheduler.attach(contextID: host.contextID, foreground: true) {
            calls += 1
            waiter?.resume(); waiter = nil
        }
        if calls == 0 {
            await withCheckedContinuation { waiter = $0 }
        }
        let record = try WritingRecord(workId: host.capture().workId, kind: "prompt", key: "advice",
                                       payload: WritingRecord.payload(WritingPrompt(text: "作品別指示")))
        try await host.append(record)
        if calls < 2 {
            await withCheckedContinuation { waiter = $0 }
        }
        #expect(calls == 2)
        #expect(try await host.records(false).contains { $0.id == record.id })
        scheduler.setForeground(false, contextID: host.contextID)
        try await host.append(WritingRecord(workId: record.workId, kind: "prompt", key: "advice", parentId: record.id,
                                            payload: WritingRecord.payload(WritingPrompt(text: "更新"))))
        try await host.synchronizeNow()
        #expect(calls == 2)
        scheduler.detach(contextID: host.contextID)
    }

    @Test func composingWaitsAndRevalidatesInsteadOfDiscardingUnrelatedEdit() async throws {
        var attempts = 0
        let result = try await WritingCompositionBoundary.capture(timeout: .seconds(1)) {
            attempts += 1
            if attempts < 3 {
                throw AssistantError.composing
            }
            return "確定した本文"
        }
        #expect(result == "確定した本文")
        #expect(attempts == 3)
        attempts = 0
        await #expect(throws: WritingError.changedScope) {
            try await WritingCompositionBoundary.capture(timeout: .seconds(1)) {
                attempts += 1
                if attempts == 1 {
                    throw AssistantError.composing
                }
                throw WritingError.changedScope
            }
        }
    }

    @Test(arguments: [WritingMCPVersion.november2025, .july2026])
    func mcpLostResponseRetryReturnsDurableResultWithoutApplyingAgain(version: WritingMCPVersion) async throws {
        let configuration = try TestRuntimeConfiguration(account: nil)
        let application = try await SnapshotSyncV2Runtime.makeApplication(mode: .test(configuration))
        let state = AppState(dependencies: AppDependencies(userDefaults: makeIsolatedTestUserDefaults()), initialStartupState: .ready)
        state.snapshotSyncV2Application = application
        let document = NovelDocument.newDocument(title: "原題"), work = WorkID(UUID())
        state.installV2Document(document, workID: work, createdAt: Date())
        #expect(await state.checkpointSnapshotSyncV2(document))
        let host = try #require(state.writingAssistantHost), requestID = UUID()
        var args: [String: Any] = ["workId": work.description, "sessionId": host.contextID, "requestId": requestID.uuidString,
                                   "scope": ["paths": [["title"]], "appendOnly": false],
                                   "changes": [["path": ["title"], "before": "原題", "after": "新題"]]]
        func call() async throws -> [String: Any] {
            let request: [String: Any] = ["jsonrpc": "2.0", "id": 1, "method": "tools/call", "params": ["name": "edit_work", "arguments": args,
                                                                                                        "_meta": ["io.modelcontextprotocol/protocolVersion": version.rawValue,
                                                                                                                  "io.modelcontextprotocol/clientCapabilities": [:]]]]
            let response = try #require(await WritingMCPProtocol.respond(JSONSerialization.data(withJSONObject: request), host: host, version: version))
            let decoded = try #require(JSONSerialization.jsonObject(with: response) as? [String: Any])
            return try #require(decoded["result"] as? [String: Any])
        }
        #expect(try await call()["isError"] as? Bool == false)
        #expect(state.document.title == "新題")
        state.document.title = "後から手で修正"
        let replay = try await call()
        #expect(replay["isError"] as? Bool == false)
        #expect((replay["content"] as? [[String: String]])?.first?["text"]?.contains("\"replayed\":true") == true)
        #expect(state.document.title == "後から手で修正")
        args["changes"] = [["path": ["title"], "before": "後から手で修正", "after": "IDを使い回した別操作"]]
        #expect(try await call()["isError"] as? Bool == true)
        #expect(state.document.title == "後から手で修正")
    }

    @Test func scopedEditsSaveAndUndoWithoutLosingOtherChanges() async throws {
        let configuration = try TestRuntimeConfiguration(account: nil)
        let application = try await SnapshotSyncV2Runtime.makeApplication(mode: .test(configuration))
        let state = AppState(dependencies: AppDependencies(userDefaults: makeIsolatedTestUserDefaults()), initialStartupState: .ready)
        state.snapshotSyncV2Application = application
        let document = NovelDocument.newDocument(title: "原題"), work = WorkID(UUID())
        state.installV2Document(document, workID: work, createdAt: Date())
        #expect(await state.checkpointSnapshotSyncV2(document))
        let host = try #require(state.writingAssistantHost)
        let capture = try host.capture()
        let edit = WritingEdit(workId: capture.workId, documentId: document.id,
                               changes: [WritingChange(path: ["title"], before: .string("原題"), after: .string("新題"))])
        state.document.synopsis = "依頼中に変更"
        try await host.apply(edit, WritingGrant(paths: [["title"]]))
        #expect(state.document.title == "新題")
        #expect(state.document.synopsis == "依頼中に変更")
        #expect(try await application.openLocal(workID: work).document?.title == "新題")
        try await host.undo(edit.id)
        #expect(state.document.title == "原題")
        #expect(state.document.synopsis == "依頼中に変更")
        await #expect(throws: WritingError.self) { try await host.apply(edit, .wholeWork) }
        state.snapshotSyncV2AccountScopeGeneration &+= 1
        #expect(throws: WritingError.changedScope) { try host.capture() }
    }

    @Test(arguments: [WritingMCPVersion.november2025, .july2026])
    func mcpRequiresCurrentWorkSessionAndMechanicallyRestrictsScope(version: WritingMCPVersion) async throws {
        let document = NovelDocument.newDocument(), work = UUID()
        var attempted = 0
        let host = WritingAssistantHost(contextID: "active-session", capture: {
            WritingCapture(workId: work, document: document, episodeId: nil)
        }, records: { _ in [] }, append: { _ in }, synchronize: {}, apply: { edit, grant in
            _ = try edit.applying(to: document, grant: grant); attempted += 1
        }, undo: { _ in })
        func call(_ arguments: [String: Any]) async throws -> [String: Any] {
            let input: [String: Any] = ["jsonrpc": "2.0", "id": 1, "method": "tools/call", "params": [
                "name": "edit_work", "arguments": arguments,
                "_meta": ["io.modelcontextprotocol/protocolVersion": version.rawValue,
                          "io.modelcontextprotocol/clientCapabilities": [:]]
            ]]
            let bytes = try await WritingMCPProtocol.respond(JSONSerialization.data(withJSONObject: input), host: host, version: version)
            let response = try #require(bytes)
            return try #require(JSONSerialization.jsonObject(with: response) as? [String: Any])
        }
        var args: [String: Any] = ["workId": work.uuidString, "sessionId": "stale", "requestId": UUID().uuidString,
                                   "scope": ["paths": [["characters"]], "appendOnly": false],
                                   "changes": [["path": ["title"], "before": document.title, "after": "unauthorized"]]]
        #expect(try await (call(args)["result"] as? [String: Any])?["isError"] as? Bool == true)
        args["sessionId"] = "active-session"
        args["workId"] = UUID().uuidString
        #expect(try await (call(args)["result"] as? [String: Any])?["isError"] as? Bool == true)
        args["workId"] = work.uuidString
        #expect(try await (call(args)["result"] as? [String: Any])?["isError"] as? Bool == true)
        #expect(attempted == 0)
        args["scope"] = ["paths": [["title"]], "appendOnly": false]
        #expect(try await (call(args)["result"] as? [String: Any])?["isError"] as? Bool == false)
        #expect(attempted == 1)
    }
}

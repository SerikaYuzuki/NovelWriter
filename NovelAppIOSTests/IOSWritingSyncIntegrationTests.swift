import Foundation
@testable import FUMINIWAIOS
import NovelCore
import NovelSyncV2
import NovelSyncV2Application
import NovelWritingSupport
import Testing

@MainActor
struct IOSWritingSyncIntegrationTests {
    @Test func appendingLocalRecordWakesSharedSchedulerAfterPersistence() async throws {
        let defaults = try #require(UserDefaults(suiteName: "WritingSyncTests.\(UUID())"))
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let state = IOSDocumentStore(userDefaults: defaults, libraryRoot: root)
        await state.bootstrap()
        #expect(await state.makeNewDocument())
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
}

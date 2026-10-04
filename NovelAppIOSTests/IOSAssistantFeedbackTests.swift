import Foundation
@testable import FUMINIWAIOS
import NovelWorkspaceUI
import Testing

@MainActor
@Suite("iOS saved assistant feedback")
struct IOSAssistantFeedbackTests {
    @Test func saveReopenAndDelete() async throws {
        let suite = "feedback-ios.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(suite)
        defer { defaults.removePersistentDomain(forName: suite); try? FileManager.default.removeItem(at: root) }
        let store = IOSDocumentStore(userDefaults: defaults, libraryRoot: root)
        await store.bootstrap()
        #expect(await store.makeNewDocument())
        let session = try #require(store.currentDocumentSessionToken)
        let account = store.snapshotSyncV2AccountScope
        let original = store.document
        let feedback = AssistantFeedback(id: UUID(), purpose: .impressions, scopeTitle: "第一話",
                                         createdAt: Date(timeIntervalSince1970: 1_790_000_001), markdown: "# 感想\n\n続きが気になる。")
        #expect(await store.saveAssistantFeedback(feedback, session: session, account: account))
        #expect(await store.saveAssistantFeedback(feedback, session: session, account: account))
        #expect(store.assistantFeedback == [feedback])
        #expect(store.referenceAttachments.isEmpty)
        let reopened = IOSDocumentStore(userDefaults: defaults, libraryRoot: root)
        await reopened.bootstrap()
        #expect(reopened.assistantFeedback == [feedback])
        #expect(reopened.document == original)
        let newSession = try #require(reopened.currentDocumentSessionToken)
        #expect(await reopened.deleteAssistantFeedback(feedback, session: newSession, account: reopened.snapshotSyncV2AccountScope))
        #expect(reopened.assistantFeedback.isEmpty)
    }
}

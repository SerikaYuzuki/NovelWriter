import Foundation
@testable import FUMINIWA
import NovelCore
import NovelSyncV2
import NovelSyncV2Application
import NovelSyncV2Runtime
import Testing

@MainActor
@Suite("Assistant feedback persistence")
struct AssistantFeedbackPersistenceTests {
    @Test func savingReopeningAndDeletingPreservesManuscript() async throws {
        let configuration = try TestRuntimeConfiguration(account: nil)
        let application = try await SnapshotSyncV2Runtime.makeApplication(mode: .test(configuration))
        let state = AppState(dependencies: AppDependencies(userDefaults: makeIsolatedTestUserDefaults()), initialStartupState: .ready)
        state.snapshotSyncV2Application = application
        let document = NovelDocument.newDocument(title: "テスト作品")
        let workID = WorkID(UUID())
        state.installV2Document(document, workID: workID, createdAt: Date(timeIntervalSince1970: 1_790_000_000))
        #expect(await state.checkpointSnapshotSyncV2(document))
        let session = state.documentSessionToken
        let account = state.snapshotSyncV2AccountScopeToken
        let feedback = AssistantFeedback(id: UUID(), purpose: .advice, scopeTitle: "第一話",
                                         createdAt: Date(timeIntervalSince1970: 1_790_000_001), markdown: "# アドバイス\n\n動機を明確に。")
        let staleAccount = SnapshotSyncV2AccountScopeToken(accountID: "other", accountFence: "other", generation: 0)
        #expect(await !state.saveAssistantFeedback(feedback, session: session, account: staleAccount))
        #expect(state.assistantFeedback.isEmpty)
        #expect(await state.saveAssistantFeedback(feedback, session: session, account: account))
        #expect(await state.saveAssistantFeedback(feedback, session: session, account: account))
        #expect(state.assistantFeedback == [feedback])
        #expect(state.referenceAttachments.isEmpty)
        let restarted = try await SnapshotSyncV2Runtime.makeApplication(mode: .test(configuration))
        let opened = try await restarted.openLocal(workID: workID)
        #expect(opened.document == document)
        #expect(AssistantFeedback.list(opened.attachments) == [feedback])
        #expect(await state.deleteAssistantFeedback(feedback, session: session, account: account))
        #expect(state.assistantFeedback.isEmpty)
        #expect(try await restarted.openLocal(workID: workID).attachments.isEmpty)
        #expect(state.document == document)
    }
}

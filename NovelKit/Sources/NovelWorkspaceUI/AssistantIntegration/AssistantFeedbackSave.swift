import Foundation
import NovelWorkspace

@MainActor
public protocol WorkspaceFeedbackHost: WorkspaceHost {
    var assistantFeedback: [AssistantFeedback] { get }
    func feedbackSaveBoundary(session: WorkspaceSessionToken, account: WorkspaceAccountScope,
                              operation: @MainActor () async -> Bool) async -> Bool
    func importFeedbackAttachment(from url: URL, session: WorkspaceSessionToken, account: WorkspaceAccountScope) async -> Bool
}

@MainActor
public enum AssistantFeedbackSave {
    public static func save(_ feedback: AssistantFeedback, host: any WorkspaceFeedbackHost,
                            session: WorkspaceSessionToken, account: WorkspaceAccountScope) async -> Bool {
        guard feedback.purpose == .impressions else { return false }
        return await host.feedbackSaveBoundary(session: session, account: account) {
            if let existing = host.assistantFeedback.first(where: { $0.id == feedback.id }) {
                return existing == feedback
            }
            guard let url = try? feedback.temporaryFile() else { return false }
            defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
            return await host.importFeedbackAttachment(from: url, session: session, account: account)
        }
    }
}

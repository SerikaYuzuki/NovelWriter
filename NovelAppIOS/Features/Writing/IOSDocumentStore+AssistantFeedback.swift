import Foundation
import NovelCore
import NovelThumbnail
import NovelWorkspace
import NovelWorkspaceUI

extension IOSDocumentStore: WorkspaceFeedbackHost {
    var assistantFeedback: [AssistantFeedback] {
        attachments.compactMap { attachment in
            guard let bytes = workspaceAttachments[attachment.fileName]?.bytes else { return nil }
            return AssistantFeedback.decode(fileName: attachment.fileName, bytes: bytes)
        }.sorted { $0.createdAt == $1.createdAt ? $0.id.uuidString < $1.id.uuidString : $0.createdAt > $1.createdAt }
    }

    var referenceAttachments: [Attachment] {
        let feedbackNames = Set(assistantFeedback.map(\.fileName))
        return attachments.filter { !feedbackNames.contains($0.fileName) && !(ThumbnailOwner(fileName: $0.fileName)?.exists(in: document) ?? false) }
    }

    func saveAssistantFeedback(_ feedback: AssistantFeedback, session: WorkspaceSessionToken,
                               account: WorkspaceAccountScope) async -> Bool {
        await AssistantFeedbackSave.save(feedback, host: self, session: session, account: account)
    }

    func feedbackSaveBoundary(session: WorkspaceSessionToken, account: WorkspaceAccountScope,
                              operation: @MainActor () async -> Bool) async -> Bool {
        guard currentDocumentSessionToken == session, matchesSyncAccount(account),
              !syncV2AccountTransitionInProgress else { return false }
        return await operation()
    }

    func importFeedbackAttachment(from url: URL, session: WorkspaceSessionToken, account: WorkspaceAccountScope) async -> Bool {
        let saved = await importAttachment(from: url, expectedSession: session, expectedAccountScope: account)
        return saved != nil && currentDocumentSessionToken == session && matchesSyncAccount(account)
    }

    func deleteAssistantFeedback(_ feedback: AssistantFeedback, session: WorkspaceSessionToken,
                                 account: WorkspaceAccountScope) async -> Bool {
        guard currentDocumentSessionToken == session, matchesSyncAccount(account),
              assistantFeedback.contains(feedback),
              let attachment = attachments.first(where: { $0.fileName == feedback.fileName }) else { return false }
        return await deleteAttachment(attachment, expectedSession: session, expectedAccountScope: account)
    }
}

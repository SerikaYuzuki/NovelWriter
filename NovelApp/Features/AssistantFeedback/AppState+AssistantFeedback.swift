import NovelWorkspace
#if os(macOS)
import Foundation
import NovelCore
import NovelThumbnail
import NovelWorkspaceUI

extension AppState: WorkspaceFeedbackHost {
    var assistantFeedback: [AssistantFeedback] {
        let names = Set(workspaceModel.attachments.map(\.fileName))
        return AssistantFeedback.list(snapshotSyncV2Attachments.filter { names.contains($0.fileName) })
    }

    var referenceAttachments: [Attachment] {
        let feedbackNames = Set(assistantFeedback.map(\.fileName))
        return workspaceModel.attachments.filter { !feedbackNames.contains($0.fileName) && !(ThumbnailOwner(fileName: $0.fileName)?.exists(in: workspaceModel.document) ?? false) }
    }

    func saveAssistantFeedback(_ feedback: AssistantFeedback, session: WorkspaceSessionToken,
                               account: WorkspaceAccountScope) async -> Bool {
        await AssistantFeedbackSave.save(feedback, host: self, session: session, account: account)
    }

    func feedbackSaveBoundary(session: WorkspaceSessionToken, account: WorkspaceAccountScope,
                              operation: @MainActor () async -> Bool) async -> Bool {
        await mutateAssistantFeedback(session: session, account: account, operation: operation)
    }

    func importFeedbackAttachment(from url: URL, session: WorkspaceSessionToken, account _: WorkspaceAccountScope) async -> Bool {
        await addAttachmentWithinSaveBoundary(from: url, expectedSession: session) != nil
    }

    func deleteAssistantFeedback(_ feedback: AssistantFeedback, session: WorkspaceSessionToken,
                                 account: WorkspaceAccountScope) async -> Bool {
        await mutateAssistantFeedback(session: session, account: account) {
            guard self.assistantFeedback.contains(feedback),
                  let attachment = self.workspaceModel.attachments.first(where: { $0.fileName == feedback.fileName }) else { return false }
            return await self.deleteAttachmentWithinSaveBoundary(attachment, expectedSession: session)
        }
    }

    private func mutateAssistantFeedback(session: WorkspaceSessionToken, account: WorkspaceAccountScope,
                                         operation: () async -> Bool) async -> Bool {
        await documentOperationGate.perform {
            guard self.workspaceModel.documentSessionToken == session, self.snapshotSyncV2AccountScopeToken == account,
                  self.permitsDocumentInteraction else { return false }
            switch self.captureCommittedText() {
            case .compositionInProgress: return false
            case let .captured(text):
                guard let chapterID = self.workspaceModel.selectedChapterID, let episodeID = self.workspaceModel.selectedEpisodeID else { return false }
                self.updateEpisodeContent(text, for: episodeID, in: chapterID, expectedSession: session)
            case .notActive: break
            }
            let result = await self.saveCoordinator.performExclusiveAfterFlushing(flushAfter: true) {
                guard self.workspaceModel.documentSessionToken == session, self.snapshotSyncV2AccountScopeToken == account,
                      self.permitsDocumentInteraction, !Task.isCancelled else { return false }
                return await operation()
            }
            guard self.workspaceModel.documentSessionToken == session, self.snapshotSyncV2AccountScopeToken == account else { return false }
            if case let .completed(saved, _) = result {
                return saved
            }
            return false
        }
    }
}
#endif

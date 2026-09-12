#if os(macOS)
import Foundation
import NovelCore

extension AppState {
    var assistantFeedback: [AssistantFeedback] {
        let names = Set(attachments.map(\.fileName))
        return AssistantFeedback.list(snapshotSyncV2Attachments.filter { names.contains($0.fileName) })
    }

    var referenceAttachments: [Attachment] {
        let feedbackNames = Set(assistantFeedback.map(\.fileName))
        return attachments.filter { !feedbackNames.contains($0.fileName) }
    }

    func saveAssistantFeedback(_ feedback: AssistantFeedback, session: DocumentSessionToken,
                               account: SnapshotSyncV2AccountScopeToken) async -> Bool {
        await mutateAssistantFeedback(session: session, account: account) {
            if let existing = self.assistantFeedback.first(where: { $0.id == feedback.id }) {
                return existing == feedback
            }
            guard let url = try? feedback.temporaryFile() else { return false }
            defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
            return await self.addAttachment(from: url, expectedSession: session) != nil
        }
    }

    func deleteAssistantFeedback(_ feedback: AssistantFeedback, session: DocumentSessionToken,
                                 account: SnapshotSyncV2AccountScopeToken) async -> Bool {
        await mutateAssistantFeedback(session: session, account: account) {
            guard self.assistantFeedback.contains(feedback),
                  let attachment = self.attachments.first(where: { $0.fileName == feedback.fileName }) else { return false }
            return await self.deleteAttachment(attachment, expectedSession: session)
        }
    }

    private func mutateAssistantFeedback(session: DocumentSessionToken, account: SnapshotSyncV2AccountScopeToken,
                                         operation: () async -> Bool) async -> Bool {
        await documentOperationGate.perform {
            guard self.documentSessionToken == session, self.snapshotSyncV2AccountScopeToken == account,
                  self.permitsDocumentInteraction else { return false }
            switch self.activeCommittedTextCapture() {
            case .compositionInProgress: return false
            case let .captured(text):
                guard let chapterID = self.selectedChapterID, let episodeID = self.selectedEpisodeID else { return false }
                self.updateEpisodeContent(text, for: episodeID, in: chapterID, expectedSession: session)
            case .notActive: break
            }
            let result = await self.saveCoordinator.performExclusiveAfterFlushing(flushAfter: true) {
                guard self.documentSessionToken == session, self.snapshotSyncV2AccountScopeToken == account,
                      self.permitsDocumentInteraction, !Task.isCancelled else { return false }
                return await operation()
            }
            guard self.documentSessionToken == session, self.snapshotSyncV2AccountScopeToken == account else { return false }
            if case let .completed(saved, _) = result {
                return saved
            }
            return false
        }
    }
}
#endif

import Foundation
import NovelCore
import NovelThumbnail
import NovelWorkspaceUI

extension IOSDocumentStore {
    var assistantFeedback: [AssistantFeedback] {
        attachments.compactMap { attachment in
            guard let bytes = syncV2AttachmentPayloads[attachment.fileName] else { return nil }
            return AssistantFeedback.decode(fileName: attachment.fileName, bytes: bytes)
        }.sorted { $0.createdAt == $1.createdAt ? $0.id.uuidString < $1.id.uuidString : $0.createdAt > $1.createdAt }
    }

    var referenceAttachments: [Attachment] {
        let feedbackNames = Set(assistantFeedback.map(\.fileName))
        return attachments.filter { !feedbackNames.contains($0.fileName) && !(ThumbnailOwner(fileName: $0.fileName)?.exists(in: document) ?? false) }
    }

    func saveAssistantFeedback(_ feedback: AssistantFeedback, session: IOSDocumentSessionToken,
                               account: IOSSnapshotSyncV2AccountScope) async -> Bool {
        guard feedback.purpose == .impressions else { return false }
        guard currentDocumentSessionToken == session, matchesSyncAccount(account),
              !syncV2AccountTransitionInProgress else { return false }
        if let existing = assistantFeedback.first(where: { $0.id == feedback.id }) {
            return existing == feedback
        }
        guard let url = try? feedback.temporaryFile() else { return false }
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let saved = await importAttachment(from: url, expectedSession: session, expectedAccountScope: account)
        return saved != nil && currentDocumentSessionToken == session && matchesSyncAccount(account)
    }

    func deleteAssistantFeedback(_ feedback: AssistantFeedback, session: IOSDocumentSessionToken,
                                 account: IOSSnapshotSyncV2AccountScope) async -> Bool {
        guard currentDocumentSessionToken == session, matchesSyncAccount(account),
              assistantFeedback.contains(feedback),
              let attachment = attachments.first(where: { $0.fileName == feedback.fileName }) else { return false }
        return await deleteAttachment(attachment, expectedSession: session, expectedAccountScope: account)
    }
}

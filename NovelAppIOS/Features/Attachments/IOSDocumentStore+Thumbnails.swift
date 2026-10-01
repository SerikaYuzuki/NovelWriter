import Foundation
import NovelCore
import NovelSyncV2
import NovelThumbnail

extension IOSDocumentStore {
    /// Install the owner edit and its image removal without a suspension or intermediate checkpoint.
    func applyOwnerRemoval(_ replacement: NovelDocument) {
        let names = ThumbnailOwner.removedNames(from: document, to: replacement)
        for name in names {
            if let owner = ThumbnailOwner(fileName: name) {
                removeThumbnailWithOwner(owner)
            }
        }
        document = replacement
    }

    func thumbnailData(_ owner: ThumbnailOwner) -> Data? {
        syncV2AttachmentPayloads[owner.fileName]
    }

    /// No suspension between owner and attachment changes; autosave captures both.
    func removeThumbnailWithOwner(_ owner: ThumbnailOwner) {
        attachments.removeAll { $0.fileName == owner.fileName }
        syncV2AttachmentPayloads.removeValue(forKey: owner.fileName)
        syncV2AttachmentIDs.removeValue(forKey: owner.fileName)
    }

    func setThumbnail(_ bytes: Data?, owner: ThumbnailOwner, session: IOSDocumentSessionToken,
                      account: IOSSnapshotSyncV2AccountScope) async -> Bool {
        await documentOperationGate.perform {
            guard self.validateCurrentDocumentSession(session), self.snapshotSyncV2AccountScope == account,
                  !self.syncV2AccountTransitionInProgress,
                  self.synchronizeActiveEditorForAttachmentMutation(expectedSession: session),
                  let application = self.snapshotSyncV2Application, let work = self.syncV2ActiveWorkID else { return false }
            do {
                let result = try await self.saveCoordinator.performExclusiveAfterFlushing(flushAfter: true) {
                    guard self.validateCurrentDocumentSession(session), self.snapshotSyncV2AccountScope == account,
                          !self.syncV2AccountTransitionInProgress, owner.exists(in: self.document),
                          let previous = self.currentV2Attachments() else { return false }
                    var updated = previous.filter { $0.fileName != owner.fileName }
                    let item = bytes.map { SyncAttachment(attachmentId: UUID(), fileName: owner.fileName, bytes: $0) }
                    if let item {
                        updated.append(item)
                    }
                    // Checkpoint the candidate before changing live records. Concurrent owner edits survive.
                    _ = try await application.checkpoint(workID: work, document: self.document, reason: .explicit,
                                                         documentCreatedAt: self.documentCreatedAt, attachments: updated)
                    guard self.validateCurrentDocumentSession(session), self.snapshotSyncV2AccountScope == account,
                          owner.exists(in: self.document) else { return false }
                    self.removeThumbnailWithOwner(owner)
                    if let item {
                        self.attachments.append(Attachment(fileName: item.fileName, byteCount: Int64(item.byteCount)))
                        self.syncV2AttachmentPayloads[item.fileName] = item.bytes
                        self.syncV2AttachmentIDs[item.fileName] = item.attachmentId
                    }
                    return self.validateCurrentDocumentSession(session) && self.snapshotSyncV2AccountScope == account
                }
                if case let .completed(saved, flushed) = result {
                    return saved && flushed
                }
            } catch { self.operationErrorMessage = "画像を保存できませんでした。もう一度お試しください。" }
            return false
        }
    }
}

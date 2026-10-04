import Foundation
import NovelCore
import NovelSyncV2
import NovelThumbnail
import NovelWorkspace

extension AppState {
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
        snapshotSyncV2Attachments.first { $0.fileName == owner.fileName }?.bytes
    }

    /// Synchronous with the owner edit, before markDirty: both enter the same checkpoint.
    func removeThumbnailWithOwner(_ owner: ThumbnailOwner) {
        snapshotSyncV2Attachments.removeAll { $0.fileName == owner.fileName }
        attachments.removeAll { $0.fileName == owner.fileName }
        attachmentPreviewURLs.removeValue(forKey: owner.fileName)
    }

    func setThumbnail(_ bytes: Data?, owner: ThumbnailOwner, session: WorkspaceSessionToken,
                      account: WorkspaceAccountScope) async -> Bool {
        guard matchesSnapshotSyncV2AccountScope(account) else { return false }
        return await performSnapshotDataMutation(expectedSession: session) {
            guard self.snapshotSyncV2AccountScopeToken == account, owner.exists(in: self.document) else { return false }
            var updated = self.snapshotSyncV2Attachments.filter { $0.fileName != owner.fileName }
            let item = bytes.map { SyncAttachment(attachmentId: UUID(), fileName: owner.fileName, bytes: $0) }
            if let item {
                updated.append(item)
            }
            // Persist a candidate; do not roll back a whole live array over concurrent owner edits.
            guard await self.checkpointSnapshotSyncV2(self.document, reason: .explicit, attachments: updated),
                  self.documentSessionToken == session, self.snapshotSyncV2AccountScopeToken == account,
                  owner.exists(in: self.document) else { return false }
            self.removeThumbnailWithOwner(owner)
            if let item {
                self.snapshotSyncV2Attachments.append(item)
                self.attachments.append(Attachment(fileName: item.fileName, byteCount: Int64(item.byteCount)))
            }
            return true
        }
    }
}

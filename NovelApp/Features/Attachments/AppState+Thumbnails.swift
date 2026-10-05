import Foundation
import NovelCore
import NovelThumbnail
import NovelWorkspace

extension AppState {
    func applyOwnerRemoval(_ replacement: NovelDocument) {
        WorkspaceAttachmentCommands.applyOwnerRemoval(replacement, host: self)
    }

    func thumbnailData(_ owner: ThumbnailOwner) -> Data? {
        workspaceModel.attachmentSet[owner.fileName]?.bytes
    }

    func removeThumbnailWithOwner(_ owner: ThumbnailOwner) {
        installWorkspaceAttachments(workspaceModel.attachmentSet.removing(named: owner.fileName))
    }

    func setThumbnail(_ bytes: Data?, owner: ThumbnailOwner, session: WorkspaceSessionToken,
                      account: WorkspaceAccountScope) async -> Bool {
        guard matchesSnapshotSyncV2AccountScope(account), workspaceModel.documentSessionToken == session else { return false }
        let context = operationContext
        let commands = WorkspaceAttachmentCommands(host: self, boundary: { operation in
            await self.performSnapshotDataMutation(expectedSession: session, operation: operation)
        }, checkpoint: { document, candidate in
            await self.checkpointSnapshotSyncV2(document, reason: .explicit, attachments: candidate.records)
        })
        return await commands.setThumbnail(bytes, owner: owner, context: context)
    }
}

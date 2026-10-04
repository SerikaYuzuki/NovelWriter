import Foundation
import NovelCore
import NovelThumbnail
import NovelWorkspace

extension IOSDocumentStore {
    func applyOwnerRemoval(_ replacement: NovelDocument) {
        WorkspaceAttachmentCommands.applyOwnerRemoval(replacement, host: self)
    }

    func thumbnailData(_ owner: ThumbnailOwner) -> Data? {
        workspaceModel.attachmentSet[owner.fileName]?.bytes
    }

    func setThumbnail(_ bytes: Data?, owner: ThumbnailOwner, session: WorkspaceSessionToken,
                      account: WorkspaceAccountScope) async -> Bool {
        await documentOperationGate.perform {
            guard self.validateCurrentDocumentSession(session), self.snapshotSyncV2AccountScope == account,
                  !self.syncV2AccountTransitionInProgress,
                  self.synchronizeActiveEditorForAttachmentMutation(expectedSession: session),
                  self.snapshotSyncV2Application != nil, self.workspaceModel.activeWorkID != nil else { return false }
            return await self.attachmentCommands(
                checkpointFailure: "画像を保存できませんでした。もう一度お試しください。", requiresPostSave: true
            ).setThumbnail(bytes, owner: owner, context: self.operationContext)
        }
    }
}

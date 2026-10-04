import NovelCore
import NovelWorkspace

extension IOSDocumentStore: WorkspaceAttachmentHost {
    /// Required by the shared coordinator port; app call sites use workspaceModel.
    var document: NovelDocument {
        get { workspaceModel.document }
        set {
            workspaceModel.document = newValue
            workspaceModel.documentSessionToken.documentID = newValue.id
        }
    }

    var operationContext: WorkspaceOperationContext {
        WorkspaceOperationContext(
            workID: workspaceModel.activeWorkID, session: currentDocumentSessionToken,
            account: snapshotSyncV2AccountScope, editGeneration: workspaceModel.editGeneration
        )
    }

    var permitsLocalMutation: Bool {
        startupState == .ready && workspaceModel.activeWorkID != nil
            && !workspaceModel.isDocumentTransitionInProgress && !syncV2AccountTransitionInProgress
            && workspaceModel.keepBothPendingWorkID == nil
    }

    func markChanged(policy: WorkspaceSavePolicy) {
        markDocumentChanged()
        if policy == .flushNow {
            Task { @MainActor [weak self] in _ = await self?.saveNow() }
        }
    }
}

import NovelWorkspace

extension IOSDocumentStore: WorkspaceAttachmentHost {
    var operationContext: WorkspaceOperationContext {
        WorkspaceOperationContext(
            workID: workspaceModel.activeWorkID, session: currentDocumentSessionToken,
            account: snapshotSyncV2AccountScope, editGeneration: workspaceModel.editGeneration
        )
    }

    var permitsLocalMutation: Bool {
        startupState == .ready && syncV2ActiveWorkID != nil
            && !isDocumentTransitionInProgress && !syncV2AccountTransitionInProgress
            && syncV2KeepBothPendingWorkID == nil
    }

    func markChanged(policy: WorkspaceSavePolicy) {
        markDocumentChanged()
        if policy == .flushNow {
            Task { @MainActor [weak self] in _ = await self?.saveNow() }
        }
    }
}

import NovelWorkspace

extension IOSDocumentStore: WorkspaceHost {
    var operationContext: WorkspaceOperationContext {
        WorkspaceOperationContext(
            workID: syncV2ActiveWorkID, session: currentDocumentSessionToken,
            account: snapshotSyncV2AccountScope, editGeneration: localEditGeneration
        )
    }

    var permitsLocalMutation: Bool {
        startupState == .ready && syncV2ActiveWorkID != nil
            && !isDocumentTransitionInProgress && !syncV2AccountTransitionInProgress
    }

    func markChanged(policy: WorkspaceSavePolicy) {
        markDocumentChanged()
        if policy == .flushNow {
            Task { @MainActor [weak self] in _ = await self?.saveNow() }
        }
    }
}

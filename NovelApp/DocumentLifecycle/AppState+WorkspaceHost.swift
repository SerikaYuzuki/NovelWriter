import NovelWorkspace

extension AppState: WorkspaceAttachmentHost {
    var operationContext: WorkspaceOperationContext {
        WorkspaceOperationContext(
            workID: currentSnapshotSyncV2WorkID, session: workspaceModel.documentSessionToken,
            account: snapshotSyncV2AccountScopeToken, editGeneration: workspaceModel.editGeneration
        )
    }

    func projectFeatureCommands(_ policy: WorkspaceSavePolicy) -> ProjectFeatureCommands {
        ProjectFeatureCommands(host: self, policy: policy)
    }

    var permitsLocalMutation: Bool {
        permitsDocumentInteraction
    }

    func markChanged(policy: WorkspaceSavePolicy) {
        saveCoordinator.markDirty()
        switch policy {
        case .flushNow: flushSaveImmediately()
        case .debounced: saveCoordinator.scheduleDebouncedSave()
        }
    }
}

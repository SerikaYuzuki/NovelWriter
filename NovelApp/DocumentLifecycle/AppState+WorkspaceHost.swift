import NovelWorkspace

extension AppState: WorkspaceHost {
    var operationContext: WorkspaceOperationContext {
        WorkspaceOperationContext(
            workID: currentSnapshotSyncV2WorkID, session: documentSessionToken,
            account: snapshotSyncV2AccountScopeToken, editGeneration: editorContentGeneration
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

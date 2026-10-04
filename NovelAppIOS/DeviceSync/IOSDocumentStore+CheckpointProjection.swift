import NovelSyncV2Application
import NovelWorkspace

extension IOSDocumentStore {
    func workspaceCheckpointCoordinator(_ application: SyncV2Application) -> CheckpointCoordinator {
        var coordinator = CheckpointCoordinator(application: application)
        #if FUMINIWA_TEST_COMPOSITION
        if let workspaceCheckpointOverride {
            coordinator.checkpoint = workspaceCheckpointOverride
        }
        #endif
        return coordinator
    }

    /// Worker projections never overwrite a newer dirty editor revision.
    /// The local-save boundary alone consumes the durability projection.
    func applyCheckpointSaveState(_ state: SyncUIState) {
        if let localState = WorkspaceSyncProjection(state: state, previous: nil, presentedFailure: nil).localSaveState {
            saveState = localState
        }
    }
}

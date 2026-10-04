import Foundation
import NovelSyncV2Application
import NovelWorkspace

extension IOSDocumentStore {
    /// The root view owns this subscription, just as the macOS Workbench does.
    /// Events never install bytes directly: adoption re-enters the document gate.
    func observeSnapshotSyncV2Status() async {
        guard let application = snapshotSyncV2Application,
              workspaceModel.activeWorkID != nil else { return }
        await workspaceCheckpointCoordinator(application).observe(
            application: application, host: self,
            isCurrent: { self.snapshotSyncV2Application === application },
            permitsProjection: { !self.isSyncV2RemoteAccountTransitionActive },
            apply: { self.applySnapshotSyncV2State($0) }
        )
    }
}

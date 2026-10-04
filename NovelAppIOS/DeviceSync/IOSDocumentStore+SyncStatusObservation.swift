import Foundation
import NovelSyncV2Application
import NovelWorkspace

extension IOSDocumentStore {
    /// The root view owns this subscription, just as the macOS Workbench does.
    /// Events never install bytes directly: adoption re-enters the document gate.
    func observeSnapshotSyncV2Status() async {
        guard let application = snapshotSyncV2Application,
              let workID = syncV2ActiveWorkID else { return }
        let operation = WorkspaceOperationContext(workID: currentDocumentSessionToken?.workID,
                                                  session: currentDocumentSessionToken,
                                                  account: snapshotSyncV2AccountScope, editGeneration: nil)
        for await event in await application.stateChanges(for: workID) {
            guard !Task.isCancelled, matchesSyncOperation(operation),
                  snapshotSyncV2Application === application else { return }
            guard event.concerns(workID), !isSyncV2RemoteAccountTransitionActive else { continue }
            let state = await application.uiState(workID: workID)
            guard !Task.isCancelled, matchesSyncOperation(operation),
                  !isSyncV2RemoteAccountTransitionActive else { return }
            applySnapshotSyncV2State(state)
        }
    }
}

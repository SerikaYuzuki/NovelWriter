import Foundation

extension AppState {
    /// Owned by the Workbench task, so closing/changing work or account cancels
    /// the subscription. A toolbar overflow must not own this lifecycle.
    func observeSnapshotSyncV2Status() async {
        guard let application = snapshotSyncV2Application else { return }
        let session = documentSessionToken
        let account = snapshotSyncV2AccountScopeToken
        for await _ in await application.stateChanges() {
            guard !Task.isCancelled,
                  documentSessionToken == session,
                  snapshotSyncV2AccountScopeToken == account,
                  snapshotSyncV2Application === application else { return }
            await refreshSnapshotSyncV2UIState()
        }
    }
}

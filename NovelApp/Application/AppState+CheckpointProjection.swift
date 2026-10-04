import NovelSyncV2Application
import NovelWorkspace
import SwiftUI

extension AppState {
    func workspaceCheckpointCoordinator(_ application: SyncV2Application) -> CheckpointCoordinator {
        var coordinator = CheckpointCoordinator(application: application)
        coordinator.checkpoint = { [self] request in
            try await checkpointSnapshotSyncV2(
                using: application, workID: request.workID, document: request.document,
                reason: request.reason, documentCreatedAt: request.documentCreatedAt,
                attachments: request.attachments, resources: request.resources
            )
        }
        return coordinator
    }

    func applyCheckpointSaveState(_ state: SyncUIState) {
        if let localState = WorkspaceSyncProjection(state: state, previous: nil, presentedFailure: nil).localSaveState {
            saveState = localState
        }
    }

    func applySnapshotSyncV2State(_ state: SyncUIState?) {
        guard state == nil || state?.workID == currentSnapshotSyncV2WorkID else { return }
        let account = snapshotSyncV2AccountScopeToken
        let projection = WorkspaceSyncProjection(
            state: state, previous: snapshotSyncV2UIState,
            presentedFailure: state.flatMap { presentedSyncFailures[account]?[$0.workID] }
        )
        if projection.announcesHistoryWait {
            AccessibilityNotification.Announcement(SyncV2HistoryFetchState.conflictWaiting).post()
        }
        snapshotSyncV2UIState = state
        snapshotSyncConflict = state?.conflict
        if projection.authenticationRequired, case .signedIn = authUIState {
            authUIState = .failed("認証の有効期限が切れました。Appleで再サインインしてください。原稿はこの端末に保存されています。")
        }
        if let workID = state?.workID {
            if let reason = projection.presentedFailure {
                presentedSyncFailures[account, default: [:]][workID] = reason
            } else if projection.clearsPresentedFailure {
                presentedSyncFailures[account]?[workID] = nil
            }
        }
        if let message = projection.failureMessage {
            operationMessage = message
        }
        if case .readyForSafeAdoption = state?.remoteProgress {
            scheduleAutomaticServerAdoption()
        }
    }
}

import Foundation
import NovelCore
import NovelWorkspace
import SwiftUI

extension AppState {
    func runAutomaticSnapshotSyncV2() async {
        guard startupState.isReady,
              let application = snapshotSyncV2Application,
              let workID = currentSnapshotSyncV2WorkID else { return }
        let session = workspaceModel.documentSessionToken
        let account = snapshotSyncV2AccountScopeToken
        await application.observeForegroundSynchronization(workID: workID) { [weak self] in
            await self?.refreshAutomaticSnapshotSyncV2(session: session, account: account)
        }
    }

    private func refreshAutomaticSnapshotSyncV2(
        session: WorkspaceSessionToken, account: WorkspaceAccountScope
    ) async {
        guard !Task.isCancelled, workspaceModel.documentSessionToken == session,
              matchesSnapshotSyncV2AccountScope(account) else { return }
        await refreshSnapshotSyncV2UIState()
    }

    /// Owned by the Workbench task, so closing/changing work or account cancels
    /// the subscription. A toolbar overflow must not own this lifecycle.
    func observeSnapshotSyncV2Status() async {
        guard let application = snapshotSyncV2Application,
              currentSnapshotSyncV2WorkID != nil else { return }
        await workspaceCheckpointCoordinator(application).observe(
            application: application, host: self,
            isCurrent: { self.snapshotSyncV2Application === application },
            apply: { self.applySnapshotSyncV2State($0) }
        )
    }
}

private struct SyncStatusObservationID: Hashable {
    let session: WorkspaceSessionToken
    let account: WorkspaceAccountScope
    var chapter: ChapterID?
    var episode: EpisodeID?
    var isActive = true
}

struct SnapshotSyncObservationModifier: ViewModifier {
    @Environment(WorkspaceModel.self) private var workspace
    @Environment(AppState.self) private var appState
    @Environment(\.scenePhase) private var scenePhase

    func body(content: Content) -> some View {
        content
            .task(id: SyncStatusObservationID(
                session: workspace.documentSessionToken, account: appState.snapshotSyncV2AccountScopeToken
            )) {
                await appState.observeSnapshotSyncV2Status()
            }
            .task(id: SyncStatusObservationID(
                session: workspace.documentSessionToken, account: appState.snapshotSyncV2AccountScopeToken,
                chapter: workspace.selectedChapterID, episode: workspace.selectedEpisodeID,
                isActive: scenePhase == .active && !workspace.isDocumentTransitionInProgress
            )) {
                if scenePhase == .active, !workspace.isDocumentTransitionInProgress {
                    await appState.runAutomaticSnapshotSyncV2()
                }
            }
    }
}

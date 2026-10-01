import Foundation
import SwiftUI

extension AppState {
    func runAutomaticSnapshotSyncV2() async {
        guard startupState.isReady,
              let application = snapshotSyncV2Application,
              let workID = currentSnapshotSyncV2WorkID else { return }
        let session = documentSessionToken
        let account = snapshotSyncV2AccountScopeToken
        await application.observeForegroundSynchronization(workID: workID) { [weak self] in
            await self?.refreshAutomaticSnapshotSyncV2(session: session, account: account)
        }
    }

    private func refreshAutomaticSnapshotSyncV2(
        session: AppDocumentSessionToken, account: SnapshotSyncV2AccountScopeToken
    ) async {
        guard !Task.isCancelled, documentSessionToken == session,
              matchesSnapshotSyncV2AccountScope(account) else { return }
        await refreshSnapshotSyncV2UIState()
    }

    /// Owned by the Workbench task, so closing/changing work or account cancels
    /// the subscription. A toolbar overflow must not own this lifecycle.
    func observeSnapshotSyncV2Status() async {
        guard let application = snapshotSyncV2Application,
              let workID = currentSnapshotSyncV2WorkID else { return }
        let session = documentSessionToken
        let account = snapshotSyncV2AccountScopeToken
        for await _ in await application.stateChanges(for: workID) {
            guard !Task.isCancelled,
                  documentSessionToken == session,
                  matchesSnapshotSyncV2AccountScope(account),
                  snapshotSyncV2Application === application else { return }
            await refreshSnapshotSyncV2UIState()
        }
    }
}

private struct SyncStatusObservationID: Hashable {
    let session: AppDocumentSessionToken
    let account: SnapshotSyncV2AccountScopeToken
    var isActive = true
}

struct SnapshotSyncObservationModifier: ViewModifier {
    @Environment(AppState.self) private var appState
    @Environment(\.scenePhase) private var scenePhase

    func body(content: Content) -> some View {
        content
            .task(id: SyncStatusObservationID(
                session: appState.documentSessionToken, account: appState.snapshotSyncV2AccountScopeToken
            )) {
                await appState.observeSnapshotSyncV2Status()
            }
            .task(id: SyncStatusObservationID(
                session: appState.documentSessionToken, account: appState.snapshotSyncV2AccountScopeToken,
                isActive: scenePhase == .active
            )) {
                if scenePhase == .active {
                    await appState.runAutomaticSnapshotSyncV2()
                }
            }
    }
}

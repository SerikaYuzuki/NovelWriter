import Foundation
import NovelSyncV2
import NovelSyncV2Application
import NovelWorkspace

extension AppState {
    var snapshotSyncV2RemoteOnlyOpenTask: Task<Bool, Never>? {
        get { syncSessionController.remoteOnlyTask }
        set { syncSessionController.remoteOnlyTask = newValue }
    }

    var snapshotSyncV2RemoteOnlyOpenToken: UUID? {
        get { syncSessionController.remoteOnlyOwner }
        set { syncSessionController.remoteOnlyOwner = newValue }
    }

    var snapshotSyncV2RemoteOnlyOpeningWorkID: WorkID? {
        get { syncSessionController.remoteOnlyWorkID }
        set { syncSessionController.remoteOnlyWorkID = newValue }
    }

    var snapshotSyncV2RemoteOnlyOpenStartedAt: Date? {
        get { syncSessionController.remoteOnlyStartedAt }
        set { syncSessionController.remoteOnlyStartedAt = newValue }
    }

    var libraryPrefetchTask: Task<Void, Never>? {
        get { syncSessionController.prefetchTask }
        set { syncSessionController.prefetchTask = newValue }
    }

    var libraryPrefetchWorkID: WorkID? {
        get { syncSessionController.prefetchWorkID }
        set { syncSessionController.prefetchWorkID = newValue }
    }

    var snapshotSyncAutoAdoptionTask: Task<Void, Never>? {
        get { syncSessionController.reprojectionTask }
        set { syncSessionController.reprojectionTask = newValue }
    }

    var snapshotSyncV2AutoAdoptionToken: UUID? {
        get { syncSessionController.reprojectionOwner }
        set { syncSessionController.reprojectionOwner = newValue }
    }

    var snapshotSyncV2AccountScopeGeneration: UInt64 {
        get { syncSessionController.accountGeneration }
        set { syncSessionController.accountGeneration = newValue }
    }

    var authOperationOwner: UUID? {
        get { syncSessionController.accountOwner }
        set { syncSessionController.accountOwner = newValue }
    }
}

extension AppState {
    func matchesSyncOperation(_ expected: WorkspaceOperationContext) -> Bool {
        expected.isCurrent(WorkspaceOperationContext(
            workID: currentSnapshotSyncV2WorkID, session: documentSessionToken,
            account: snapshotSyncV2AccountScopeToken,
            editGeneration: expected.editGeneration == nil ? nil : editorContentGeneration
        ))
    }
}

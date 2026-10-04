import Foundation
import NovelSyncV2
import NovelSyncV2Application
import NovelWorkspace

extension IOSDocumentStore {
    var snapshotSyncV2RemoteOnlyOpenTask: Task<Void, Never>? {
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

    var snapshotSyncV2ReprojectionTask: Task<Void, Never>? {
        get { syncSessionController.reprojectionTask }
        set { syncSessionController.reprojectionTask = newValue }
    }

    var snapshotSyncV2ReprojectionToken: UUID? {
        get { syncSessionController.reprojectionOwner }
        set { syncSessionController.reprojectionOwner = newValue }
    }

    var syncV2AccountTransitionRequestOwner: UUID? {
        get { syncSessionController.accountOwner }
        set { syncSessionController.accountOwner = newValue }
    }

    var syncV2AccountTransitionRequested: Bool {
        get { syncSessionController.accountTransitionRequested }
        set { syncSessionController.accountTransitionRequested = newValue }
    }

    var syncV2AccountTransitionInProgress: Bool {
        get { syncSessionController.accountTransitionInProgress }
        set { syncSessionController.accountTransitionInProgress = newValue }
    }

    var syncV2RemoteSuspensionToken: SyncV2AccountTransitionRemoteSuspensionToken? {
        get { syncSessionController.remoteSuspension }
        set { syncSessionController.remoteSuspension = newValue }
    }

    func matchesSyncAccount(_ expected: IOSSnapshotSyncV2AccountScope?) -> Bool {
        guard let expected else { return false }
        return syncSessionController.matchesAccount(expected, current: snapshotSyncV2AccountScope)
    }

    func matchesRemoteSyncAccount(_ expected: IOSSnapshotSyncV2AccountScope) -> Bool {
        syncSessionController.matchesAccount(expected, current: snapshotSyncV2AccountScope,
                                             transitionActive: isSyncV2RemoteAccountTransitionActive)
    }

    func matchesLocalSyncAccount(_ expected: IOSSnapshotSyncV2AccountScope) -> Bool {
        syncSessionController.matchesAccount(expected, current: snapshotSyncV2AccountScope,
                                             transitionActive: isSyncV2AccountTransitionActive)
    }
}

extension IOSDocumentStore {
    typealias SyncOperationContext = SyncSessionController<IOSDocumentSessionToken?, IOSSnapshotSyncV2AccountScope, Void>.OperationContext

    func matchesSyncOperation(_ expected: SyncOperationContext) -> Bool {
        expected.isCurrent(SyncOperationContext(
            workID: currentDocumentSessionToken?.workID, session: currentDocumentSessionToken,
            account: snapshotSyncV2AccountScope,
            editGeneration: expected.editGeneration == nil ? nil : localEditGeneration
        ))
    }
}

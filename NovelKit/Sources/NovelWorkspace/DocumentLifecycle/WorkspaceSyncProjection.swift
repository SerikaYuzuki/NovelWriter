import NovelSyncV2Application

/// Shared effects; adapters retain their observable properties and UI APIs.
public struct WorkspaceSyncProjection {
    public let state: SyncUIState?
    public let announcesHistoryWait: Bool
    public let authenticationRequired: Bool
    public let failureMessage: String?
    public let presentedFailure: SyncV2FatalReason?
    public let clearsPresentedFailure: Bool
    public let localSaveState: WorkspaceSaveState?

    public init(state: SyncUIState?, previous: SyncUIState?, presentedFailure: SyncV2FatalReason?) {
        self.state = state
        announcesHistoryWait = state?.remoteProgress == .retryable(.historyIncomplete)
            && previous?.remoteProgress != state?.remoteProgress
        authenticationRequired = state?.remoteProgress == .authenticationRequired
        if case let .failed(reason) = state?.remoteProgress {
            self.presentedFailure = reason
            failureMessage = reason == presentedFailure ? nil : reason.japaneseDescription
        } else {
            self.presentedFailure = nil
            failureMessage = nil
        }
        clearsPresentedFailure = state != nil && state?.lastFailure == nil
            && (state?.remoteProgress == .idle || state?.remoteProgress == .noChanges)
        localSaveState = switch state?.localDurability {
        case .unsaved: .dirty
        case .saving: .saving
        case .saved: .saved
        case .failed: .failed
        case nil: nil
        }
    }
}

import Foundation
import NovelSyncV2

public enum SyncV2LocalDurability: Equatable, Sendable {
    case unsaved
    case saving
    case saved(generation: Int64, snapshotID: SnapshotID)
    case failed
}

public enum SyncV2RemoteProgress: Equatable, Sendable {
    case idle
    case noChanges
    case pending
    case syncing(operationID: UUID)
    case offline
    case authenticationRequired
    case fenceChanged
    case parkedDifferentAccount
    case quarantined(SyncV2QuarantineReason)
    case retryable(SyncV2RetryReason)
    case needsChoice
    case readyForSafeAdoption(inboxID: UUID)
    case failed(SyncV2FatalReason)
    case receiptMismatch

    public var japaneseLabel: String {
        switch self {
        case .idle, .noChanges: "同期済み"
        case .pending: "同期待ち"
        case .syncing: "同期中"
        case .offline: "端末に保存済み・通信待ち"
        case .authenticationRequired: "サインインすると同期します"
        case .fenceChanged: "アカウントの安全確認が必要です"
        case .parkedDifferentAccount: "別のアカウントのため保留中"
        case .quarantined: "安全確認後に同期を再開します"
        case .retryable: "端末に保存済み・同期を再試行します"
        case .needsChoice: "競合の確認が必要です"
        case .readyForSafeAdoption: "サーバーの版を適用できます"
        case .failed, .receiptMismatch: "同期を再試行できます"
        }
    }
}

public enum SyncV2TypedResult: Equatable, Sendable {
    case checkpointed
    case noChanges
    case queued
    case sent
    case conflictPending
    case staleConflictAction
    case restored
    case remoteOnlyInstalled
    case adoptionPending
    case failure(SyncV2Failure)
}

public struct SyncUIState: Equatable, Sendable {
    public let workID: WorkID
    public let localDurability: SyncV2LocalDurability
    public let remoteProgress: SyncV2RemoteProgress
    public let conflict: SyncV2ConflictProjection?
    public let lastTypedResult: SyncV2TypedResult
    public let lastFailure: SyncV2Failure?

    public init(
        workID: WorkID,
        localDurability: SyncV2LocalDurability,
        remoteProgress: SyncV2RemoteProgress,
        conflict: SyncV2ConflictProjection? = nil,
        lastTypedResult: SyncV2TypedResult,
        lastFailure: SyncV2Failure? = nil
    ) {
        self.workID = workID
        self.localDurability = localDurability
        self.remoteProgress = remoteProgress
        self.conflict = conflict
        self.lastTypedResult = lastTypedResult
        self.lastFailure = lastFailure
    }

    public var japaneseLabel: String {
        remoteProgress.japaneseLabel
    }
}

enum SyncV2ConflictUpdate: Sendable {
    case retain
    case set(SyncV2ConflictProjection)
    case clear
}

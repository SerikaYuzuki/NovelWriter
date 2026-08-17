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
    case syncing(commandID: UUID)
    case offline
    case parked(reason: String)
    case quarantined(reason: String)
    case needsChoice
    case failed

    public var japaneseLabel: String {
        switch self {
        case .idle, .noChanges: "同期済み"
        case .syncing: "同期中"
        case .offline: "端末に保存済み・通信待ち"
        case .parked: "別のアカウントのため保留中"
        case .quarantined: "安全確認後に同期を再開します"
        case .needsChoice: "競合の確認が必要です"
        case .failed: "同期を再試行できます"
        }
    }
}

public struct SyncV2ConflictProjection: Hashable, Sendable {
    public let conflictID: UUID
    public let revision: Int64
    public let baseSnapshotID: SnapshotID?
    public let localSnapshotID: SnapshotID
    public let remoteSnapshotID: SnapshotID
    public let sourceGeneration: Int64
    public let commandID: UUID?
}

public enum SyncV2TypedResult: Equatable, Sendable {
    case checkpointed
    case noChanges
    case queued
    case sent
    case conflictPending
    case staleConflictAction
    case restored
    case offline
    case failed
}

public struct SyncUIState: Equatable, Sendable {
    public let workID: WorkID
    public let localDurability: SyncV2LocalDurability
    public let remoteProgress: SyncV2RemoteProgress
    public let conflict: SyncV2ConflictProjection?
    public let lastTypedResult: SyncV2TypedResult

    public init(
        workID: WorkID,
        localDurability: SyncV2LocalDurability,
        remoteProgress: SyncV2RemoteProgress,
        conflict: SyncV2ConflictProjection? = nil,
        lastTypedResult: SyncV2TypedResult
    ) {
        self.workID = workID
        self.localDurability = localDurability
        self.remoteProgress = remoteProgress
        self.conflict = conflict
        self.lastTypedResult = lastTypedResult
    }

    public var japaneseLabel: String {
        remoteProgress.japaneseLabel
    }
}

public struct SafeAdoptionBoundary: Hashable, Sendable {
    public let workID: WorkID
    public let sessionToken: UUID
    public let expectedGeneration: Int64
    public let expectedSnapshotID: SnapshotID?
    public let imeActive: Bool
    public let hasUnsavedChanges: Bool
    public let hasPendingIntent: Bool
    public let documentGateProof: UUID

    public init(
        workID: WorkID,
        sessionToken: UUID,
        expectedGeneration: Int64,
        expectedSnapshotID: SnapshotID?,
        imeActive: Bool,
        hasUnsavedChanges: Bool,
        hasPendingIntent: Bool,
        documentGateProof: UUID
    ) {
        self.workID = workID
        self.sessionToken = sessionToken
        self.expectedGeneration = expectedGeneration
        self.expectedSnapshotID = expectedSnapshotID
        self.imeActive = imeActive
        self.hasUnsavedChanges = hasUnsavedChanges
        self.hasPendingIntent = hasPendingIntent
        self.documentGateProof = documentGateProof
    }
}

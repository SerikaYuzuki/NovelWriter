import Foundation
import NovelCore
import NovelSyncV2

public enum SyncV2ApplicationError: Error, Equatable, Sendable {
    case workNotFound
    case invalidRuntimeMode
    case previewReadOnly
    case staleConflictAction
    case safeBoundaryRejected
    case remoteOnlyInstallRejected
    case invalidHistoryCursor
}

public enum SyncV2Failure: Error, Equatable, Sendable {
    case offline
    case authenticationRequired
    case accountFenceChanged
    case quarantined(SyncV2QuarantineReason)
    case retryable(SyncV2RetryReason)
    case fatal(SyncV2FatalReason)
    case receiptMismatch
}

public enum SyncV2QuarantineReason: String, Equatable, Sendable {
    case differentAccount
    case changedFence
    case invalidRemoteData
    case unsafeLocalState
}

public enum SyncV2RetryReason: String, Equatable, Sendable {
    case serverUnavailable
    case rateLimited
    case lostResponse
    case uploadExpired
}

public enum SyncV2FatalReason: String, Equatable, Sendable {
    case unsupportedCommand
    case invalidLocalState
    case unexpected
}

public enum SyncV2CheckpointReason: String, Codable, Sendable {
    case autosave
    case explicit
    case navigation
    case close
    case restore
    case migration
    case conflictResolution
    case keepBoth
}

public struct SyncV2CheckpointCapture: Sendable {
    public let workID: WorkID
    public let document: NovelDocument
    public let documentCreatedAt: Date
    public let expectedGeneration: Int64
    public let reason: SyncV2CheckpointReason
    public let attachments: [SyncAttachment]

    public init(
        workID: WorkID,
        document: NovelDocument,
        documentCreatedAt: Date,
        expectedGeneration: Int64,
        reason: SyncV2CheckpointReason,
        attachments: [SyncAttachment] = []
    ) {
        self.workID = workID
        self.document = document
        self.documentCreatedAt = documentCreatedAt
        self.expectedGeneration = expectedGeneration
        self.reason = reason
        self.attachments = attachments
    }
}

public struct SyncV2LocalCheckpoint: Hashable, Sendable {
    public let snapshotID: SnapshotID
    public let generation: Int64
    public let intentID: UUID?
    public let noChanges: Bool

    public init(
        snapshotID: SnapshotID,
        generation: Int64,
        intentID: UUID?,
        noChanges: Bool
    ) {
        self.snapshotID = snapshotID
        self.generation = generation
        self.intentID = intentID
        self.noChanges = noChanges
    }
}

public struct SyncV2OpenedWork: Sendable {
    public let workID: WorkID
    public let document: NovelDocument?
    public let documentCreatedAt: Date
    public let attachments: [SyncAttachment]
    public let generation: Int64
    public let snapshotID: SnapshotID?

    public init(
        workID: WorkID,
        document: NovelDocument?,
        documentCreatedAt: Date,
        attachments: [SyncAttachment] = [],
        generation: Int64,
        snapshotID: SnapshotID?
    ) {
        self.workID = workID
        self.document = document
        self.documentCreatedAt = documentCreatedAt
        self.attachments = attachments
        self.generation = generation
        self.snapshotID = snapshotID
    }
}

public struct SyncV2RestoreRequest: Hashable, Sendable {
    public let workID: WorkID
    public let snapshotID: SnapshotID

    public init(workID: WorkID, snapshotID: SnapshotID) {
        self.workID = workID
        self.snapshotID = snapshotID
    }
}

public struct SyncV2Preparation: Hashable, Sendable {
    public let intentID: UUID?
    public let noChanges: Bool

    public init(intentID: UUID?, noChanges: Bool) {
        self.intentID = intentID
        self.noChanges = noChanges
    }
}

public struct SyncV2ExplicitAccountClone: Hashable, Sendable {
    public let sourceWorkID: WorkID
    public let newWorkID: WorkID
    public let newDocumentID: DocumentID
    public let intentID: UUID

    public init(sourceWorkID: WorkID, newWorkID: WorkID, newDocumentID: DocumentID, intentID: UUID) {
        self.sourceWorkID = sourceWorkID
        self.newWorkID = newWorkID
        self.newDocumentID = newDocumentID
        self.intentID = intentID
    }
}

public struct SyncV2PendingAdoption: Hashable, Sendable {
    public let workID: WorkID
    public let inboxID: UUID
    public let expectedLocalVersion: SyncV2LocalVersion
    public let conflictID: UUID
    public let conflictRevision: Int64

    public init(
        workID: WorkID,
        inboxID: UUID,
        expectedLocalVersion: SyncV2LocalVersion,
        conflictID: UUID,
        conflictRevision: Int64
    ) {
        self.workID = workID
        self.inboxID = inboxID
        self.expectedLocalVersion = expectedLocalVersion
        self.conflictID = conflictID
        self.conflictRevision = conflictRevision
    }
}

import Foundation
import NovelCore
import NovelSyncV2

public enum SyncV2StoreError: Error, Equatable, Sendable {
    case invalidRoot
    case databaseMissing
    case databaseAlreadyExists
    case sqlite(String)
    case schemaMismatch
    case workNotFound
    case generationMismatch
    case snapshotNotFound
    case invalidSnapshot
    case invalidCommand
    case commandAlreadySealed
    case invalidAcknowledgement
    case invalidRemoteHead
    case invalidLifecycle
    case accountMismatch
    case staleCAS
    case inboxNotFound
    case conflictNotFound
    case staleConflictAction
    case reservationNotFound
    case invalidHistoryCursor
    case invalidHistoryDate
}

public enum V2StoreOpenPolicy: Equatable, Sendable {
    case createNew
    case openExisting
}

public struct V2AccountBinding: Hashable, Sendable {
    public let accountID: String
    public let accountFence: String
    public let serverInstanceID: String
    public let protocolEpoch: Int64

    public init(
        accountID: String,
        accountFence: String,
        serverInstanceID: String,
        protocolEpoch: Int64 = 2
    ) {
        self.accountID = accountID
        self.accountFence = accountFence
        self.serverInstanceID = serverInstanceID
        self.protocolEpoch = protocolEpoch
    }
}

public enum V2LocalWorkScope: Hashable, Sendable {
    case unbound
    /// A parked work is local-only but remains distinguishable from a never-
    /// bound work. Parked checkpoints never create an actionable intent.
    case parked
    case bound(V2AccountBinding)
}

public enum V2SyncLane: String, Hashable, Sendable {
    case normal
    case keepBothReserved
}

public struct V2WorkSummary: Hashable, Sendable {
    public let workID: WorkID
    public let documentID: DocumentID
    public let localGeneration: Int64
    public let currentSnapshotID: SnapshotID?
    public let acknowledgedHeadGeneration: Int64?
    public let syncLane: V2SyncLane
}

public enum V2CheckpointReason: String, Codable, Sendable {
    case autosave
    case explicit
    case navigation
    case close
    case restore
    case migration
    case conflictResolution
    case keepBoth
}

extension V2CheckpointReason {
    var protectsOccurrence: Bool {
        switch self {
        case .explicit, .navigation, .close, .migration:
            true
        case .autosave, .restore, .conflictResolution, .keepBoth:
            false
        }
    }
}

public struct V2OpenResult: Sendable {
    public let summary: V2WorkSummary
    public let document: NovelDocument?
    public let documentCreatedAt: Date
    public let attachments: [SyncAttachment]
    /// Opaque `.novelpkg` remainder retained only in the local SQLite mirror.
    /// These resources never enter Snapshot manifests or remote commands.
    public let resources: [PortableResource]

    public init(
        summary: V2WorkSummary,
        document: NovelDocument?,
        documentCreatedAt: Date,
        attachments: [SyncAttachment] = [],
        resources: [PortableResource] = []
    ) {
        self.summary = summary
        self.document = document
        self.documentCreatedAt = documentCreatedAt
        self.attachments = attachments
        self.resources = resources
    }
}

public struct V2CheckpointRequest: Sendable {
    public let workID: WorkID
    public let document: NovelDocument
    public let documentCreatedAt: Date
    public let expectedGeneration: Int64
    public let reason: V2CheckpointReason
    public let attachments: [SyncAttachment]
    /// `nil` preserves an already-imported local resource mirror. An explicit
    /// empty array is the only value that requests a caller-owned clear.
    public let resources: [PortableResource]?

    public init(
        workID: WorkID,
        document: NovelDocument,
        documentCreatedAt: Date,
        expectedGeneration: Int64,
        reason: V2CheckpointReason = .autosave,
        attachments: [SyncAttachment] = [],
        resources: [PortableResource]? = nil
    ) {
        self.workID = workID
        self.document = document
        self.documentCreatedAt = documentCreatedAt
        self.expectedGeneration = expectedGeneration
        self.reason = reason
        self.attachments = attachments
        self.resources = resources
    }
}

public struct V2CheckpointResult: Sendable {
    public let snapshotID: SnapshotID
    public let generation: Int64
    public let intentID: UUID?
    public let noChanges: Bool
}

public struct V2PendingIntent: Hashable, Sendable {
    public let intentID: UUID
    public let workID: WorkID
    public let sourceSnapshotID: SnapshotID
    public let sourceGeneration: Int64
    public let kind: String
    public let status: String
}

/// Immutable bytes selected by the worker for one local intent.  The view is
/// account-scoped and intentionally contains no SQLite row handles; a caller
/// may retain it while doing network I/O and must still re-seal the command
/// through the store before sending.
public struct V2ImmutableTransferView: Sendable {
    public let workID: WorkID
    public let binding: V2AccountBinding
    public let summary: V2WorkSummary
    public let snapshot: EncodedSnapshot
    public let pendingIntent: V2PendingIntent
    public let expectedRemoteHead: V2RemoteHead?

    public init(
        workID: WorkID,
        binding: V2AccountBinding,
        summary: V2WorkSummary,
        snapshot: EncodedSnapshot,
        pendingIntent: V2PendingIntent,
        expectedRemoteHead: V2RemoteHead?
    ) {
        self.workID = workID
        self.binding = binding
        self.summary = summary
        self.snapshot = snapshot
        self.pendingIntent = pendingIntent
        self.expectedRemoteHead = expectedRemoteHead
    }
}

public struct V2PendingServerAdoption: Hashable, Sendable {
    public let workID: WorkID
    public let inboxID: UUID
    public let expectedCurrentSnapshotID: SnapshotID
    public let expectedLocalGeneration: Int64
    public let conflictID: UUID
    public let conflictRevision: Int64
}

public struct V2UploadTransferRecord: Hashable, Sendable {
    public let transferID: UUID
    public let commandID: UUID
    public let workID: WorkID
    public let objectID: ObjectID
    public let sourceSnapshotID: SnapshotID
    public let sourceGeneration: Int64
    public let uploadID: UUID
    public let capability: String
    public let exactBytes: Data
    public let bytesDigest: ObjectID
    public let acknowledgedOffset: Int
    public let expiresAt: Date
    public let lifecycle: String

    public init(
        transferID: UUID,
        commandID: UUID,
        workID: WorkID,
        objectID: ObjectID,
        sourceSnapshotID: SnapshotID,
        sourceGeneration: Int64,
        uploadID: UUID,
        capability: String,
        exactBytes: Data,
        bytesDigest: ObjectID,
        acknowledgedOffset: Int,
        expiresAt: Date,
        lifecycle: String
    ) {
        self.transferID = transferID
        self.commandID = commandID
        self.workID = workID
        self.objectID = objectID
        self.sourceSnapshotID = sourceSnapshotID
        self.sourceGeneration = sourceGeneration
        self.uploadID = uploadID
        self.capability = capability
        self.exactBytes = exactBytes
        self.bytesDigest = bytesDigest
        self.acknowledgedOffset = acknowledgedOffset
        self.expiresAt = expiresAt
        self.lifecycle = lifecycle
    }
}

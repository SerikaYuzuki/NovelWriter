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
}

public struct V2CheckpointRequest: Sendable {
    public let workID: WorkID
    public let document: NovelDocument
    public let documentCreatedAt: Date
    public let expectedGeneration: Int64
    public let reason: V2CheckpointReason
    public let attachments: [SyncAttachment]

    public init(
        workID: WorkID,
        document: NovelDocument,
        documentCreatedAt: Date,
        expectedGeneration: Int64,
        reason: V2CheckpointReason = .autosave,
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

    public init(transferID: UUID, commandID: UUID, workID: WorkID, objectID: ObjectID, sourceSnapshotID: SnapshotID, sourceGeneration: Int64, uploadID: UUID, capability: String, exactBytes: Data, bytesDigest: ObjectID, acknowledgedOffset: Int, expiresAt: Date, lifecycle: String) {
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

public struct V2HistoryOccurrence: Hashable, Sendable {
    public let occurrenceID: UUID
    public let snapshotID: SnapshotID
    public let reason: String
    public let pinned: Bool
    public let localGeneration: Int64
    public let createdAt: Date

    public init(
        occurrenceID: UUID,
        snapshotID: SnapshotID,
        reason: String,
        pinned: Bool,
        localGeneration: Int64,
        createdAt: Date
    ) {
        self.occurrenceID = occurrenceID
        self.snapshotID = snapshotID
        self.reason = reason
        self.pinned = pinned
        self.localGeneration = localGeneration
        self.createdAt = createdAt
    }
}

public struct V2HistoryPage: Hashable, Sendable {
    public let items: [V2HistoryOccurrence]
    public let nextCursor: String?

    public init(items: [V2HistoryOccurrence], nextCursor: String?) {
        self.items = items
        self.nextCursor = nextCursor
    }
}

public struct V2RemoteHead: Hashable, Sendable {
    public static let maximumGeneration: Int64 = 9_007_199_254_740_991

    public let snapshotID: SnapshotID
    public let generation: Int64

    public init(snapshotID: SnapshotID, generation: Int64) throws {
        guard generation > 0, generation <= Self.maximumGeneration else {
            throw SyncV2StoreError.invalidRemoteHead
        }
        self.snapshotID = snapshotID
        self.generation = generation
    }

    /// Conversion boundary for a head that already passed the application
    /// wire validator.
    public init(validatedSnapshotID snapshotID: SnapshotID, generation: Int64) {
        self.snapshotID = snapshotID
        self.generation = generation
    }
}

public struct V2RemoteSnapshotGraph: Sendable {
    public let inboxID: UUID
    public let workID: WorkID
    public let headSnapshotID: SnapshotID
    public let snapshots: [EncodedSnapshot]
    public let expectedCurrentSnapshotID: SnapshotID?
    public let expectedLocalGeneration: Int64
    public let expectedRemoteHead: V2RemoteHead?

    public init(
        inboxID: UUID = UUID(),
        workID: WorkID,
        headSnapshotID: SnapshotID,
        snapshots: [EncodedSnapshot],
        expectedCurrentSnapshotID: SnapshotID?,
        expectedLocalGeneration: Int64,
        expectedRemoteHead: V2RemoteHead? = nil
    ) {
        self.inboxID = inboxID
        self.workID = workID
        self.headSnapshotID = headSnapshotID
        self.snapshots = snapshots
        self.expectedCurrentSnapshotID = expectedCurrentSnapshotID
        self.expectedLocalGeneration = expectedLocalGeneration
        self.expectedRemoteHead = expectedRemoteHead
    }
}

public struct V2RemoteSnapshot: Sendable {
    public let inboxID: UUID
    public let workID: WorkID
    public let encoded: EncodedSnapshot
    public let expectedCurrentSnapshotID: SnapshotID?
    public let expectedLocalGeneration: Int64
    public let expectedRemoteHead: V2RemoteHead?

    public init(
        inboxID: UUID = UUID(),
        workID: WorkID,
        encoded: EncodedSnapshot,
        expectedCurrentSnapshotID: SnapshotID?,
        expectedLocalGeneration: Int64,
        expectedRemoteHead: V2RemoteHead? = nil
    ) {
        self.inboxID = inboxID
        self.workID = workID
        self.encoded = encoded
        self.expectedCurrentSnapshotID = expectedCurrentSnapshotID
        self.expectedLocalGeneration = expectedLocalGeneration
        self.expectedRemoteHead = expectedRemoteHead
    }

    var graph: V2RemoteSnapshotGraph {
        V2RemoteSnapshotGraph(
            inboxID: inboxID,
            workID: workID,
            headSnapshotID: encoded.snapshotId,
            snapshots: [encoded],
            expectedCurrentSnapshotID: expectedCurrentSnapshotID,
            expectedLocalGeneration: expectedLocalGeneration,
            expectedRemoteHead: expectedRemoteHead
        )
    }
}

public struct V2ConflictCandidate: Hashable, Sendable {
    public let conflictID: UUID
    public let revision: Int64
    public let workID: WorkID
    public let baseSnapshotID: SnapshotID?
    public let localSnapshotID: SnapshotID
    public let remoteSnapshotID: SnapshotID
    public let sourceGeneration: Int64
}

public struct V2ServerResolutionRequest: Hashable, Sendable {
    public let workID: WorkID
    public let conflictID: UUID
    public let revision: Int64
    public let sourceGeneration: Int64
    public let localSnapshotID: SnapshotID
    public let remoteSnapshotID: SnapshotID
    public let inboxID: UUID
    public let expectedRemoteHead: V2RemoteHead

    public init(
        workID: WorkID,
        conflictID: UUID,
        revision: Int64,
        sourceGeneration: Int64,
        localSnapshotID: SnapshotID,
        remoteSnapshotID: SnapshotID,
        inboxID: UUID,
        expectedRemoteHead: V2RemoteHead
    ) {
        self.workID = workID
        self.conflictID = conflictID
        self.revision = revision
        self.sourceGeneration = sourceGeneration
        self.localSnapshotID = localSnapshotID
        self.remoteSnapshotID = remoteSnapshotID
        self.inboxID = inboxID
        self.expectedRemoteHead = expectedRemoteHead
    }
}

public struct V2DeviceResolutionRequest: Sendable {
    public let workID: WorkID
    public let conflictID: UUID
    public let revision: Int64
    public let sourceGeneration: Int64
    public let localSnapshotID: SnapshotID
    public let remoteSnapshotID: SnapshotID
    public let inboxID: UUID
    public let remoteHead: V2RemoteHead

    public init(
        workID: WorkID,
        conflictID: UUID,
        revision: Int64,
        sourceGeneration: Int64,
        localSnapshotID: SnapshotID,
        remoteSnapshotID: SnapshotID,
        inboxID: UUID,
        remoteHead: V2RemoteHead
    ) {
        self.workID = workID
        self.conflictID = conflictID
        self.revision = revision
        self.sourceGeneration = sourceGeneration
        self.localSnapshotID = localSnapshotID
        self.remoteSnapshotID = remoteSnapshotID
        self.inboxID = inboxID
        self.remoteHead = remoteHead
    }
}

public struct V2KeepBothPreparationRequest: Sendable {
    public let workID: WorkID
    public let conflictID: UUID
    public let revision: Int64
    public let sourceGeneration: Int64
    public let localSnapshotID: SnapshotID
    public let remoteSnapshotID: SnapshotID
    public let newWorkID: WorkID
    public let newDocumentID: DocumentID

    public init(
        workID: WorkID,
        conflictID: UUID,
        revision: Int64,
        sourceGeneration: Int64,
        localSnapshotID: SnapshotID,
        remoteSnapshotID: SnapshotID,
        newWorkID: WorkID,
        newDocumentID: DocumentID
    ) {
        self.workID = workID
        self.conflictID = conflictID
        self.revision = revision
        self.sourceGeneration = sourceGeneration
        self.localSnapshotID = localSnapshotID
        self.remoteSnapshotID = remoteSnapshotID
        self.newWorkID = newWorkID
        self.newDocumentID = newDocumentID
    }
}

public struct V2KeepBothReservation: Hashable, Sendable {
    public let reservationID: UUID
    public let sourceWorkID: WorkID
    public let newWorkID: WorkID
    public let newDocumentID: DocumentID
    public let newRootSnapshotID: SnapshotID
    public let sourceGeneration: Int64
    public let expectedOriginalHead: V2RemoteHead
    public let state: String
}

public struct V2RestorePreparationRequest: Sendable {
    public let workID: WorkID
    public let selectedSnapshotID: SnapshotID
    public let expectedLocalGeneration: Int64

    public init(
        workID: WorkID,
        selectedSnapshotID: SnapshotID,
        expectedLocalGeneration: Int64
    ) {
        self.workID = workID
        self.selectedSnapshotID = selectedSnapshotID
        self.expectedLocalGeneration = expectedLocalGeneration
    }
}

public struct V2RestorePreparationResult: Sendable {
    public let restoreID: UUID?
    public let checkpoint: V2CheckpointResult
    public let expectedRemoteHead: V2RemoteHead?
}

public enum V2SealedCommandLifecycle: String, Hashable, Sendable {
    case sealed
    case sending
    case completed
    case quarantined
    case conflictPending
    case parked
}

public struct V2SealedCommandRecord: Hashable, Sendable {
    public let commandID: UUID
    public let workID: WorkID
    public let intentID: UUID?
    public let binding: V2AccountBinding
    public let commandKind: String
    public let canonicalRequest: Data
    public let requestDigest: ObjectID
    public let sourceSnapshotID: SnapshotID
    public let sourceGeneration: Int64
    public let lifecycle: V2SealedCommandLifecycle
}

public enum V2CommandTerminalResult: String, Hashable, Sendable {
    case applied
    case noChanges
    case conflictPending
    case parked
    case retryable
}

public struct V2ReadBackPredicates: Hashable, Sendable {
    public let accountMatched: Bool
    public let commandDigestMatched: Bool
    public let resourceMatched: Bool
    public let headMatched: Bool
    public let stateMatched: Bool

    public init(
        accountMatched: Bool,
        commandDigestMatched: Bool,
        resourceMatched: Bool,
        headMatched: Bool,
        stateMatched: Bool
    ) {
        self.accountMatched = accountMatched
        self.commandDigestMatched = commandDigestMatched
        self.resourceMatched = resourceMatched
        self.headMatched = headMatched
        self.stateMatched = stateMatched
    }

    public var allVerified: Bool {
        accountMatched && commandDigestMatched && resourceMatched &&
            headMatched && stateMatched
    }
}

public struct V2CommandAcknowledgement: Sendable {
    public let commandID: UUID
    public let canonicalReceiptEnvelope: Data

    public init(
        commandID: UUID,
        canonicalReceiptEnvelope: Data
    ) {
        self.commandID = commandID
        self.canonicalReceiptEnvelope = canonicalReceiptEnvelope
    }
}

public struct V2ReceiptReadback: Hashable, Sendable {
    public let commandID: UUID
    public let result: V2CommandTerminalResult
    public let responseStatus: Int
    public let canonicalResponse: Data
    public let predicates: V2ReadBackPredicates
    public let remoteHead: V2RemoteHead?
    public let cloneRemoteHead: V2RemoteHead?
}

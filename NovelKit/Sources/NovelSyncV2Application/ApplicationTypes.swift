import Foundation
import NovelCore
import NovelSyncV2

public enum SyncV2ApplicationError: Error, Equatable, Sendable {
    case workNotFound
    case invalidRuntimeMode
    case previewReadOnly
    case staleConflictAction
    case safeBoundaryRejected
    case missingReceipt
    case receiptMismatch
    case transport(String)
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
    public let encoded: EncodedSnapshot
    public let reason: SyncV2CheckpointReason

    public init(
        workID: WorkID,
        encoded: EncodedSnapshot,
        reason: SyncV2CheckpointReason
    ) {
        self.workID = workID
        self.encoded = encoded
        self.reason = reason
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
    public let generation: Int64
    public let snapshotID: SnapshotID?

    public init(
        workID: WorkID,
        document: NovelDocument?,
        generation: Int64,
        snapshotID: SnapshotID?
    ) {
        self.workID = workID
        self.document = document
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

public enum SyncV2ConflictChoice: String, Codable, Sendable {
    case useDevice
    case useServer
    case keepBoth
}

public struct SyncV2ConflictAction: Hashable, Sendable {
    public let workID: WorkID
    public let conflictID: UUID
    public let revision: Int64
    public let baseSnapshotID: SnapshotID?
    public let localSnapshotID: SnapshotID
    public let remoteSnapshotID: SnapshotID
    public let sourceGeneration: Int64
    public let choice: SyncV2ConflictChoice
    public let commandID: UUID?
    public let inboxID: UUID?

    public init(
        workID: WorkID,
        conflictID: UUID,
        revision: Int64,
        baseSnapshotID: SnapshotID?,
        localSnapshotID: SnapshotID,
        remoteSnapshotID: SnapshotID,
        sourceGeneration: Int64,
        choice: SyncV2ConflictChoice,
        commandID: UUID? = nil,
        inboxID: UUID? = nil
    ) {
        self.workID = workID
        self.conflictID = conflictID
        self.revision = revision
        self.baseSnapshotID = baseSnapshotID
        self.localSnapshotID = localSnapshotID
        self.remoteSnapshotID = remoteSnapshotID
        self.sourceGeneration = sourceGeneration
        self.choice = choice
        self.commandID = commandID
        self.inboxID = inboxID
    }
}

public struct SyncV2RemoteInbox: Sendable {
    public let inboxID: UUID
    public let workID: WorkID
    public let headSnapshotID: SnapshotID
    public let snapshots: [EncodedSnapshot]
    public let expectedCurrentSnapshotID: SnapshotID?
    public let expectedLocalGeneration: Int64
    public let expectedRemoteHead: SyncV2RemoteHead

    public init(
        inboxID: UUID,
        workID: WorkID,
        headSnapshotID: SnapshotID,
        snapshots: [EncodedSnapshot],
        expectedCurrentSnapshotID: SnapshotID?,
        expectedLocalGeneration: Int64,
        expectedRemoteHead: SyncV2RemoteHead
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

public struct SyncV2RemoteHead: Hashable, Sendable {
    public static let maximumGeneration: Int64 = 9_007_199_254_740_991
    public let snapshotID: SnapshotID
    public let generation: Int64

    public init(
        snapshotID: SnapshotID,
        generation: Int64
    ) throws {
        guard generation > 0, generation <= Self.maximumGeneration else {
            throw SyncV2ApplicationError.receiptMismatch
        }
        self.snapshotID = snapshotID
        self.generation = generation
    }
}

public struct SyncV2ReadBackPredicates: Hashable, Sendable {
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

public struct SyncV2ReceiptReadback: Hashable, Sendable {
    public let commandID: UUID
    public let requestDigest: ObjectID
    public let responseStatus: Int
    public let canonicalResponse: Data
    public let predicates: SyncV2ReadBackPredicates
    public let result: SyncV2RemoteResult
    public let verifiedInboxID: UUID?
    public let conflict: SyncV2ConflictProjection?
    public let remoteHead: SyncV2RemoteHead?
    public let cloneRemoteHead: SyncV2RemoteHead?

    public init(
        commandID: UUID,
        requestDigest: ObjectID,
        responseStatus: Int,
        canonicalResponse: Data,
        predicates: SyncV2ReadBackPredicates,
        result: SyncV2RemoteResult,
        verifiedInboxID: UUID? = nil,
        conflict: SyncV2ConflictProjection? = nil,
        remoteHead: SyncV2RemoteHead? = nil,
        cloneRemoteHead: SyncV2RemoteHead? = nil
    ) {
        self.commandID = commandID
        self.requestDigest = requestDigest
        self.responseStatus = responseStatus
        self.canonicalResponse = canonicalResponse
        self.predicates = predicates
        self.result = result
        self.verifiedInboxID = verifiedInboxID
        self.conflict = conflict
        self.remoteHead = remoteHead
        self.cloneRemoteHead = cloneRemoteHead
    }
}

public enum SyncV2RemoteResult: String, Codable, Sendable {
    case applied
    case noChanges
    case conflictPending
}

public struct SyncV2TransportRequest: Sendable {
    public let commandID: UUID
    public let canonicalBytes: Data
    public let requestDigest: ObjectID

    public init(commandID: UUID, canonicalBytes: Data, requestDigest: ObjectID) {
        self.commandID = commandID
        self.canonicalBytes = canonicalBytes
        self.requestDigest = requestDigest
    }
}

public struct SyncV2TransportResponse: Sendable {
    public let status: Int
    public let canonicalBytes: Data
    public let receipt: SyncV2ReceiptReadback?
    public let remoteInbox: SyncV2RemoteInbox?

    public init(
        status: Int,
        canonicalBytes: Data,
        receipt: SyncV2ReceiptReadback? = nil,
        remoteInbox: SyncV2RemoteInbox? = nil
    ) {
        self.status = status
        self.canonicalBytes = canonicalBytes
        self.receipt = receipt
        self.remoteInbox = remoteInbox
    }
}

public protocol SyncV2Transport: Sendable {
    func send(_ request: SyncV2TransportRequest) async throws -> SyncV2TransportResponse
}

public protocol SyncV2LocalKernel: Sendable {
    func checkpoint(_ capture: SyncV2CheckpointCapture) async throws -> SyncV2LocalCheckpoint
    func open(workID: WorkID) async throws -> SyncV2OpenedWork
    func pendingCommands(workID: WorkID) async throws -> [SealedCommand]
    func markSending(commandID: UUID, workID: WorkID) async throws -> SealedCommand
    func requeue(commandID: UUID, workID: WorkID) async throws
    func acknowledge(
        _ receipt: SyncV2ReceiptReadback,
        command: SealedCommand,
        verifiedInboxID: UUID?
    ) async throws
    func prepareConflict(_ action: SyncV2ConflictAction) async throws -> SealedCommand
    func prepareRestore(_ request: SyncV2RestoreRequest) async throws -> SealedCommand?
    func stageRemote(_ inbox: SyncV2RemoteInbox) async throws
    func verifyRemote(inboxID: UUID, workID: WorkID) async throws
    func applyStagedRemote(_ boundary: SafeAdoptionBoundary) async throws -> SyncV2OpenedWork
}

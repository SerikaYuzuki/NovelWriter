import Foundation
import NovelSyncV2

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

    public init(snapshotID: SnapshotID, generation: Int64) throws {
        guard generation > 0, generation <= Self.maximumGeneration else {
            throw SyncV2Failure.receiptMismatch
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

public enum SyncV2RemoteResult: String, Codable, Sendable {
    case applied
    case noChanges
    case conflictPending
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

public struct SyncV2RemoteCatalogEntry: Hashable, Sendable {
    public let workID: WorkID
    public let title: String
    public let head: SyncV2RemoteHead?

    public init(workID: WorkID, title: String, head: SyncV2RemoteHead?) {
        self.workID = workID
        self.title = title
        self.head = head
    }
}

public struct SyncV2RemoteCatalogPage: Hashable, Sendable {
    public let items: [SyncV2RemoteCatalogEntry]
    public let nextCursor: String?

    public init(items: [SyncV2RemoteCatalogEntry], nextCursor: String?) {
        self.items = items
        self.nextCursor = nextCursor
    }
}

public struct SyncV2RemoteHistoryEntry: Hashable, Sendable {
    public let occurrenceID: UUID
    public let snapshotID: SnapshotID
    public let reason: String
    public let pinned: Bool
    public let createdAt: Date

    public init(occurrenceID: UUID, snapshotID: SnapshotID, reason: String, pinned: Bool, createdAt: Date) {
        self.occurrenceID = occurrenceID
        self.snapshotID = snapshotID
        self.reason = reason
        self.pinned = pinned
        self.createdAt = createdAt
    }
}

public struct SyncV2RemoteHistoryPage: Hashable, Sendable {
    public let items: [SyncV2RemoteHistoryEntry]
    public let nextCursor: String?

    public init(items: [SyncV2RemoteHistoryEntry], nextCursor: String?) {
        self.items = items
        self.nextCursor = nextCursor
    }
}

public enum SyncV2RemoteOperationKind: String, CaseIterable, Equatable, Sendable {
    case createWork
    case prepareObject
    case finalizeObject
    case registerSnapshot
    case publish
    case resolveDevice
    case resolveServer
    case cloneWork
    case restore
}

public struct SyncV2SealedRemoteCommand: Sendable {
    public let kind: SyncV2RemoteOperationKind
    public let command: SealedCommand

    public init(command: SealedCommand) throws {
        guard let kind = SyncV2RemoteOperationKind(
            rawValue: command.commandKind
        ) else {
            throw SyncV2Failure.fatal(.unsupportedCommand)
        }
        self.kind = kind
        self.command = command
    }
}

public struct SyncV2UploadTransfer: Sendable {
    public let transferID: UUID
    public let workID: WorkID
    public let uploadID: UUID
    public let objectID: ObjectID
    public let exactBytes: Data
    public let acknowledgedOffset: Int
    public let expiresAt: Date
    public let capability: String

    public init(
        transferID: UUID,
        workID: WorkID,
        uploadID: UUID,
        objectID: ObjectID,
        exactBytes: Data,
        acknowledgedOffset: Int,
        expiresAt: Date,
        capability: String
    ) {
        self.transferID = transferID
        self.workID = workID
        self.uploadID = uploadID
        self.objectID = objectID
        self.exactBytes = exactBytes
        self.acknowledgedOffset = acknowledgedOffset
        self.expiresAt = expiresAt
        self.capability = capability
    }
}

public struct SyncV2UploadCompletion: Hashable, Sendable {
    public let transferID: UUID
    public let uploadID: UUID
    public let objectID: ObjectID
    public let acknowledgedByteCount: Int

    public init(
        transferID: UUID,
        uploadID: UUID,
        objectID: ObjectID,
        acknowledgedByteCount: Int
    ) {
        self.transferID = transferID
        self.uploadID = uploadID
        self.objectID = objectID
        self.acknowledgedByteCount = acknowledgedByteCount
    }
}

public enum SyncV2RemoteOperation: Sendable {
    case command(SyncV2SealedRemoteCommand)
    case upload(SyncV2UploadTransfer)
}

public enum SyncV2RemoteExecution: Sendable {
    case command(receipt: SyncV2ReceiptReadback, remoteInbox: SyncV2RemoteInbox?)
    case upload(SyncV2UploadCompletion)
}

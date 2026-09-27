import Foundation
import NovelCore
import NovelSyncV2

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

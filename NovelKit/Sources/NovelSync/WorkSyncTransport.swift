import Foundation

public struct WorkRemoteSnapshot: Hashable, Codable, Sendable {
    private enum CodingKeys: String, CodingKey {
        case protocolVersion
        case head
    }

    public let head: WorkRevision?

    public init(head: WorkRevision?) {
        self.head = head
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try requireCurrentWorkSyncWireVersion(forKey: .protocolVersion, in: container)
        head = try container.decodeIfPresent(WorkRevision.self, forKey: .head)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(WorkSyncWireProtocol.currentVersion, forKey: .protocolVersion)
        try container.encodeIfPresent(head, forKey: .head)
    }
}

public enum WorkSyncTransportError: Error, Equatable, Sendable {
    case unavailable
    case invalidPublishRequest
    case revisionCollision
    case mutationReuse
    case missingRevision
}

public struct WorkPublishRequest: Hashable, Codable, Sendable {
    private enum CodingKeys: String, CodingKey {
        case protocolVersion
        case mutationID
        case workID
        case revisions
        case candidateHeadRevisionID
        case expectedHeadRevisionID
        case expectedHeadSnapshotDigest
    }

    public static let maximumRevisionCount = 8

    public let mutationID: SyncMutationID
    public let workID: SyncWorkID
    public let revisions: [WorkRevision]
    public let candidateHeadRevisionID: SyncRevisionID
    public let expectedHeadRevisionID: SyncRevisionID?
    public let expectedHeadSnapshotDigest: SyncContentDigest?

    public init(
        mutationID: SyncMutationID = SyncMutationID(),
        workID: SyncWorkID,
        revisions: [WorkRevision],
        candidateHeadRevisionID: SyncRevisionID,
        expectedHeadRevisionID: SyncRevisionID?,
        expectedHeadSnapshotDigest: SyncContentDigest?
    ) throws {
        self.mutationID = mutationID
        self.workID = workID
        self.revisions = revisions
        self.candidateHeadRevisionID = candidateHeadRevisionID
        self.expectedHeadRevisionID = expectedHeadRevisionID
        self.expectedHeadSnapshotDigest = expectedHeadSnapshotDigest
        try validate()
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try requireCurrentWorkSyncWireVersion(forKey: .protocolVersion, in: container)
        mutationID = try container.decode(SyncMutationID.self, forKey: .mutationID)
        workID = try container.decode(SyncWorkID.self, forKey: .workID)
        revisions = try container.decode([WorkRevision].self, forKey: .revisions)
        candidateHeadRevisionID = try container.decode(SyncRevisionID.self, forKey: .candidateHeadRevisionID)
        expectedHeadRevisionID = try container.decodeIfPresent(SyncRevisionID.self, forKey: .expectedHeadRevisionID)
        expectedHeadSnapshotDigest = try container.decodeIfPresent(
            SyncContentDigest.self,
            forKey: .expectedHeadSnapshotDigest
        )
        try validate()
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(WorkSyncWireProtocol.currentVersion, forKey: .protocolVersion)
        try container.encode(mutationID, forKey: .mutationID)
        try container.encode(workID, forKey: .workID)
        try container.encode(revisions, forKey: .revisions)
        try container.encode(candidateHeadRevisionID, forKey: .candidateHeadRevisionID)
        try container.encodeIfPresent(expectedHeadRevisionID, forKey: .expectedHeadRevisionID)
        try container.encodeIfPresent(expectedHeadSnapshotDigest, forKey: .expectedHeadSnapshotDigest)
    }

    public func validate() throws {
        guard !revisions.isEmpty,
              revisions.count <= Self.maximumRevisionCount,
              revisions.allSatisfy({ $0.workID == workID }),
              Set(revisions.map(\.revisionID)).count == revisions.count,
              revisions.last?.revisionID == candidateHeadRevisionID,
              (expectedHeadRevisionID == nil) == (expectedHeadSnapshotDigest == nil) else {
            throw WorkSyncTransportError.invalidPublishRequest
        }
        guard Set(revisions.map(\.snapshot.documentID)).count == 1 else {
            throw WorkSyncTransportError.invalidPublishRequest
        }
        for revision in revisions {
            try revision.validate()
        }
        let batch = Dictionary(uniqueKeysWithValues: revisions.map { ($0.revisionID, $0) })
        var frontier = [candidateHeadRevisionID]
        var visited: Set<SyncRevisionID> = []
        var reachesExpected = false
        while let revisionID = frontier.popLast() {
            guard visited.insert(revisionID).inserted else { continue }
            if revisionID == expectedHeadRevisionID {
                reachesExpected = true
                continue
            }
            guard let revision = batch[revisionID] else { continue }
            if expectedHeadRevisionID == nil, revision.parentRevisionIDs.isEmpty {
                reachesExpected = true
            }
            frontier.append(contentsOf: revision.parentRevisionIDs)
        }
        guard reachesExpected, Set(batch.keys).isSubset(of: visited) else {
            throw WorkSyncTransportError.invalidPublishRequest
        }
    }
}

public enum WorkPublishResult: Hashable, Codable, Sendable {
    case acknowledged(committedHead: WorkRevision, current: WorkRemoteSnapshot)
    case diverged(WorkRemoteSnapshot)

    private enum CodingKeys: String, CodingKey {
        case protocolVersion
        case kind
        case committedHead
        case current
    }

    private enum Kind: String, Codable {
        case acknowledged
        case diverged
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try requireCurrentWorkSyncWireVersion(forKey: .protocolVersion, in: container)
        let current = try container.decode(WorkRemoteSnapshot.self, forKey: .current)
        switch try container.decode(Kind.self, forKey: .kind) {
        case .acknowledged:
            self = try .acknowledged(
                committedHead: container.decode(WorkRevision.self, forKey: .committedHead),
                current: current
            )
        case .diverged:
            self = .diverged(current)
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(WorkSyncWireProtocol.currentVersion, forKey: .protocolVersion)
        switch self {
        case let .acknowledged(committedHead, current):
            try container.encode(Kind.acknowledged, forKey: .kind)
            try container.encode(committedHead, forKey: .committedHead)
            try container.encode(current, forKey: .current)
        case let .diverged(current):
            try container.encode(Kind.diverged, forKey: .kind)
            try container.encode(current, forKey: .current)
        }
    }
}

public protocol WorkSyncTransport: Sendable {
    func fetchSnapshot(for workID: SyncWorkID) async throws -> WorkRemoteSnapshot
    func fetchRevision(_ id: SyncRevisionID, for workID: SyncWorkID) async throws -> WorkRevision
    func publish(_ request: WorkPublishRequest) async throws -> WorkPublishResult
}

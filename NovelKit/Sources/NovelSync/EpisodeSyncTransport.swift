import Foundation

public enum EpisodeLeaseClaimKind: String, Codable, Sendable {
    case acquireOrRenew
    case forceTakeover
}

public struct EpisodeLeaseClaimRequest: Hashable, Codable, Sendable {
    private enum CodingKeys: String, CodingKey {
        case protocolVersion
        case key
        case requesterReplicaID
        case requesterSessionID
        case expectedEpoch
        case expiresAt
        case kind
    }

    public let key: EpisodeSyncKey
    public let requesterReplicaID: SyncReplicaID
    public let requesterSessionID: SyncEditSessionID
    public let expectedEpoch: UInt64?
    public let expiresAt: Date
    public let kind: EpisodeLeaseClaimKind

    public init(
        key: EpisodeSyncKey,
        requesterReplicaID: SyncReplicaID,
        requesterSessionID: SyncEditSessionID,
        expectedEpoch: UInt64?,
        expiresAt: Date,
        kind: EpisodeLeaseClaimKind
    ) throws {
        guard expectedEpoch.map({ $0 <= EpisodeLeaseAuthority.maximumEpoch }) ?? true else {
            throw EpisodeSyncTransportError.leaseEpochOverflow
        }
        self.key = key
        self.requesterReplicaID = requesterReplicaID
        self.requesterSessionID = requesterSessionID
        self.expectedEpoch = expectedEpoch
        self.expiresAt = normalizedSyncTimestamp(expiresAt)
        self.kind = kind
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try requireCurrentSyncWireVersion(forKey: .protocolVersion, in: container)
        key = try container.decode(EpisodeSyncKey.self, forKey: .key)
        requesterReplicaID = try container.decode(SyncReplicaID.self, forKey: .requesterReplicaID)
        requesterSessionID = try container.decode(SyncEditSessionID.self, forKey: .requesterSessionID)
        expectedEpoch = try container.decodeIfPresent(UInt64.self, forKey: .expectedEpoch)
        expiresAt = try decodeCanonicalSyncTimestamp(forKey: .expiresAt, in: container)
        kind = try container.decode(EpisodeLeaseClaimKind.self, forKey: .kind)
        guard expectedEpoch.map({ $0 <= EpisodeLeaseAuthority.maximumEpoch }) ?? true else {
            throw DecodingError.dataCorruptedError(
                forKey: .expectedEpoch,
                in: container,
                debugDescription: "expected lease epoch must fit signed 64-bit wire storage"
            )
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(SyncWireProtocol.currentVersion, forKey: .protocolVersion)
        try container.encode(key, forKey: .key)
        try container.encode(requesterReplicaID, forKey: .requesterReplicaID)
        try container.encode(requesterSessionID, forKey: .requesterSessionID)
        try container.encodeIfPresent(expectedEpoch, forKey: .expectedEpoch)
        try encodeCanonicalSyncTimestamp(expiresAt, forKey: .expiresAt, in: &container)
        try container.encode(kind, forKey: .kind)
    }
}

public enum EpisodeLeaseClaimResult: Hashable, Codable, Sendable {
    /// claim CAS後のexact head + lease snapshot。
    case granted(EpisodeRemoteSnapshot)
    case denied(EpisodeRemoteSnapshot)
    case changed(EpisodeRemoteSnapshot)

    private enum CodingKeys: String, CodingKey {
        case protocolVersion
        case kind
        case snapshot
    }

    private enum Kind: String, Codable {
        case granted
        case denied
        case changed
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try requireCurrentSyncWireVersion(forKey: .protocolVersion, in: container)
        let snapshot = try container.decode(EpisodeRemoteSnapshot.self, forKey: .snapshot)
        switch try container.decode(Kind.self, forKey: .kind) {
        case .granted:
            self = .granted(snapshot)
        case .denied:
            self = .denied(snapshot)
        case .changed:
            self = .changed(snapshot)
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(SyncWireProtocol.currentVersion, forKey: .protocolVersion)
        switch self {
        case let .granted(snapshot):
            try container.encode(Kind.granted, forKey: .kind)
            try container.encode(snapshot, forKey: .snapshot)
        case let .denied(snapshot):
            try container.encode(Kind.denied, forKey: .kind)
            try container.encode(snapshot, forKey: .snapshot)
        case let .changed(snapshot):
            try container.encode(Kind.changed, forKey: .kind)
            try container.encode(snapshot, forKey: .snapshot)
        }
    }
}

/// pending revision列とremote head更新を一つの冪等mutationとして要求する。
/// `revisions`は親から子の順、`candidateHeadRevisionID`はその列の最終headである。
public struct EpisodePublishRequest: Hashable, Codable, Sendable {
    private enum CodingKeys: String, CodingKey {
        case protocolVersion
        case mutationID
        case key
        case revisions
        case candidateHeadRevisionID
        case expectedHeadRevisionID
        case expectedLeaseAuthority
    }

    public static let maximumRevisionCount = 64

    public let mutationID: SyncMutationID
    public let key: EpisodeSyncKey
    public let revisions: [EpisodeRevision]
    public let candidateHeadRevisionID: SyncRevisionID
    public let expectedHeadRevisionID: SyncRevisionID?
    public let expectedLeaseAuthority: EpisodeLeaseAuthority

    public init(
        mutationID: SyncMutationID = SyncMutationID(),
        key: EpisodeSyncKey,
        revisions: [EpisodeRevision],
        candidateHeadRevisionID: SyncRevisionID,
        expectedHeadRevisionID: SyncRevisionID?,
        expectedLeaseAuthority: EpisodeLeaseAuthority
    ) throws {
        guard !revisions.isEmpty, revisions.count <= Self.maximumRevisionCount else {
            throw EpisodeSyncTransportError.invalidPublishRequest
        }
        self.mutationID = mutationID
        self.key = key
        self.revisions = revisions
        self.candidateHeadRevisionID = candidateHeadRevisionID
        self.expectedHeadRevisionID = expectedHeadRevisionID
        self.expectedLeaseAuthority = expectedLeaseAuthority
        try validate()
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try requireCurrentSyncWireVersion(forKey: .protocolVersion, in: container)
        mutationID = try container.decode(SyncMutationID.self, forKey: .mutationID)
        key = try container.decode(EpisodeSyncKey.self, forKey: .key)
        revisions = try container.decode([EpisodeRevision].self, forKey: .revisions)
        candidateHeadRevisionID = try container.decode(SyncRevisionID.self, forKey: .candidateHeadRevisionID)
        expectedHeadRevisionID = try container.decodeIfPresent(SyncRevisionID.self, forKey: .expectedHeadRevisionID)
        expectedLeaseAuthority = try container.decode(
            EpisodeLeaseAuthority.self,
            forKey: .expectedLeaseAuthority
        )
        do {
            try validate()
        } catch {
            throw DecodingError.dataCorruptedError(
                forKey: .revisions,
                in: container,
                debugDescription: "publish batch is malformed or exceeds its resource cap"
            )
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(SyncWireProtocol.currentVersion, forKey: .protocolVersion)
        try container.encode(mutationID, forKey: .mutationID)
        try container.encode(key, forKey: .key)
        try container.encode(revisions, forKey: .revisions)
        try container.encode(candidateHeadRevisionID, forKey: .candidateHeadRevisionID)
        try container.encodeIfPresent(expectedHeadRevisionID, forKey: .expectedHeadRevisionID)
        try container.encode(expectedLeaseAuthority, forKey: .expectedLeaseAuthority)
    }

    public func validate() throws {
        guard !revisions.isEmpty,
              revisions.count <= Self.maximumRevisionCount,
              revisions.allSatisfy({ $0.key == key }),
              Set(revisions.map(\.revisionID)).count == revisions.count,
              revisions.last?.revisionID == candidateHeadRevisionID,
              revisions.last?.authorReplicaID == expectedLeaseAuthority.holderReplicaID,
              revisions.last?.authorSessionID == expectedLeaseAuthority.holderSessionID else {
            throw EpisodeSyncTransportError.invalidPublishRequest
        }
        for revision in revisions {
            try revision.validate()
        }

        let batch = Dictionary(uniqueKeysWithValues: revisions.map { ($0.revisionID, $0) })
        var pending = [candidateHeadRevisionID]
        var visited: Set<SyncRevisionID> = []
        var reachesExpectedHead = false
        while let revisionID = pending.popLast() {
            guard visited.insert(revisionID).inserted else { continue }
            if revisionID == expectedHeadRevisionID {
                reachesExpectedHead = true
                continue
            }
            guard let revision = batch[revisionID] else { continue }
            if expectedHeadRevisionID == nil, revision.parentRevisionIDs.isEmpty {
                reachesExpectedHead = true
            }
            pending.append(contentsOf: revision.parentRevisionIDs)
        }
        let batchIDs = Set(batch.keys)
        guard reachesExpectedHead,
              batchIDs.isSubset(of: visited) else {
            throw EpisodeSyncTransportError.invalidPublishRequest
        }
    }
}

public enum EpisodePublishResult: Hashable, Codable, Sendable {
    /// mutationはcommit済み。`current`はreceipt読出し時点の最新control/headであり、
    /// response loss後に別writerが進めた状態を古いsnapshotで巻き戻さない。
    case acknowledged(committedHead: EpisodeRevision, current: EpisodeRemoteSnapshot)
    /// headは別revisionへ進んでいた。remoteは変更せず、revisionsはlocal journalが保持する。
    case diverged(EpisodeRemoteSnapshot)
    /// holderまたはepochが古い。revisionsもheadも変更していない。
    case staleLease(EpisodeRemoteSnapshot)

    private enum CodingKeys: String, CodingKey {
        case protocolVersion
        case kind
        case committedHead
        case current
    }

    private enum Kind: String, Codable {
        case acknowledged
        case diverged
        case staleLease
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try requireCurrentSyncWireVersion(forKey: .protocolVersion, in: container)
        let current = try container.decode(EpisodeRemoteSnapshot.self, forKey: .current)
        switch try container.decode(Kind.self, forKey: .kind) {
        case .acknowledged:
            let committedHead = try container.decode(EpisodeRevision.self, forKey: .committedHead)
            self = .acknowledged(committedHead: committedHead, current: current)
        case .diverged:
            self = .diverged(current)
        case .staleLease:
            self = .staleLease(current)
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(SyncWireProtocol.currentVersion, forKey: .protocolVersion)
        switch self {
        case let .acknowledged(committedHead, current):
            try container.encode(Kind.acknowledged, forKey: .kind)
            try container.encode(committedHead, forKey: .committedHead)
            try container.encode(current, forKey: .current)
        case let .diverged(current):
            try container.encode(Kind.diverged, forKey: .kind)
            try container.encode(current, forKey: .current)
        case let .staleLease(current):
            try container.encode(Kind.staleLease, forKey: .kind)
            try container.encode(current, forKey: .current)
        }
    }
}

public enum EpisodeSyncTransportError: Error, Equatable, Sendable {
    case unavailable
    case invalidPublishRequest
    case revisionCollision
    case mutationReuse
    case missingRevision
    case leaseEpochOverflow
}

public protocol EpisodeSyncTransport: Sendable {
    func fetchSnapshot(for key: EpisodeSyncKey) async throws -> EpisodeRemoteSnapshot
    func fetchRevision(_ id: SyncRevisionID, for key: EpisodeSyncKey) async throws -> EpisodeRevision
    func claimLease(_ request: EpisodeLeaseClaimRequest) async throws -> EpisodeLeaseClaimResult
    /// 現holderだけがreleaseできる。epochは削除・巻き戻しせず、holder不在の同epochを保持する。
    func releaseLease(
        key: EpisodeSyncKey,
        expectedAuthority: EpisodeLeaseAuthority
    ) async throws -> EpisodeRemoteSnapshot
    func publish(_ request: EpisodePublishRequest) async throws -> EpisodePublishResult
}

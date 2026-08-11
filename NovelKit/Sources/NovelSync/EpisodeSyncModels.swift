import Foundation

public enum EpisodeRevisionError: Error, Equatable, Sendable {
    case contentTooLarge(actualBytes: Int, maximumBytes: Int)
    case tooManyParents
    case duplicateParent
    case selfParent
    case digestMismatch
}

/// 話本文のimmutable full-snapshot revision。
public struct EpisodeRevision: Hashable, Codable, Sendable, Identifiable {
    private enum CodingKeys: String, CodingKey {
        case protocolVersion
        case key
        case revisionID
        case parentRevisionIDs
        case branchID
        case authorReplicaID
        case authorSessionID
        case content
        case contentDigest
        case clientCreatedAt
    }

    /// app-private journalの64 MiB cap内でbase/local/remote/mergeを保全できる上限。
    public static let maximumContentUTF8Bytes = 1 * 1024 * 1024

    public var id: SyncRevisionID {
        revisionID
    }

    public let key: EpisodeSyncKey
    public let revisionID: SyncRevisionID
    public let parentRevisionIDs: [SyncRevisionID]
    public let branchID: SyncBranchID
    public let authorReplicaID: SyncReplicaID
    public let authorSessionID: SyncEditSessionID
    public let content: String
    public let contentDigest: SyncContentDigest
    /// 表示・監査用。headの勝者やrevision順序の判定には使わない。
    public let clientCreatedAt: Date

    public init(
        key: EpisodeSyncKey,
        revisionID: SyncRevisionID = SyncRevisionID(),
        parentRevisionIDs: [SyncRevisionID],
        branchID: SyncBranchID,
        authorReplicaID: SyncReplicaID,
        authorSessionID: SyncEditSessionID,
        content: String,
        clientCreatedAt: Date
    ) throws {
        let contentBytes = content.utf8.count
        guard contentBytes <= Self.maximumContentUTF8Bytes else {
            throw EpisodeRevisionError.contentTooLarge(
                actualBytes: contentBytes,
                maximumBytes: Self.maximumContentUTF8Bytes
            )
        }
        guard parentRevisionIDs.count <= 2 else { throw EpisodeRevisionError.tooManyParents }
        guard Set(parentRevisionIDs).count == parentRevisionIDs.count else {
            throw EpisodeRevisionError.duplicateParent
        }
        guard !parentRevisionIDs.contains(revisionID) else { throw EpisodeRevisionError.selfParent }

        self.key = key
        self.revisionID = revisionID
        self.parentRevisionIDs = parentRevisionIDs
        self.branchID = branchID
        self.authorReplicaID = authorReplicaID
        self.authorSessionID = authorSessionID
        self.content = content
        contentDigest = SyncContentDigest(content: content)
        self.clientCreatedAt = normalizedSyncTimestamp(clientCreatedAt)
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try requireCurrentSyncWireVersion(forKey: .protocolVersion, in: container)
        key = try container.decode(EpisodeSyncKey.self, forKey: .key)
        revisionID = try container.decode(SyncRevisionID.self, forKey: .revisionID)
        parentRevisionIDs = try container.decode([SyncRevisionID].self, forKey: .parentRevisionIDs)
        branchID = try container.decode(SyncBranchID.self, forKey: .branchID)
        authorReplicaID = try container.decode(SyncReplicaID.self, forKey: .authorReplicaID)
        authorSessionID = try container.decode(SyncEditSessionID.self, forKey: .authorSessionID)
        content = try container.decode(String.self, forKey: .content)
        contentDigest = try container.decode(SyncContentDigest.self, forKey: .contentDigest)
        clientCreatedAt = try decodeCanonicalSyncTimestamp(
            forKey: .clientCreatedAt,
            in: container
        )
        try validate()
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(SyncWireProtocol.currentVersion, forKey: .protocolVersion)
        try container.encode(key, forKey: .key)
        try container.encode(revisionID, forKey: .revisionID)
        try container.encode(parentRevisionIDs, forKey: .parentRevisionIDs)
        try container.encode(branchID, forKey: .branchID)
        try container.encode(authorReplicaID, forKey: .authorReplicaID)
        try container.encode(authorSessionID, forKey: .authorSessionID)
        try container.encode(content, forKey: .content)
        try container.encode(contentDigest, forKey: .contentDigest)
        try encodeCanonicalSyncTimestamp(clientCreatedAt, forKey: .clientCreatedAt, in: &container)
    }

    public func validate() throws {
        let contentBytes = content.utf8.count
        guard contentBytes <= Self.maximumContentUTF8Bytes else {
            throw EpisodeRevisionError.contentTooLarge(
                actualBytes: contentBytes,
                maximumBytes: Self.maximumContentUTF8Bytes
            )
        }
        guard parentRevisionIDs.count <= 2 else { throw EpisodeRevisionError.tooManyParents }
        guard Set(parentRevisionIDs).count == parentRevisionIDs.count else {
            throw EpisodeRevisionError.duplicateParent
        }
        guard !parentRevisionIDs.contains(revisionID) else { throw EpisodeRevisionError.selfParent }
        guard contentDigest == SyncContentDigest(content: content) else {
            throw EpisodeRevisionError.digestMismatch
        }
    }
}

public struct EpisodeLeaseAuthority: Hashable, Codable, Sendable {
    public static let maximumEpoch = UInt64(Int64.max)

    public let holderReplicaID: SyncReplicaID
    public let holderSessionID: SyncEditSessionID
    public let epoch: UInt64

    public init(
        holderReplicaID: SyncReplicaID,
        holderSessionID: SyncEditSessionID,
        epoch: UInt64
    ) throws {
        guard epoch <= Self.maximumEpoch else { throw EpisodeSyncTransportError.leaseEpochOverflow }
        self.holderReplicaID = holderReplicaID
        self.holderSessionID = holderSessionID
        self.epoch = epoch
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        holderReplicaID = try container.decode(SyncReplicaID.self, forKey: .holderReplicaID)
        holderSessionID = try container.decode(SyncEditSessionID.self, forKey: .holderSessionID)
        epoch = try container.decode(UInt64.self, forKey: .epoch)
        guard epoch <= Self.maximumEpoch else {
            throw DecodingError.dataCorruptedError(
                forKey: .epoch,
                in: container,
                debugDescription: "lease epoch must fit signed 64-bit wire storage"
            )
        }
    }
}

/// 話単位のsoft lease。holder/epochはpublish authority、`expiresAt`はUX表示専用。
/// expiryだけで旧writerへ書込み権を戻さず、移譲は必ずserverのepoch更新を通す。
public struct EpisodeLease: Hashable, Codable, Sendable {
    private enum CodingKeys: String, CodingKey {
        case authority
        case expiresAt
    }

    public let authority: EpisodeLeaseAuthority
    public let expiresAt: Date

    public init(authority: EpisodeLeaseAuthority, expiresAt: Date) {
        self.authority = authority
        self.expiresAt = normalizedSyncTimestamp(expiresAt)
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        authority = try container.decode(EpisodeLeaseAuthority.self, forKey: .authority)
        expiresAt = try decodeCanonicalSyncTimestamp(forKey: .expiresAt, in: container)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(authority, forKey: .authority)
        try encodeCanonicalSyncTimestamp(expiresAt, forKey: .expiresAt, in: &container)
    }

    public func appearsExpired(at date: Date) -> Bool {
        expiresAt <= date
    }
}

func normalizedSyncTimestamp(_ date: Date) -> Date {
    // JSON/CloudKit間のidempotent retryでfractional precision差を生まない。
    Date(timeIntervalSince1970: floor(date.timeIntervalSince1970))
}

public struct EpisodeRemoteSnapshot: Hashable, Codable, Sendable {
    private enum CodingKeys: String, CodingKey {
        case protocolVersion
        case head
        case leaseEpoch
        case lease
    }

    public let head: EpisodeRevision?
    /// active holderがreleaseされた後も巻き戻さないserver-side monotonic epoch。
    public let leaseEpoch: UInt64
    public let lease: EpisodeLease?

    public init(head: EpisodeRevision?, leaseEpoch: UInt64, lease: EpisodeLease?) throws {
        guard leaseEpoch <= EpisodeLeaseAuthority.maximumEpoch,
              lease?.authority.epoch == leaseEpoch || lease == nil else {
            throw EpisodeSyncTransportError.leaseEpochOverflow
        }
        self.head = head
        self.leaseEpoch = leaseEpoch
        self.lease = lease
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try requireCurrentSyncWireVersion(forKey: .protocolVersion, in: container)
        head = try container.decodeIfPresent(EpisodeRevision.self, forKey: .head)
        leaseEpoch = try container.decode(UInt64.self, forKey: .leaseEpoch)
        lease = try container.decodeIfPresent(EpisodeLease.self, forKey: .lease)
        guard leaseEpoch <= EpisodeLeaseAuthority.maximumEpoch,
              lease?.authority.epoch == leaseEpoch || lease == nil else {
            throw DecodingError.dataCorruptedError(
                forKey: .leaseEpoch,
                in: container,
                debugDescription: "lease epoch is out of range or inconsistent"
            )
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(SyncWireProtocol.currentVersion, forKey: .protocolVersion)
        try container.encodeIfPresent(head, forKey: .head)
        try container.encode(leaseEpoch, forKey: .leaseEpoch)
        try container.encodeIfPresent(lease, forKey: .lease)
    }
}

/// remote lease CAS成功時のexact observation。Appがこのheadをpackage/native editorへ
/// installし、digestをackするまではcoordinatorのpublish authorityにならない。
public struct EpisodeAuthorityGrant: Hashable, Sendable {
    public let snapshot: EpisodeRemoteSnapshot
    public let lease: EpisodeLease

    public init(snapshot: EpisodeRemoteSnapshot, lease: EpisodeLease) throws {
        guard snapshot.lease == lease,
              snapshot.leaseEpoch == lease.authority.epoch else {
            throw EpisodeSyncCoordinatorError.malformedRemoteSnapshot
        }
        self.snapshot = snapshot
        self.lease = lease
    }
}

public struct EpisodeConflict: Hashable, Codable, Sendable {
    public let base: EpisodeRevision?
    public let local: EpisodeRevision
    public let remote: EpisodeRevision

    public init(base: EpisodeRevision?, local: EpisodeRevision, remote: EpisodeRevision) {
        self.base = base
        self.local = local
        self.remote = remote
    }
}

/// 自動統合できなかった時にも、両本文を保持したまま提示できる確認用下書き。
public struct EpisodeIntegrationReviewDraft: Hashable, Codable, Sendable {
    public enum Reason: String, Codable, Sendable {
        case commonAncestorUnknown
        case inputLimitExceeded
        case sameInsertionPoint
        case overlappingChanges
        case ambiguousChanges
    }

    public let baseRevisionID: SyncRevisionID?
    public let localRevisionID: SyncRevisionID
    public let remoteRevisionID: SyncRevisionID
    public let proposedContent: String
    public let reason: Reason

    public init(
        baseRevisionID: SyncRevisionID?,
        localRevisionID: SyncRevisionID,
        remoteRevisionID: SyncRevisionID,
        proposedContent: String,
        reason: Reason
    ) {
        self.baseRevisionID = baseRevisionID
        self.localRevisionID = localRevisionID
        self.remoteRevisionID = remoteRevisionID
        self.proposedContent = proposedContent
        self.reason = reason
    }
}

/// native editorの本文と、自動統合後のgraph headが一時的に異なることをdurableに示す。
/// Appが安全な世代・IME境界で`integratedRevision`をmaterializeするまで削除しない。
public struct EpisodePendingMaterialization: Hashable, Codable, Sendable {
    public let workingRevisionID: SyncRevisionID
    public let integratedRevision: EpisodeRevision

    public init(workingRevisionID: SyncRevisionID, integratedRevision: EpisodeRevision) {
        self.workingRevisionID = workingRevisionID
        self.integratedRevision = integratedRevision
    }
}

public enum EpisodeIntegrationChoice: Hashable, Sendable {
    case keepLocal
    case keepRemote
    case manual(content: String)

    public func resolvedContent(for conflict: EpisodeConflict) -> String {
        switch self {
        case .keepLocal:
            conflict.local.content
        case .keepRemote:
            conflict.remote.content
        case let .manual(content):
            content
        }
    }
}

public struct EpisodeConflictResolutionMaterialization: Hashable, Sendable {
    public let localWorkingCopyID: LocalWorkingCopyID
    public let sourceConflict: EpisodeConflict
    public let chosenRevision: EpisodeRevision

    public init(
        localWorkingCopyID: LocalWorkingCopyID,
        sourceConflict: EpisodeConflict,
        chosenRevision: EpisodeRevision
    ) {
        self.localWorkingCopyID = localWorkingCopyID
        self.sourceConflict = sourceConflict
        self.chosenRevision = chosenRevision
    }
}

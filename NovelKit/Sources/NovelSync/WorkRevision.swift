// Digest input is the already-validated canonical UTF-8 byte sequence.
// swiftlint:disable:next blanket_disable_command
// swiftlint:disable optional_data_string_conversion
import Foundation

public enum WorkRevisionError: Error, Equatable, Sendable {
    case tooManyParents
    case duplicateParent
    case selfParent
    case digestMismatch
    case byteCountMismatch
    case revisionTooLarge(actualBytes: Int, maximumBytes: Int)
}

/// 作品全体を表すimmutable revision。親は通常1件、統合時だけ2件とする。
public struct WorkRevision: Hashable, Codable, Sendable, Identifiable {
    private enum CodingKeys: String, CodingKey {
        case protocolVersion
        case workID
        case revisionID
        case parentRevisionIDs
        case branchID
        case authorReplicaID
        case authorSessionID
        case snapshot
        case snapshotDigest
        case snapshotByteCount
        case clientCreatedAt
    }

    public static let maximumCanonicalByteCount = 50 * 1024 * 1024

    public var id: SyncRevisionID {
        revisionID
    }

    public let workID: SyncWorkID
    public let revisionID: SyncRevisionID
    public let parentRevisionIDs: [SyncRevisionID]
    public let branchID: SyncBranchID
    public let authorReplicaID: SyncReplicaID
    public let authorSessionID: SyncEditSessionID
    public let snapshot: WorkSnapshot
    public let snapshotDigest: SyncContentDigest
    public let snapshotByteCount: Int
    public let clientCreatedAt: Date

    public init(
        workID: SyncWorkID,
        revisionID: SyncRevisionID = SyncRevisionID(),
        parentRevisionIDs: [SyncRevisionID],
        branchID: SyncBranchID,
        authorReplicaID: SyncReplicaID,
        authorSessionID: SyncEditSessionID,
        snapshot: WorkSnapshot,
        clientCreatedAt: Date
    ) throws {
        let canonical = try WorkCanonicalJSON.encodeSnapshot(snapshot)
        self.workID = workID
        self.revisionID = revisionID
        self.parentRevisionIDs = parentRevisionIDs
        self.branchID = branchID
        self.authorReplicaID = authorReplicaID
        self.authorSessionID = authorSessionID
        self.snapshot = snapshot
        snapshotDigest = SyncContentDigest(content: String(decoding: canonical, as: UTF8.self))
        snapshotByteCount = canonical.count
        self.clientCreatedAt = normalizedSyncTimestamp(clientCreatedAt)
        try validateParentMetadata()
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try requireCurrentWorkSyncWireVersion(forKey: .protocolVersion, in: container)
        workID = try container.decode(SyncWorkID.self, forKey: .workID)
        revisionID = try container.decode(SyncRevisionID.self, forKey: .revisionID)
        parentRevisionIDs = try container.decode([SyncRevisionID].self, forKey: .parentRevisionIDs)
        branchID = try container.decode(SyncBranchID.self, forKey: .branchID)
        authorReplicaID = try container.decode(SyncReplicaID.self, forKey: .authorReplicaID)
        authorSessionID = try container.decode(SyncEditSessionID.self, forKey: .authorSessionID)
        snapshot = try container.decode(WorkSnapshot.self, forKey: .snapshot)
        snapshotDigest = try container.decode(SyncContentDigest.self, forKey: .snapshotDigest)
        snapshotByteCount = try container.decode(Int.self, forKey: .snapshotByteCount)
        clientCreatedAt = try decodeCanonicalSyncTimestamp(forKey: .clientCreatedAt, in: container)
        try validate()
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(WorkSyncWireProtocol.currentVersion, forKey: .protocolVersion)
        try container.encode(workID, forKey: .workID)
        try container.encode(revisionID, forKey: .revisionID)
        try container.encode(parentRevisionIDs, forKey: .parentRevisionIDs)
        try container.encode(branchID, forKey: .branchID)
        try container.encode(authorReplicaID, forKey: .authorReplicaID)
        try container.encode(authorSessionID, forKey: .authorSessionID)
        try container.encode(snapshot, forKey: .snapshot)
        try container.encode(snapshotDigest, forKey: .snapshotDigest)
        try container.encode(snapshotByteCount, forKey: .snapshotByteCount)
        try encodeCanonicalSyncTimestamp(clientCreatedAt, forKey: .clientCreatedAt, in: &container)
    }

    public func validate() throws {
        try validateParentMetadata()
        try snapshot.validate()
        let canonical = try WorkCanonicalJSON.encodeSnapshot(snapshot)
        guard canonical.count == snapshotByteCount else { throw WorkRevisionError.byteCountMismatch }
        let digest = SyncContentDigest(content: String(decoding: canonical, as: UTF8.self))
        guard digest == snapshotDigest else { throw WorkRevisionError.digestMismatch }
    }

    private func validateParentMetadata() throws {
        guard parentRevisionIDs.count <= 2 else { throw WorkRevisionError.tooManyParents }
        guard Set(parentRevisionIDs).count == parentRevisionIDs.count else {
            throw WorkRevisionError.duplicateParent
        }
        guard !parentRevisionIDs.contains(revisionID) else { throw WorkRevisionError.selfParent }
    }
}

public extension WorkCanonicalJSON {
    static func encodeRevision(_ revision: WorkRevision) throws -> Data {
        try revision.validate()
        let data = try uncheckedEncoder().encode(revision)
        guard data.count <= WorkRevision.maximumCanonicalByteCount else {
            throw WorkRevisionError.revisionTooLarge(
                actualBytes: data.count,
                maximumBytes: WorkRevision.maximumCanonicalByteCount
            )
        }
        return data
    }

    static func decodeRevision(_ data: Data) throws -> WorkRevision {
        guard data.count <= WorkRevision.maximumCanonicalByteCount else {
            throw WorkRevisionError.revisionTooLarge(
                actualBytes: data.count,
                maximumBytes: WorkRevision.maximumCanonicalByteCount
            )
        }
        let revision = try JSONDecoder().decode(WorkRevision.self, from: data)
        guard try uncheckedEncoder().encode(revision) == data else {
            throw WorkSnapshotError.nonCanonicalJSON
        }
        return revision
    }
}

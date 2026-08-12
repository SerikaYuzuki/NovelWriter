import Foundation
import NovelCore

public struct SyncWorkID: Hashable, Codable, Sendable, CustomStringConvertible {
    public let rawValue: UUID

    public init(rawValue: UUID) {
        self.rawValue = rawValue
    }

    public init() {
        rawValue = UUID()
    }

    public var description: String {
        rawValue.uuidString
    }

    public init(from decoder: Decoder) throws {
        rawValue = try decodeCanonicalSyncUUID(from: decoder)
    }

    public func encode(to encoder: Encoder) throws {
        try encodeCanonicalSyncUUID(rawValue, to: encoder)
    }
}

public struct SyncReplicaID: Hashable, Codable, Sendable, CustomStringConvertible {
    public let rawValue: UUID

    public init(rawValue: UUID) {
        self.rawValue = rawValue
    }

    public init() {
        rawValue = UUID()
    }

    public var description: String {
        rawValue.uuidString
    }

    public init(from decoder: Decoder) throws {
        rawValue = try decodeCanonicalSyncUUID(from: decoder)
    }

    public func encode(to encoder: Encoder) throws {
        try encodeCanonicalSyncUUID(rawValue, to: encoder)
    }
}

public struct SyncEditSessionID: Hashable, Codable, Sendable, CustomStringConvertible {
    public let rawValue: UUID

    public init(rawValue: UUID) {
        self.rawValue = rawValue
    }

    public init() {
        rawValue = UUID()
    }

    public var description: String {
        rawValue.uuidString
    }

    public init(from decoder: Decoder) throws {
        rawValue = try decodeCanonicalSyncUUID(from: decoder)
    }

    public func encode(to encoder: Encoder) throws {
        try encodeCanonicalSyncUUID(rawValue, to: encoder)
    }
}

public struct SyncRevisionID: Hashable, Codable, Sendable, CustomStringConvertible {
    public let rawValue: UUID

    public init(rawValue: UUID) {
        self.rawValue = rawValue
    }

    public init() {
        rawValue = UUID()
    }

    public var description: String {
        rawValue.uuidString
    }

    public init(from decoder: Decoder) throws {
        rawValue = try decodeCanonicalSyncUUID(from: decoder)
    }

    public func encode(to encoder: Encoder) throws {
        try encodeCanonicalSyncUUID(rawValue, to: encoder)
    }
}

public struct SyncBranchID: Hashable, Codable, Sendable, CustomStringConvertible {
    public let rawValue: UUID

    public init(rawValue: UUID) {
        self.rawValue = rawValue
    }

    public init() {
        rawValue = UUID()
    }

    public var description: String {
        rawValue.uuidString
    }

    public init(from decoder: Decoder) throws {
        rawValue = try decodeCanonicalSyncUUID(from: decoder)
    }

    public func encode(to encoder: Encoder) throws {
        try encodeCanonicalSyncUUID(rawValue, to: encoder)
    }
}

public struct SyncMutationID: Hashable, Codable, Sendable, CustomStringConvertible {
    public let rawValue: UUID

    public init(rawValue: UUID) {
        self.rawValue = rawValue
    }

    public init() {
        rawValue = UUID()
    }

    public var description: String {
        rawValue.uuidString
    }

    public init(from decoder: Decoder) throws {
        rawValue = try decodeCanonicalSyncUUID(from: decoder)
    }

    public func encode(to encoder: Encoder) throws {
        try encodeCanonicalSyncUUID(rawValue, to: encoder)
    }
}

/// 同期上の話identity。`SyncWorkID`は`.novelpkg`の`NovelDocument.id`から独立する。
/// 同じpackageを複数回取り込んでも、呼び出し側が明示的にbindingしない限り
/// 同じ同期作品へ自動結合しない。
public struct EpisodeSyncKey: Hashable, Codable, Sendable {
    private enum CodingKeys: String, CodingKey {
        case workID
        case episodeID
    }

    public let workID: SyncWorkID
    public let episodeID: EpisodeID

    public init(workID: SyncWorkID, episodeID: EpisodeID) {
        self.workID = workID
        self.episodeID = episodeID
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        workID = try container.decode(SyncWorkID.self, forKey: .workID)
        let episodeUUID = try decodeCanonicalSyncUUID(forKey: .episodeID, in: container)
        episodeID = EpisodeID(rawValue: episodeUUID)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(workID, forKey: .workID)
        try container.encode(episodeID.rawValue.uuidString, forKey: .episodeID)
    }
}

func decodeCanonicalSyncUUID(from decoder: Decoder) throws -> UUID {
    let container = try decoder.singleValueContainer()
    let value = try container.decode(String.self)
    guard value.utf8.count == 36,
          let uuid = UUID(uuidString: value),
          uuid.uuidString == value else {
        throw DecodingError.dataCorruptedError(
            in: container,
            debugDescription: "sync UUID must be a canonical uppercase 36-character string"
        )
    }
    return uuid
}

func encodeCanonicalSyncUUID(_ uuid: UUID, to encoder: Encoder) throws {
    var container = encoder.singleValueContainer()
    try container.encode(uuid.uuidString)
}

func decodeCanonicalSyncUUID<Key: CodingKey>(
    forKey key: Key,
    in container: KeyedDecodingContainer<Key>
) throws -> UUID {
    let value = try container.decode(String.self, forKey: key)
    guard value.utf8.count == 36,
          let uuid = UUID(uuidString: value),
          uuid.uuidString == value else {
        throw DecodingError.dataCorruptedError(
            forKey: key,
            in: container,
            debugDescription: "sync UUID must be a canonical uppercase 36-character string"
        )
    }
    return uuid
}

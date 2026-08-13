import Foundation

public enum NoteSyncStateError: Error, Equatable, Sendable {
    case unsupportedProtocolVersion(Int)
    case workMismatch
    case overlappingDirtyKeys
    case tooManyEntities
    case unsafeRoot
    case invalidFile
    case stateTooLarge
}

public struct NoteSyncDirtySet: Hashable, Sendable {
    public var saves: Set<NoteSyncEntityKey>
    public var deletes: Set<NoteSyncEntityKey>

    public static let empty = NoteSyncDirtySet(saves: [], deletes: [])

    public init(saves: Set<NoteSyncEntityKey>, deletes: Set<NoteSyncEntityKey>) {
        self.saves = saves
        self.deletes = deletes
    }

    public var isEmpty: Bool {
        saves.isEmpty && deletes.isEmpty
    }

    public func contains(_ key: NoteSyncEntityKey) -> Bool {
        saves.contains(key) || deletes.contains(key)
    }

    public static func difference(
        from previous: [NoteSyncEntityKey: NoteSyncRecord],
        to current: [NoteSyncEntityKey: NoteSyncRecord]
    ) -> NoteSyncDirtySet {
        var saves: Set<NoteSyncEntityKey> = []
        var deletes: Set<NoteSyncEntityKey> = []
        for key in Set(previous.keys).union(current.keys) {
            let previousDigest = previous[key]?.digest
            let currentDigest = current[key]?.digest
            if currentDigest == nil {
                deletes.insert(key)
            } else if previousDigest != currentDigest {
                saves.insert(key)
            }
        }
        return NoteSyncDirtySet(saves: saves, deletes: deletes)
    }

    func validated() throws -> NoteSyncDirtySet {
        guard saves.isDisjoint(with: deletes) else {
            throw NoteSyncStateError.overlappingDirtyKeys
        }
        return self
    }
}

public struct NoteSyncState: Hashable, Sendable {
    public let protocolVersion: Int
    public let workID: SyncWorkID
    public var dirty: NoteSyncDirtySet
    public var lastAckedDigests: [NoteSyncEntityKey: SyncContentDigest]
    public var pendingConflictKeys: Set<NoteSyncEntityKey>
    public var forceSendKeys: Set<NoteSyncEntityKey>

    public static func empty(workID: SyncWorkID) -> NoteSyncState {
        NoteSyncState(
            protocolVersion: NoteSyncWireProtocol.currentVersion,
            workID: workID,
            dirty: .empty,
            lastAckedDigests: [:],
            pendingConflictKeys: [],
            forceSendKeys: []
        )
    }

    public init(
        protocolVersion: Int = NoteSyncWireProtocol.currentVersion,
        workID: SyncWorkID,
        dirty: NoteSyncDirtySet,
        lastAckedDigests: [NoteSyncEntityKey: SyncContentDigest],
        pendingConflictKeys: Set<NoteSyncEntityKey> = [],
        forceSendKeys: Set<NoteSyncEntityKey> = []
    ) {
        self.protocolVersion = protocolVersion
        self.workID = workID
        self.dirty = dirty
        self.lastAckedDigests = lastAckedDigests
        self.pendingConflictKeys = pendingConflictKeys
        self.forceSendKeys = forceSendKeys
    }

    public func validate() throws {
        guard protocolVersion == NoteSyncWireProtocol.currentVersion else {
            throw NoteSyncStateError.unsupportedProtocolVersion(protocolVersion)
        }
        _ = try dirty.validated()
        let allKeys = dirty.saves
            .union(dirty.deletes)
            .union(lastAckedDigests.keys)
            .union(pendingConflictKeys)
            .union(forceSendKeys)
        guard allKeys.count <= WorkSnapshot.maximumTotalEntityCount else {
            throw NoteSyncStateError.tooManyEntities
        }
        guard allKeys.allSatisfy({ $0.workID == workID }) else {
            throw NoteSyncStateError.workMismatch
        }
    }
}

extension NoteSyncDirtySet: Codable {
    private enum CodingKeys: String, CodingKey {
        case saves
        case deletes
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        saves = try Set(container.decode([NoteSyncEntityKey].self, forKey: .saves))
        deletes = try Set(container.decode([NoteSyncEntityKey].self, forKey: .deletes))
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(saves.sorted(), forKey: .saves)
        try container.encode(deletes.sorted(), forKey: .deletes)
    }
}

extension NoteSyncState: Codable {
    private enum CodingKeys: String, CodingKey {
        case protocolVersion
        case workID
        case dirty
        case lastAcked
        case pendingConflictKeys
        case forceSendKeys
    }

    private struct AckedEntry: Codable {
        let key: NoteSyncEntityKey
        let digest: SyncContentDigest
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try requireCurrentNoteSyncWireVersion(forKey: .protocolVersion, in: container)
        protocolVersion = NoteSyncWireProtocol.currentVersion
        workID = try container.decode(SyncWorkID.self, forKey: .workID)
        dirty = try container.decode(NoteSyncDirtySet.self, forKey: .dirty)
        let acked = try container.decode([AckedEntry].self, forKey: .lastAcked)
        var lastAcked: [NoteSyncEntityKey: SyncContentDigest] = [:]
        for entry in acked {
            if lastAcked[entry.key] != nil {
                throw DecodingError.dataCorruptedError(
                    forKey: .lastAcked,
                    in: container,
                    debugDescription: "lastAcked keys must be unique"
                )
            }
            lastAcked[entry.key] = entry.digest
        }
        lastAckedDigests = lastAcked
        pendingConflictKeys = try Set(container.decode([NoteSyncEntityKey].self, forKey: .pendingConflictKeys))
        forceSendKeys = try Set(container.decode([NoteSyncEntityKey].self, forKey: .forceSendKeys))
        try validate()
    }

    public func encode(to encoder: Encoder) throws {
        try validate()
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(protocolVersion, forKey: .protocolVersion)
        try container.encode(workID, forKey: .workID)
        try container.encode(dirty, forKey: .dirty)
        let acked = lastAckedDigests
            .map { AckedEntry(key: $0.key, digest: $0.value) }
            .sorted { $0.key < $1.key }
        try container.encode(acked, forKey: .lastAcked)
        try container.encode(pendingConflictKeys.sorted(), forKey: .pendingConflictKeys)
        try container.encode(forceSendKeys.sorted(), forKey: .forceSendKeys)
    }
}

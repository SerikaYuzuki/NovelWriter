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
    /// Monotonic token for each locally dirty entity. A network acknowledgement
    /// must carry the token it observed, otherwise a save that happened while
    /// the request was in flight could be cleared by the older response.
    public var dirtyGenerations: [NoteSyncEntityKey: Int]

    public static func empty(workID: SyncWorkID) -> NoteSyncState {
        NoteSyncState(
            protocolVersion: NoteSyncWireProtocol.currentVersion,
            workID: workID,
            dirty: .empty,
            lastAckedDigests: [:],
            pendingConflictKeys: [],
            forceSendKeys: [],
            dirtyGenerations: [:]
        )
    }

    public init(
        protocolVersion: Int = NoteSyncWireProtocol.currentVersion,
        workID: SyncWorkID,
        dirty: NoteSyncDirtySet,
        lastAckedDigests: [NoteSyncEntityKey: SyncContentDigest],
        pendingConflictKeys: Set<NoteSyncEntityKey> = [],
        forceSendKeys: Set<NoteSyncEntityKey> = [],
        dirtyGenerations: [NoteSyncEntityKey: Int] = [:]
    ) {
        self.protocolVersion = protocolVersion
        self.workID = workID
        self.dirty = dirty
        self.lastAckedDigests = lastAckedDigests
        self.pendingConflictKeys = pendingConflictKeys
        self.forceSendKeys = forceSendKeys
        self.dirtyGenerations = dirtyGenerations
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
            .union(dirtyGenerations.keys)
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
        case dirtyGenerations
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
        dirtyGenerations = try container.decodeIfPresent(
            [NoteSyncEntityKey: Int].self,
            forKey: .dirtyGenerations
        ) ?? [:]
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
        try container.encode(dirtyGenerations, forKey: .dirtyGenerations)
    }
}

public extension NoteSyncConflict {
    /// Durable Note state after restart. Empty pending keys are not a conflict.
    static func pending(in state: NoteSyncState) -> NoteSyncConflict? {
        guard !state.pendingConflictKeys.isEmpty else { return nil }
        return NoteSyncConflict(workID: state.workID, keys: state.pendingConflictKeys)
    }

    /// Entity keys that differ between two whole-work snapshots.
    /// This is reserved for an explicit legacy-recovery flow; normal Note
    /// preparation does not auto-migrate a leftover Work review.
    static func leftover(
        workID: SyncWorkID,
        local: WorkSnapshot,
        remote: WorkSnapshot
    ) throws -> NoteSyncConflict? {
        let delta = try NoteSyncProjection.changes(workID: workID, from: remote, to: local)
        var keys = delta.saves.union(delta.deletes)
        if keys.isEmpty {
            keys = try Set(NoteSyncProjection.records(workID: workID, snapshot: local).map(\.key))
        }
        guard !keys.isEmpty else { return nil }
        return NoteSyncConflict(workID: workID, keys: keys)
    }
}

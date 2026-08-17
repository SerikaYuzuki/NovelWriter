import Foundation
import NovelSyncV2

public enum SyncV2HistorySource: String, Codable, Hashable, Sendable {
    case local
    case remote
}

public enum SyncV2HistoryAvailability: String, Codable, Hashable, Sendable {
    case available
    case unavailable
}

public struct SyncV2LocalHistoryOccurrence: Hashable, Sendable {
    public let occurrenceID: UUID
    public let snapshotID: SnapshotID
    public let reason: String
    public let pinned: Bool
    public let localGeneration: Int64
    public let createdAt: Date

    public init(
        occurrenceID: UUID,
        snapshotID: SnapshotID,
        reason: String,
        pinned: Bool,
        localGeneration: Int64,
        createdAt: Date
    ) {
        self.occurrenceID = occurrenceID
        self.snapshotID = snapshotID
        self.reason = reason
        self.pinned = pinned
        self.localGeneration = localGeneration
        self.createdAt = createdAt
    }
}

public struct SyncV2LocalHistoryPage: Hashable, Sendable {
    public let items: [SyncV2LocalHistoryOccurrence]
    public let nextCursor: String?

    public init(items: [SyncV2LocalHistoryOccurrence], nextCursor: String?) {
        self.items = items
        self.nextCursor = nextCursor
    }
}

/// One occurrence, never a snapshot-ID merge. A local and a remote occurrence
/// with the same SnapshotID remain two rows because their retention and restore
/// authority are different.
public struct SyncV2HistoryItem: Hashable, Sendable {
    public let occurrenceID: UUID
    public let snapshotID: SnapshotID
    public let reason: String
    public let pinned: Bool
    public let localGeneration: Int64?
    public let createdAt: Date
    public let source: SyncV2HistorySource
    public let localAvailability: SyncV2HistoryAvailability
    public let onlineAvailability: SyncV2HistoryAvailability

    public init(
        occurrenceID: UUID,
        snapshotID: SnapshotID,
        reason: String,
        pinned: Bool,
        localGeneration: Int64?,
        createdAt: Date,
        source: SyncV2HistorySource,
        localAvailability: SyncV2HistoryAvailability,
        onlineAvailability: SyncV2HistoryAvailability
    ) {
        self.occurrenceID = occurrenceID
        self.snapshotID = snapshotID
        self.reason = reason
        self.pinned = pinned
        self.localGeneration = localGeneration
        self.createdAt = createdAt
        self.source = source
        self.localAvailability = localAvailability
        self.onlineAvailability = onlineAvailability
    }
}

public struct SyncV2HistoryPage: Sendable {
    public let items: [SyncV2HistoryItem]
    public let nextCursor: String?
    public let localAvailability: SyncV2HistoryAvailability
    public let onlineAvailability: SyncV2HistoryAvailability
    public let onlineFailure: SyncV2Failure?

    public init(
        items: [SyncV2HistoryItem],
        nextCursor: String?,
        localAvailability: SyncV2HistoryAvailability,
        onlineAvailability: SyncV2HistoryAvailability,
        onlineFailure: SyncV2Failure? = nil
    ) {
        self.items = items
        self.nextCursor = nextCursor
        self.localAvailability = localAvailability
        self.onlineAvailability = onlineAvailability
        self.onlineFailure = onlineFailure
    }
}

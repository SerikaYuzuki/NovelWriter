import Foundation
import NovelSyncV2

public enum V2BackfillStatus: String, Sendable {
    case running, paused, failed, suspended, complete
}

public enum V2SnapshotAvailability: Sendable {
    case local, unfetched, unknown
}

public struct V2BackfillState: Sendable {
    public let workID: WorkID
    public let rootSnapshotID: SnapshotID
    public let binding: V2AccountBinding
    public let resumeCursor: String?
    public let status: V2BackfillStatus
    public let receivedSnapshots: Int64
    public let totalSnapshots: Int64?
    public let failureCode: String?
}

/// Only closed, fully validated groups enter SQLite. A split group's objects
/// stay in the downloader until its manifest arrives; restart replays that group.
public struct V2BackfillPage: Sendable {
    public let snapshots: [EncodedSnapshot]
    public let resumeCursor: String?
    public let terminal: Bool

    public init(snapshots: [EncodedSnapshot], resumeCursor: String?, terminal: Bool) {
        self.snapshots = snapshots
        self.resumeCursor = resumeCursor
        self.terminal = terminal
    }
}

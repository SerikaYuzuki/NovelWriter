import Foundation

struct HistoryOccurrenceRow: SQLiteRowDecodable {
    static let columns = """
    snapshot_id,reason,pinned,local_generation,occurrence_id,created_at
    """
    let snapshotID: Data?
    let reason: String?
    let pinned: Int64?
    let localGeneration: Int64?
    let occurrenceID: String?
    let createdAt: String?

    init(_ row: SQLiteRow) throws {
        snapshotID = try row.blob("snapshot_id")
        reason = try row.text("reason")
        pinned = try row.int64("pinned")
        localGeneration = try row.int64("local_generation")
        occurrenceID = try row.text("occurrence_id")
        createdAt = try row.text("created_at")
    }
}

struct HistoryPageRow: SQLiteRowDecodable {
    static let columns = """
    occurrence_id,snapshot_id,reason,pinned,local_generation,created_at
    """
    let occurrenceID: String?
    let snapshotID: Data?
    let reason: String?
    let pinned: Int64?
    let localGeneration: Int64?
    let createdAt: String?

    init(_ row: SQLiteRow) throws {
        occurrenceID = try row.text("occurrence_id")
        snapshotID = try row.blob("snapshot_id")
        reason = try row.text("reason")
        pinned = try row.int64("pinned")
        localGeneration = try row.int64("local_generation")
        createdAt = try row.text("created_at")
    }
}

struct HistoryPromotionRow: SQLiteRowDecodable {
    static let columns = """
    reason,pinned
    """
    let reason: String?
    let pinned: Int64?

    init(_ row: SQLiteRow) throws {
        reason = try row.text("reason")
        pinned = try row.int64("pinned")
    }
}

struct ShallowBoundaryRow: SQLiteRowDecodable {
    static let columns = """
    work_id,snapshot_id,parent_snapshot_id
    """
    let workID: String?
    let snapshotID: Data?
    let parentSnapshotID: Data?

    init(_ row: SQLiteRow) throws {
        workID = try row.text("work_id")
        snapshotID = try row.blob("snapshot_id")
        parentSnapshotID = try row.blob("parent_snapshot_id")
    }
}

struct HistoryBackfillRow: SQLiteRowDecodable {
    static let columns = """
    root_snapshot_id,server_instance_id,protocol_epoch,account_id,account_fence,resume_cursor,state,
    received_snapshots,total_snapshots,failure_code
    """
    let rootSnapshotID: Data?
    let serverInstanceID: String?
    let protocolEpoch: Int64?
    let accountID: String?
    let accountFence: String?
    let resumeCursor: String?
    let state: String?
    let receivedSnapshots: Int64?
    let totalSnapshots: Int64?
    let failureCode: String?

    init(_ row: SQLiteRow) throws {
        rootSnapshotID = try row.blob("root_snapshot_id")
        serverInstanceID = try row.text("server_instance_id")
        protocolEpoch = try row.int64("protocol_epoch")
        accountID = try row.text("account_id")
        accountFence = try row.text("account_fence")
        resumeCursor = try row.text("resume_cursor")
        state = try row.text("state")
        receivedSnapshots = try row.int64("received_snapshots")
        totalSnapshots = try row.int64("total_snapshots")
        failureCode = try row.text("failure_code")
    }
}

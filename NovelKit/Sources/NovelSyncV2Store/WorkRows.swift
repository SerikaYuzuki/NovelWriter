import Foundation

struct WorkRow: SQLiteRowDecodable {
    static let columns = """
    w.work_id,w.document_id,w.local_generation,w.current_snapshot_id,
    w.acknowledged_head_generation,w.document_created_at,w.sync_lane
    """
    let workID: String?
    let documentID: String?
    let localGeneration: Int64?
    let currentSnapshotID: Data?
    let acknowledgedHeadGeneration: Int64?
    let documentCreatedAt: String?
    let syncLane: String?

    init(_ row: SQLiteRow) throws {
        workID = try row.text("work_id")
        documentID = try row.text("document_id")
        localGeneration = try row.int64("local_generation")
        currentSnapshotID = try row.blob("current_snapshot_id")
        acknowledgedHeadGeneration = try row.int64("acknowledged_head_generation")
        documentCreatedAt = try row.text("document_created_at")
        syncLane = try row.text("sync_lane")
    }
}

struct WorkCurrentRow: SQLiteRowDecodable {
    static let columns = """
    current_snapshot_id,local_generation
    """
    let currentSnapshotID: Data?
    let localGeneration: Int64?

    init(_ row: SQLiteRow) throws {
        currentSnapshotID = try row.blob("current_snapshot_id")
        localGeneration = try row.int64("local_generation")
    }
}

struct WorkAnchorRow: SQLiteRowDecodable {
    static let columns = """
    document_id,document_created_at
    """
    let documentID: String?
    let documentCreatedAt: String?

    init(_ row: SQLiteRow) throws {
        documentID = try row.text("document_id")
        documentCreatedAt = try row.text("document_created_at")
    }
}

struct AcknowledgedHeadRow: SQLiteRowDecodable {
    static let columns = """
    acknowledged_head_snapshot_id,acknowledged_head_generation
    """
    let acknowledgedHeadSnapshotID: Data?
    let acknowledgedHeadGeneration: Int64?

    init(_ row: SQLiteRow) throws {
        acknowledgedHeadSnapshotID = try row.blob("acknowledged_head_snapshot_id")
        acknowledgedHeadGeneration = try row.int64("acknowledged_head_generation")
    }
}

struct RemoteEquivalentRow: SQLiteRowDecodable {
    static let columns = """
    remote_snapshot_id,remote_generation
    """
    let remoteSnapshotID: Data?
    let remoteGeneration: Int64?

    init(_ row: SQLiteRow) throws {
        remoteSnapshotID = try row.blob("remote_snapshot_id")
        remoteGeneration = try row.int64("remote_generation")
    }
}

struct WorkDeletionRow: SQLiteRowDecodable {
    static let columns = """
    server_instance_id,protocol_epoch,account_id,account_fence,phase
    """
    let serverInstanceID: String?
    let protocolEpoch: Int64?
    let accountID: String?
    let accountFence: String?
    let phase: String?

    init(_ row: SQLiteRow) throws {
        serverInstanceID = try row.text("server_instance_id")
        protocolEpoch = try row.int64("protocol_epoch")
        accountID = try row.text("account_id")
        accountFence = try row.text("account_fence")
        phase = try row.text("phase")
    }
}

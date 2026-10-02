import Foundation

struct InboxBatchRow: SQLiteRowDecodable {
    static let columns = """
    work_id,snapshot_id,expected_current_snapshot_id,expected_local_generation,expected_remote_head_snapshot_id,
    expected_remote_head_generation,manifest_bytes
    """
    let workID: String?
    let snapshotID: Data?
    let expectedCurrentSnapshotID: Data?
    let expectedLocalGeneration: Int64?
    let expectedRemoteHeadSnapshotID: Data?
    let expectedRemoteHeadGeneration: Int64?
    let manifestBytes: Data?

    init(_ row: SQLiteRow) throws {
        workID = try row.text("work_id")
        snapshotID = try row.blob("snapshot_id")
        expectedCurrentSnapshotID = try row.blob("expected_current_snapshot_id")
        expectedLocalGeneration = try row.int64("expected_local_generation")
        expectedRemoteHeadSnapshotID = try row.blob("expected_remote_head_snapshot_id")
        expectedRemoteHeadGeneration = try row.int64("expected_remote_head_generation")
        manifestBytes = try row.blob("manifest_bytes")
    }
}

struct InboxSnapshotRow: SQLiteRowDecodable {
    static let columns = """
    snapshot_id,manifest_bytes,work_id,is_head,verified
    """
    let snapshotID: Data?
    let manifestBytes: Data?
    let workID: String?
    let isHead: Int64?
    let verified: Int64?

    init(_ row: SQLiteRow) throws {
        snapshotID = try row.blob("snapshot_id")
        manifestBytes = try row.blob("manifest_bytes")
        workID = try row.text("work_id")
        isHead = try row.int64("is_head")
        verified = try row.int64("verified")
    }
}

struct InboxObjectRow: SQLiteRowDecodable {
    static let columns = """
    object_id,byte_count,bytes,verified
    """
    let objectID: Data?
    let byteCount: Int64?
    let bytes: Data?
    let verified: Int64?

    init(_ row: SQLiteRow) throws {
        objectID = try row.blob("object_id")
        byteCount = try row.int64("byte_count")
        bytes = try row.blob("bytes")
        verified = try row.int64("verified")
    }
}

struct InboxReplayBatchRow: SQLiteRowDecodable {
    static let columns = """
    work_id,document_id,document_created_at,server_instance_id,protocol_epoch,account_id,account_fence,
    snapshot_id,expected_current_snapshot_id,expected_local_generation,expected_remote_head_snapshot_id,
    expected_remote_head_generation,state,manifest_bytes
    """
    let workID: String?
    let documentID: String?
    let documentCreatedAt: String?
    let serverInstanceID: String?
    let protocolEpoch: Int64?
    let accountID: String?
    let accountFence: String?
    let snapshotID: Data?
    let expectedCurrentSnapshotID: Data?
    let expectedLocalGeneration: Int64?
    let expectedRemoteHeadSnapshotID: Data?
    let expectedRemoteHeadGeneration: Int64?
    let state: String?
    let manifestBytes: Data?

    init(_ row: SQLiteRow) throws {
        workID = try row.text("work_id")
        documentID = try row.text("document_id")
        documentCreatedAt = try row.text("document_created_at")
        serverInstanceID = try row.text("server_instance_id")
        protocolEpoch = try row.int64("protocol_epoch")
        accountID = try row.text("account_id")
        accountFence = try row.text("account_fence")
        snapshotID = try row.blob("snapshot_id")
        expectedCurrentSnapshotID = try row.blob("expected_current_snapshot_id")
        expectedLocalGeneration = try row.int64("expected_local_generation")
        expectedRemoteHeadSnapshotID = try row.blob("expected_remote_head_snapshot_id")
        expectedRemoteHeadGeneration = try row.int64("expected_remote_head_generation")
        state = try row.text("state")
        manifestBytes = try row.blob("manifest_bytes")
    }
}

struct InboxReplaySnapshotRow: SQLiteRowDecodable {
    static let columns = """
    snapshot_id,manifest_bytes,is_head
    """
    let snapshotID: Data?
    let manifestBytes: Data?
    let isHead: Int64?

    init(_ row: SQLiteRow) throws {
        snapshotID = try row.blob("snapshot_id")
        manifestBytes = try row.blob("manifest_bytes")
        isHead = try row.int64("is_head")
    }
}

struct InboxClosureRow: SQLiteRowDecodable {
    static let columns = """
    snapshot_id,entity_key,object_id,byte_count,content_type
    """
    let snapshotID: Data?
    let entityKey: String?
    let objectID: Data?
    let byteCount: Int64?
    let contentType: String?

    init(_ row: SQLiteRow) throws {
        snapshotID = try row.blob("snapshot_id")
        entityKey = try row.text("entity_key")
        objectID = try row.blob("object_id")
        byteCount = try row.int64("byte_count")
        contentType = try row.text("content_type")
    }
}

struct InboxManifestRow: SQLiteRowDecodable {
    static let columns = """
    inbox_id,manifest_bytes
    """
    let inboxID: String?
    let manifestBytes: Data?

    init(_ row: SQLiteRow) throws {
        inboxID = try row.text("inbox_id")
        manifestBytes = try row.blob("manifest_bytes")
    }
}

struct InboxHeadRow: SQLiteRowDecodable {
    static let columns = """
    snapshot_id,expected_remote_head_generation
    """
    let snapshotID: Data?
    let expectedRemoteHeadGeneration: Int64?

    init(_ row: SQLiteRow) throws {
        snapshotID = try row.blob("snapshot_id")
        expectedRemoteHeadGeneration = try row.int64("expected_remote_head_generation")
    }
}

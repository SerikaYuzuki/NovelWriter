import Foundation

struct SealedCommandRow: SQLiteRowDecodable {
    static let columns = """
    command_id,work_id,intent_id,account_id,account_fence,server_instance_id,protocol_epoch,command_kind,
    canonical_request,request_digest,source_snapshot_id,source_generation,status
    """
    let commandID: String?
    let workID: String?
    let intentID: String?
    let accountID: String?
    let accountFence: String?
    let serverInstanceID: String?
    let protocolEpoch: Int64?
    let commandKind: String?
    let canonicalRequest: Data?
    let requestDigest: Data?
    let sourceSnapshotID: Data?
    let sourceGeneration: Int64?
    let status: String?

    init(_ row: SQLiteRow) throws {
        commandID = try row.text("command_id")
        workID = try row.text("work_id")
        intentID = try row.text("intent_id")
        accountID = try row.text("account_id")
        accountFence = try row.text("account_fence")
        serverInstanceID = try row.text("server_instance_id")
        protocolEpoch = try row.int64("protocol_epoch")
        commandKind = try row.text("command_kind")
        canonicalRequest = try row.blob("canonical_request")
        requestDigest = try row.blob("request_digest")
        sourceSnapshotID = try row.blob("source_snapshot_id")
        sourceGeneration = try row.int64("source_generation")
        status = try row.text("status")
    }
}

struct CommandSourceRow: SQLiteRowDecodable {
    static let columns = """
    work_id,source_snapshot_id,source_generation
    """
    let workID: String?
    let sourceSnapshotID: Data?
    let sourceGeneration: Int64?

    init(_ row: SQLiteRow) throws {
        workID = try row.text("work_id")
        sourceSnapshotID = try row.blob("source_snapshot_id")
        sourceGeneration = try row.int64("source_generation")
    }
}

struct AcknowledgedCommandRow: SQLiteRowDecodable {
    static let columns = """
    command_id,source_snapshot_id
    """
    let commandID: String?
    let sourceSnapshotID: Data?

    init(_ row: SQLiteRow) throws {
        commandID = try row.text("command_id")
        sourceSnapshotID = try row.blob("source_snapshot_id")
    }
}

struct AcknowledgedObjectRow: SQLiteRowDecodable {
    static let columns = """
    c.work_id,c.command_kind,c.source_snapshot_id,r.terminal_result,t.object_id,
    CASE WHEN t.object_id IS NULL AND c.command_kind IN ('prepareObject','finalizeObject')
         THEN c.canonical_request ELSE NULL END AS canonical_request
    """
    let workID: String?
    let commandKind: String?
    let sourceSnapshotID: Data?
    let terminalResult: String?
    let objectID: Data?
    let canonicalRequest: Data?

    init(_ row: SQLiteRow) throws {
        workID = try row.text("work_id")
        commandKind = try row.text("command_kind")
        sourceSnapshotID = try row.blob("source_snapshot_id")
        terminalResult = try row.text("terminal_result")
        objectID = try row.blob("object_id")
        canonicalRequest = try row.blob("canonical_request")
    }
}

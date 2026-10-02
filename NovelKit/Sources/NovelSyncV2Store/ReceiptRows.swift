import Foundation

struct ReceiptRow: SQLiteRowDecodable {
    static let columns = """
    terminal_result,response_status,canonical_response,account_matched,command_digest_matched,resource_matched,
    head_matched,state_matched,remote_head_snapshot_id,remote_head_generation,clone_head_snapshot_id,
    clone_head_generation
    """
    let terminalResult: String?
    let responseStatus: Int64?
    let canonicalResponse: Data?
    let accountMatched: Int64?
    let commandDigestMatched: Int64?
    let resourceMatched: Int64?
    let headMatched: Int64?
    let stateMatched: Int64?
    let remoteHeadSnapshotID: Data?
    let remoteHeadGeneration: Int64?
    let cloneHeadSnapshotID: Data?
    let cloneHeadGeneration: Int64?

    init(_ row: SQLiteRow) throws {
        terminalResult = try row.text("terminal_result")
        responseStatus = try row.int64("response_status")
        canonicalResponse = try row.blob("canonical_response")
        accountMatched = try row.int64("account_matched")
        commandDigestMatched = try row.int64("command_digest_matched")
        resourceMatched = try row.int64("resource_matched")
        headMatched = try row.int64("head_matched")
        stateMatched = try row.int64("state_matched")
        remoteHeadSnapshotID = try row.blob("remote_head_snapshot_id")
        remoteHeadGeneration = try row.int64("remote_head_generation")
        cloneHeadSnapshotID = try row.blob("clone_head_snapshot_id")
        cloneHeadGeneration = try row.int64("clone_head_generation")
    }
}

struct ReceiptHeadRow: SQLiteRowDecodable {
    static let columns = """
    remote_head_snapshot_id,remote_head_generation
    """
    let remoteHeadSnapshotID: Data?
    let remoteHeadGeneration: Int64?

    init(_ row: SQLiteRow) throws {
        remoteHeadSnapshotID = try row.blob("remote_head_snapshot_id")
        remoteHeadGeneration = try row.int64("remote_head_generation")
    }
}

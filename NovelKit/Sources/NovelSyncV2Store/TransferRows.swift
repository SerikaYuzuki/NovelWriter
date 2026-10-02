import Foundation

struct UploadTransferRow: SQLiteRowDecodable {
    static let columns = """
    transfer_id,command_id,work_id,object_id,source_snapshot_id,source_generation,upload_id,capability,
    exact_bytes,bytes_digest,acknowledged_offset,expires_at,lifecycle
    """
    let transferID: String?
    let commandID: String?
    let workID: String?
    let objectID: Data?
    let sourceSnapshotID: Data?
    let sourceGeneration: Int64?
    let uploadID: String?
    let capability: String?
    let exactBytes: Data?
    let bytesDigest: Data?
    let acknowledgedOffset: Int64?
    let expiresAt: String?
    let lifecycle: String?

    init(_ row: SQLiteRow) throws {
        transferID = try row.text("transfer_id")
        commandID = try row.text("command_id")
        workID = try row.text("work_id")
        objectID = try row.blob("object_id")
        sourceSnapshotID = try row.blob("source_snapshot_id")
        sourceGeneration = try row.int64("source_generation")
        uploadID = try row.text("upload_id")
        capability = try row.text("capability")
        exactBytes = try row.blob("exact_bytes")
        bytesDigest = try row.blob("bytes_digest")
        acknowledgedOffset = try row.int64("acknowledged_offset")
        expiresAt = try row.text("expires_at")
        lifecycle = try row.text("lifecycle")
    }
}

struct UploadProgressRow: SQLiteRowDecodable {
    static let columns = """
    exact_bytes,acknowledged_offset,lifecycle
    """
    let exactBytes: Data?
    let acknowledgedOffset: Int64?
    let lifecycle: String?

    init(_ row: SQLiteRow) throws {
        exactBytes = try row.blob("exact_bytes")
        acknowledgedOffset = try row.int64("acknowledged_offset")
        lifecycle = try row.text("lifecycle")
    }
}

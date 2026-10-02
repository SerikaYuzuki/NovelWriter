import Foundation

struct IntentRow: SQLiteRowDecodable {
    static let columns = """
    intent_id,work_id,source_snapshot_id,source_generation,kind,status
    """
    let intentID: String?
    let workID: String?
    let sourceSnapshotID: Data?
    let sourceGeneration: Int64?
    let kind: String?
    let status: String?

    init(_ row: SQLiteRow) throws {
        intentID = try row.text("intent_id")
        workID = try row.text("work_id")
        sourceSnapshotID = try row.blob("source_snapshot_id")
        sourceGeneration = try row.int64("source_generation")
        kind = try row.text("kind")
        status = try row.text("status")
    }
}

struct IntentValidationRow: SQLiteRowDecodable {
    static let columns = """
    work_id,source_snapshot_id,source_generation,kind,status
    """
    let workID: String?
    let sourceSnapshotID: Data?
    let sourceGeneration: Int64?
    let kind: String?
    let status: String?

    init(_ row: SQLiteRow) throws {
        workID = try row.text("work_id")
        sourceSnapshotID = try row.blob("source_snapshot_id")
        sourceGeneration = try row.int64("source_generation")
        kind = try row.text("kind")
        status = try row.text("status")
    }
}

struct IntentSourceRow: SQLiteRowDecodable {
    static let columns = """
    source_snapshot_id,source_generation,status
    """
    let sourceSnapshotID: Data?
    let sourceGeneration: Int64?
    let status: String?

    init(_ row: SQLiteRow) throws {
        sourceSnapshotID = try row.blob("source_snapshot_id")
        sourceGeneration = try row.int64("source_generation")
        status = try row.text("status")
    }
}

struct PreparedIntentRow: SQLiteRowDecodable {
    static let columns = """
    intent_id,source_snapshot_id,source_generation
    """
    let intentID: String?
    let sourceSnapshotID: Data?
    let sourceGeneration: Int64?

    init(_ row: SQLiteRow) throws {
        intentID = try row.text("intent_id")
        sourceSnapshotID = try row.blob("source_snapshot_id")
        sourceGeneration = try row.int64("source_generation")
    }
}

import Foundation

struct RestoreCommandRow: SQLiteRowDecodable {
    static let columns = """
    pre_restore_snapshot_id,selected_snapshot_id,result_snapshot_id,expected_remote_head_snapshot_id,
    expected_remote_head_generation
    """
    let preRestoreSnapshotID: Data?
    let selectedSnapshotID: Data?
    let resultSnapshotID: Data?
    let expectedRemoteHeadSnapshotID: Data?
    let expectedRemoteHeadGeneration: Int64?

    init(_ row: SQLiteRow) throws {
        preRestoreSnapshotID = try row.blob("pre_restore_snapshot_id")
        selectedSnapshotID = try row.blob("selected_snapshot_id")
        resultSnapshotID = try row.blob("result_snapshot_id")
        expectedRemoteHeadSnapshotID = try row.blob("expected_remote_head_snapshot_id")
        expectedRemoteHeadGeneration = try row.int64("expected_remote_head_generation")
    }
}

struct RestoreExpectedHeadRow: SQLiteRowDecodable {
    static let columns = """
    expected_remote_head_snapshot_id,expected_remote_head_generation
    """
    let expectedRemoteHeadSnapshotID: Data?
    let expectedRemoteHeadGeneration: Int64?

    init(_ row: SQLiteRow) throws {
        expectedRemoteHeadSnapshotID = try row.blob("expected_remote_head_snapshot_id")
        expectedRemoteHeadGeneration = try row.int64("expected_remote_head_generation")
    }
}

struct RestoreIdentityRow: SQLiteRowDecodable {
    static let columns = """
    restore_id,intent_id,command_id
    """
    let restoreID: String?
    let intentID: String?
    let commandID: String?

    init(_ row: SQLiteRow) throws {
        restoreID = try row.text("restore_id")
        intentID = try row.text("intent_id")
        commandID = try row.text("command_id")
    }
}

struct PreparedRestoreRow: SQLiteRowDecodable {
    static let columns = """
    r.restore_id,r.result_snapshot_id,r.intent_id,i.source_generation,r.expected_remote_head_snapshot_id,
    r.expected_remote_head_generation
    """
    let restoreID: String?
    let resultSnapshotID: Data?
    let intentID: String?
    let sourceGeneration: Int64?
    let expectedRemoteHeadSnapshotID: Data?
    let expectedRemoteHeadGeneration: Int64?

    init(_ row: SQLiteRow) throws {
        restoreID = try row.text("restore_id")
        resultSnapshotID = try row.blob("result_snapshot_id")
        intentID = try row.text("intent_id")
        sourceGeneration = try row.int64("source_generation")
        expectedRemoteHeadSnapshotID = try row.blob("expected_remote_head_snapshot_id")
        expectedRemoteHeadGeneration = try row.int64("expected_remote_head_generation")
    }
}

import Foundation

struct ConflictCandidateRow: SQLiteRowDecodable {
    static let columns = """
    c.conflict_id,c.current_revision,k.base_snapshot_id,k.local_snapshot_id,k.remote_snapshot_id,
    k.source_generation,k.remote_inbox_id
    """
    let conflictID: String?
    let currentRevision: Int64?
    let baseSnapshotID: Data?
    let localSnapshotID: Data?
    let remoteSnapshotID: Data?
    let sourceGeneration: Int64?
    let remoteInboxID: String?

    init(_ row: SQLiteRow) throws {
        conflictID = try row.text("conflict_id")
        currentRevision = try row.int64("current_revision")
        baseSnapshotID = try row.blob("base_snapshot_id")
        localSnapshotID = try row.blob("local_snapshot_id")
        remoteSnapshotID = try row.blob("remote_snapshot_id")
        sourceGeneration = try row.int64("source_generation")
        remoteInboxID = try row.text("remote_inbox_id")
    }
}

struct KeepBothReservationRow: SQLiteRowDecodable {
    static let columns = """
    reservation_id,new_document_id,new_root_snapshot_id,source_generation,expected_original_head_snapshot_id,
    expected_original_head_generation,state
    """
    let reservationID: String?
    let newDocumentID: String?
    let newRootSnapshotID: Data?
    let sourceGeneration: Int64?
    let expectedOriginalHeadSnapshotID: Data?
    let expectedOriginalHeadGeneration: Int64?
    let state: String?

    init(_ row: SQLiteRow) throws {
        reservationID = try row.text("reservation_id")
        newDocumentID = try row.text("new_document_id")
        newRootSnapshotID = try row.blob("new_root_snapshot_id")
        sourceGeneration = try row.int64("source_generation")
        expectedOriginalHeadSnapshotID = try row.blob("expected_original_head_snapshot_id")
        expectedOriginalHeadGeneration = try row.int64("expected_original_head_generation")
        state = try row.text("state")
    }
}

struct KeepBothFinalizationRow: SQLiteRowDecodable {
    static let columns = """
    conflict_id,conflict_revision,source_generation,remote_snapshot_id,new_work_id,new_root_snapshot_id,
    expected_original_head_snapshot_id,expected_original_head_generation,state
    """
    let conflictID: String?
    let conflictRevision: Int64?
    let sourceGeneration: Int64?
    let remoteSnapshotID: Data?
    let newWorkID: String?
    let newRootSnapshotID: Data?
    let expectedOriginalHeadSnapshotID: Data?
    let expectedOriginalHeadGeneration: Int64?
    let state: String?

    init(_ row: SQLiteRow) throws {
        conflictID = try row.text("conflict_id")
        conflictRevision = try row.int64("conflict_revision")
        sourceGeneration = try row.int64("source_generation")
        remoteSnapshotID = try row.blob("remote_snapshot_id")
        newWorkID = try row.text("new_work_id")
        newRootSnapshotID = try row.blob("new_root_snapshot_id")
        expectedOriginalHeadSnapshotID = try row.blob("expected_original_head_snapshot_id")
        expectedOriginalHeadGeneration = try row.int64("expected_original_head_generation")
        state = try row.text("state")
    }
}

struct ReservationExpectedHeadRow: SQLiteRowDecodable {
    static let columns = """
    expected_original_head_snapshot_id,expected_original_head_generation
    """
    let expectedOriginalHeadSnapshotID: Data?
    let expectedOriginalHeadGeneration: Int64?

    init(_ row: SQLiteRow) throws {
        expectedOriginalHeadSnapshotID = try row.blob("expected_original_head_snapshot_id")
        expectedOriginalHeadGeneration = try row.int64("expected_original_head_generation")
    }
}

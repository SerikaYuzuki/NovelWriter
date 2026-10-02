import Foundation

struct MigrationLedgerRow: SQLiteRowDecodable {
    static let columns = """
    migration_id,account_id,source_kind,source_digest,export_backup_marker,adoption_marker,
    quarantined_from_state,evidence_bytes,state
    """
    let migrationID: String?
    let accountID: String?
    let sourceKind: String?
    let sourceDigest: Data?
    let exportBackupMarker: String?
    let adoptionMarker: String?
    let quarantinedFromState: String?
    let evidenceBytes: Data?
    let state: String?

    init(_ row: SQLiteRow) throws {
        migrationID = try row.text("migration_id")
        accountID = try row.text("account_id")
        sourceKind = try row.text("source_kind")
        sourceDigest = try row.blob("source_digest")
        exportBackupMarker = try row.text("export_backup_marker")
        adoptionMarker = try row.text("adoption_marker")
        quarantinedFromState = try row.text("quarantined_from_state")
        evidenceBytes = try row.blob("evidence_bytes")
        state = try row.text("state")
    }
}

struct MigrationStagingRow: SQLiteRowDecodable {
    static let columns = """
    proposed_work_id,proposed_document_id,snapshot_id,manifest_bytes,state
    """
    let proposedWorkID: String?
    let proposedDocumentID: String?
    let snapshotID: Data?
    let manifestBytes: Data?
    let state: String?

    init(_ row: SQLiteRow) throws {
        proposedWorkID = try row.text("proposed_work_id")
        proposedDocumentID = try row.text("proposed_document_id")
        snapshotID = try row.blob("snapshot_id")
        manifestBytes = try row.blob("manifest_bytes")
        state = try row.text("state")
    }
}

struct MigrationVerificationRow: SQLiteRowDecodable {
    static let columns = """
    state,verified_account_id
    """
    let state: String?
    let verifiedAccountID: String?

    init(_ row: SQLiteRow) throws {
        state = try row.text("state")
        verifiedAccountID = try row.text("verified_account_id")
    }
}

struct MigrationCommitRow: SQLiteRowDecodable {
    static let columns = """
    proposed_work_id,proposed_document_id,snapshot_id,manifest_bytes,state,verified_account_id
    """
    let proposedWorkID: String?
    let proposedDocumentID: String?
    let snapshotID: Data?
    let manifestBytes: Data?
    let state: String?
    let verifiedAccountID: String?

    let columnCount: Int

    init(_ row: SQLiteRow) throws {
        columnCount = row.count
        proposedWorkID = try row.text("proposed_work_id")
        proposedDocumentID = try row.text("proposed_document_id")
        snapshotID = try row.blob("snapshot_id")
        manifestBytes = try row.blob("manifest_bytes")
        state = try row.text("state")
        verifiedAccountID = try row.text("verified_account_id")
    }
}

struct MigrationWorkRow: SQLiteRowDecodable {
    static let columns = """
    document_id,current_snapshot_id,local_generation
    """
    let documentID: String?
    let currentSnapshotID: Data?
    let localGeneration: Int64?

    let columnCount: Int

    init(_ row: SQLiteRow) throws {
        columnCount = row.count
        documentID = try row.text("document_id")
        currentSnapshotID = try row.blob("current_snapshot_id")
        localGeneration = try row.int64("local_generation")
    }
}

import CSQLite
import Foundation
@testable import NovelSyncV2Store
import Testing

struct SQLiteRowDecodingTests {
    @Test func workProjectionIgnoresColumnOrderAndExtraColumns() throws {
        let row = try WorkRow(readRow("""
        SELECT 'normal' AS sync_lane, X'010203' AS current_snapshot_id,
               'created' AS document_created_at, 99 AS unrelated,
               'document' AS document_id, NULL AS acknowledged_head_generation,
               17 AS local_generation, 'work' AS work_id
        """))
        #expect(row.workID == "work")
        #expect(row.documentID == "document")
        #expect(row.localGeneration == 17)
        #expect(row.currentSnapshotID == Data([1, 2, 3]))
        #expect(row.acknowledgedHeadGeneration == nil)
        #expect(row.documentCreatedAt == "created")
        #expect(row.syncLane == "normal")
    }

    @Test func inboxReplayProjectionPreservesEveryAttestationField() throws {
        let row = try InboxReplayBatchRow(readRow("""
        SELECT X'04' AS manifest_bytes, 'verified' AS state,
               23 AS expected_remote_head_generation, X'03' AS expected_remote_head_snapshot_id,
               19 AS expected_local_generation, X'02' AS expected_current_snapshot_id,
               X'01' AS snapshot_id, 'fence' AS account_fence, 'account' AS account_id,
               7 AS protocol_epoch, 'server' AS server_instance_id,
               'created' AS document_created_at, 'document' AS document_id, 'work' AS work_id
        """))
        #expect(row.workID == "work")
        #expect(row.documentID == "document")
        #expect(row.documentCreatedAt == "created")
        #expect(row.serverInstanceID == "server")
        #expect(row.protocolEpoch == 7)
        #expect(row.accountID == "account")
        #expect(row.accountFence == "fence")
        #expect(row.snapshotID == Data([1]))
        #expect(row.expectedCurrentSnapshotID == Data([2]))
        #expect(row.expectedLocalGeneration == 19)
        #expect(row.expectedRemoteHeadSnapshotID == Data([3]))
        #expect(row.expectedRemoteHeadGeneration == 23)
        #expect(row.state == "verified")
        #expect(row.manifestBytes == Data([4]))
    }

    @Test func missingColumnIsNotTreatedAsSQLNull() throws {
        let row = try readRow("SELECT 'schema' AS value")
        #expect(throws: SyncV2StoreError.sqlite("missing or ambiguous column: checksum")) {
            try SchemaMarkerRow(row)
        }
        let nullable = try SchemaMarkerRow(readRow("SELECT NULL AS checksum, 'schema' AS value"))
        #expect(nullable.checksum == nil)
    }

    @Test func duplicateColumnNameFailsClosed() throws {
        let row = try readRow("SELECT 'first' AS value, 'second' AS value, X'01' AS checksum")
        #expect(throws: SyncV2StoreError.sqlite("missing or ambiguous column: value")) {
            try SchemaMarkerRow(row)
        }
    }

    @Test func incompatibleStorageTypesThrowStoreErrors() throws {
        let text = try readRow("SELECT 1 AS value, X'01' AS checksum")
        #expect(throws: SyncV2StoreError.sqlite("invalid text column: value")) {
            try SchemaMarkerRow(text)
        }
        let blob = try readRow("SELECT 'schema' AS value, 'not bytes' AS checksum")
        #expect(throws: SyncV2StoreError.sqlite("invalid blob column: checksum")) {
            try SchemaMarkerRow(blob)
        }
        let integer = try readRow("SELECT X'01' AS current_snapshot_id, '17' AS local_generation")
        #expect(throws: SyncV2StoreError.sqlite("invalid integer column: local_generation")) {
            try WorkCurrentRow(integer)
        }
    }

    @Test func scalarHelperRejectsMultiColumnProjections() throws {
        let single = try readRow("SELECT 42")
        #expect(try single.scalar.int64 == 42)
        let multiple = try readRow("SELECT 42, 43")
        #expect(throws: SyncV2StoreError.sqlite("expected a single scalar column")) {
            try multiple.scalar
        }
    }

    private func readRow(_ sql: String) throws -> SQLiteRow {
        var database: OpaquePointer?
        #expect(sqlite3_open(":memory:", &database) == SQLITE_OK)
        let handle = try #require(database)
        defer { sqlite3_close(handle) }
        var statement: OpaquePointer?
        #expect(sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK)
        let prepared = try #require(statement)
        defer { sqlite3_finalize(prepared) }
        #expect(sqlite3_step(prepared) == SQLITE_ROW)
        return try SQLiteRow(statement: prepared)
    }
}

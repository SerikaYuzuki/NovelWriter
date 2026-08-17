// Schema attestation and its narrow, transactional compatibility migrations
// intentionally remain co-located so every accepted checksum is auditable.
// swiftlint:disable:next blanket_disable_command
// swiftlint:disable type_body_length
import CSQLite
import Foundation
import NovelSyncV2

enum V2StoreSchema {
    static let version = "2"
    private static let legacyRestoreStateChecksum = Data(
        hex: "745d947270838584aa854262fd794c7808316a0aa507966a22e9d33fe9cccf74"
    )
    private static let legacyRetiredRestoreStateChecksum = Data(
        hex: "6b089b87ef6118cbf04e89b3e46295b8b1297463e68cde8e785d44149c76c467"
    )
    private static let legacyCleanTransferStateChecksum = Data(
        hex: "e38615c6acc8bbe4b16d28ec9144bf75c1cbf239024ae06b8cb77a2729ec43fa"
    )
    private static let legacyUnconstrainedTransferStateChecksum = Data(
        hex: "9af3fd4c7a743ccce0810aea444b93fd7df060b4d48a78fc5156555afbe98280"
    )
    private static let legacyUploadTransferTableDDL = [
        "CREATE TABLE upload_transfers (",
        "  transfer_id TEXT PRIMARY KEY,",
        "  command_id TEXT NOT NULL UNIQUE,",
        "  work_id TEXT NOT NULL,",
        "  object_id BLOB NOT NULL,",
        "  source_snapshot_id BLOB NOT NULL,",
        "  source_generation INTEGER NOT NULL,",
        "  upload_id TEXT NOT NULL,",
        "  capability TEXT NOT NULL,",
        "  exact_bytes BLOB NOT NULL,",
        "  bytes_digest BLOB NOT NULL,",
        "  acknowledged_offset INTEGER NOT NULL,",
        "  expires_at TEXT NOT NULL,",
        "  lifecycle TEXT NOT NULL CHECK (lifecycle IN (",
        "    'prepared', 'sending', 'acknowledged', 'quarantined', 'parked'",
        "  )),",
        "  server_instance_id TEXT NOT NULL,",
        "  protocol_epoch INTEGER NOT NULL,",
        "  account_id TEXT NOT NULL,",
        "  account_fence TEXT NOT NULL",
        ");",
        "CREATE INDEX upload_transfers_scope",
        "  ON upload_transfers(server_instance_id, protocol_epoch, account_id, account_fence, work_id);"
    ].joined(separator: "\n")
    private static let legacyRestoreTableDDL = [
        "CREATE TABLE restore_records (",
        "  restore_id TEXT PRIMARY KEY,",
        "  work_id TEXT NOT NULL,",
        "  account_id TEXT,",
        "  selected_snapshot_id BLOB NOT NULL,",
        "  pre_restore_snapshot_id BLOB NOT NULL,",
        "  result_snapshot_id BLOB NOT NULL,",
        "  intent_id TEXT NOT NULL UNIQUE,",
        "  command_id TEXT UNIQUE,",
        "  selected_remote_equivalent_snapshot_id BLOB,",
        "  selected_remote_equivalent_generation INTEGER CHECK (",
        "    selected_remote_equivalent_generation IS NULL OR",
        "    selected_remote_equivalent_generation > 0",
        "  ),",
        "  expected_remote_head_snapshot_id BLOB,",
        "  expected_remote_head_generation INTEGER CHECK (",
        "    expected_remote_head_generation IS NULL OR",
        "    expected_remote_head_generation BETWEEN 1 AND 9007199254740991",
        "  ),",
        "  state TEXT NOT NULL CHECK (state IN ('prepared', 'sealed', 'finalized')),",
        "  FOREIGN KEY (work_id, selected_snapshot_id) REFERENCES snapshots(work_id, snapshot_id),",
        "  FOREIGN KEY (work_id, pre_restore_snapshot_id) REFERENCES snapshots(work_id, snapshot_id),",
        "  FOREIGN KEY (work_id, result_snapshot_id) REFERENCES snapshots(work_id, snapshot_id),",
        "  FOREIGN KEY (intent_id) REFERENCES sync_intents(intent_id),",
        "  FOREIGN KEY (account_id, work_id, command_id)",
        "    REFERENCES sealed_commands(account_id, work_id, command_id),",
        "  CHECK (",
        "    (selected_remote_equivalent_snapshot_id IS NULL) =",
        "    (selected_remote_equivalent_generation IS NULL)",
        "  ),",
        "  CHECK (",
        "    (expected_remote_head_snapshot_id IS NULL) =",
        "    (expected_remote_head_generation IS NULL)",
        "  ),",
        "  CHECK (",
        "    (state = 'prepared' AND command_id IS NULL) OR",
        "    (state IN ('sealed', 'finalized') AND command_id IS NOT NULL)",
        "  )",
        ");"
    ].joined(separator: "\n")
    private static let legacyRetiredRestoreTableDDL = [
        "CREATE TABLE restore_records (",
        "  restore_id TEXT PRIMARY KEY,",
        "  work_id TEXT NOT NULL,",
        "  account_id TEXT,",
        "  selected_snapshot_id BLOB NOT NULL,",
        "  pre_restore_snapshot_id BLOB NOT NULL,",
        "  result_snapshot_id BLOB NOT NULL,",
        "  intent_id TEXT NOT NULL UNIQUE,",
        "  command_id TEXT UNIQUE,",
        "  selected_remote_equivalent_snapshot_id BLOB,",
        "  selected_remote_equivalent_generation INTEGER CHECK (",
        "    selected_remote_equivalent_generation IS NULL OR",
        "    selected_remote_equivalent_generation > 0",
        "  ),",
        "  expected_remote_head_snapshot_id BLOB,",
        "  expected_remote_head_generation INTEGER CHECK (",
        "    expected_remote_head_generation IS NULL OR",
        "    expected_remote_head_generation BETWEEN 1 AND 9007199254740991",
        "  ),",
        "  state TEXT NOT NULL CHECK (state IN ('prepared', 'sealed', 'finalized', 'retired')),",
        "  FOREIGN KEY (work_id, selected_snapshot_id) REFERENCES snapshots(work_id, snapshot_id),",
        "  FOREIGN KEY (work_id, pre_restore_snapshot_id) REFERENCES snapshots(work_id, snapshot_id),",
        "  FOREIGN KEY (work_id, result_snapshot_id) REFERENCES snapshots(work_id, snapshot_id),",
        "  FOREIGN KEY (intent_id) REFERENCES sync_intents(intent_id),",
        "  FOREIGN KEY (account_id, work_id, command_id)",
        "    REFERENCES sealed_commands(account_id, work_id, command_id),",
        "  CHECK (",
        "    (selected_remote_equivalent_snapshot_id IS NULL) =",
        "    (selected_remote_equivalent_generation IS NULL)",
        "  ),",
        "  CHECK (",
        "    (expected_remote_head_snapshot_id IS NULL) =",
        "    (expected_remote_head_generation IS NULL)",
        "  ),",
        "  CHECK (",
        "    (state = 'prepared' AND command_id IS NULL) OR",
        "    (state IN ('sealed', 'finalized') AND command_id IS NOT NULL)",
        "    OR state = 'retired'",
        "  )",
        ");"
    ].joined(separator: "\n")

    static func resourceSQL() throws -> Data {
        guard let url = Bundle.module.url(forResource: "sqlite", withExtension: "sql") else {
            throw SyncV2StoreError.schemaMismatch
        }
        return try Data(contentsOf: url, options: [.mappedIfSafe])
    }

    static func checksum(_ sql: Data) -> Data {
        Data(hex: SHA256Digest.hex(sql))
    }

    static func open(_ db: OpaquePointer, create: Bool) throws {
        let sql = try resourceSQL()
        let expectedChecksum = checksum(sql)
        guard sqlite3_exec(
            db,
            "PRAGMA foreign_keys=ON; PRAGMA synchronous=FULL;",
            nil,
            nil,
            nil
        ) == SQLITE_OK else {
            throw SyncV2StoreError.sqlite(String(cString: sqlite3_errmsg(db)))
        }
        if create {
            guard try schemaObjects(db).isEmpty else {
                throw SyncV2StoreError.schemaMismatch
            }
            guard sqlite3_exec(db, String(decoding: sql, as: UTF8.self), nil, nil, nil) == SQLITE_OK else {
                throw SyncV2StoreError.sqlite(String(cString: sqlite3_errmsg(db)))
            }
            try insertMetadata(db, checksum: expectedChecksum)
        }
        if create {
            try attest(db, expectedSQL: sql, expectedChecksum: expectedChecksum)
            return
        }
        do {
            try attest(db, expectedSQL: sql, expectedChecksum: expectedChecksum)
        } catch {
            let canonicalError = error
            let candidates: [(Data, Data)] = [
                (legacyResourceSQL(from: sql), legacyRestoreStateChecksum),
                (legacyRetiredResourceSQL(from: sql), legacyRetiredRestoreStateChecksum)
            ]
            var migrated = false
            for (legacySQL, legacyChecksum) in candidates {
                guard checksum(legacySQL) == legacyChecksum else { continue }
                do {
                    try attest(
                        db,
                        expectedSQL: legacySQL,
                        expectedChecksum: legacyChecksum,
                        includeTransferJournal: false
                    )
                    try migrateLegacyRestoreState(
                        db,
                        expectedSQL: sql,
                        expectedChecksum: expectedChecksum
                    )
                    migrated = true
                    break
                } catch {
                    continue
                }
            }
            if !migrated {
                let legacyTransferSQL = legacyTransferResourceSQL(from: sql)
                if checksum(legacyTransferSQL) == legacyUnconstrainedTransferStateChecksum {
                    do {
                        try attest(
                            db,
                            expectedSQL: legacyTransferSQL,
                            expectedChecksum: legacyUnconstrainedTransferStateChecksum
                        )
                        try migrateLegacyTransferSchema(
                            db,
                            expectedSQL: sql,
                            expectedChecksum: expectedChecksum
                        )
                        migrated = true
                    } catch {
                        migrated = false
                    }
                }
            }
            if !migrated {
                let legacySQL = withoutTransferJournalSQL(from: sql)
                if checksum(legacySQL) == legacyCleanTransferStateChecksum {
                    do {
                        try attest(
                            db,
                            expectedSQL: legacySQL,
                            expectedChecksum: legacyCleanTransferStateChecksum,
                            includeTransferJournal: false
                        )
                        try migrateLegacyTransferJournal(
                            db,
                            expectedSQL: sql,
                            expectedChecksum: expectedChecksum
                        )
                        migrated = true
                    } catch {
                        migrated = false
                    }
                }
            }
            guard migrated else { throw canonicalError }
        }
        try attest(db, expectedSQL: sql, expectedChecksum: expectedChecksum)
    }

    /// v2 databases created before restore retirement used the same metadata
    /// version but did not allow a closed `retired` state. Keep the exact old
    /// table DDL here so a future canonical edit cannot silently broaden the
    /// accepted legacy schema.
    private static func legacyResourceSQL(from sql: Data) -> Data {
        let current = String(decoding: withoutTransferJournalSQL(from: sql), as: UTF8.self)
        guard let start = current.range(of: "CREATE TABLE restore_records ("),
              let end = current.range(
                  of: "\nCREATE TABLE snapshot_remote_equivalents",
                  range: start.upperBound ..< current.endIndex
              ) else {
            return Data()
        }
        let legacy = String(current[..<start.lowerBound]) +
            legacyRestoreTableDDL +
            String(current[end.lowerBound...])
        return Data(legacy.utf8)
    }

    private static func legacyRetiredResourceSQL(from sql: Data) -> Data {
        let current = String(decoding: withoutTransferJournalSQL(from: sql), as: UTF8.self)
        guard let start = current.range(of: "CREATE TABLE restore_records ("),
              let end = current.range(
                  of: "\nCREATE TABLE snapshot_remote_equivalents",
                  range: start.upperBound ..< current.endIndex
              ) else {
            return Data()
        }
        let legacy = String(current[..<start.lowerBound]) +
            legacyRetiredRestoreTableDDL +
            String(current[end.lowerBound...])
        return Data(legacy.utf8)
    }

    private static func legacyTransferResourceSQL(from sql: Data) -> Data {
        let current = String(decoding: sql, as: UTF8.self)
        guard let start = current.range(of: "CREATE TABLE upload_transfers ("),
              let end = current.range(
                  of: "CREATE TABLE remote_receipts (",
                  range: start.upperBound ..< current.endIndex
              ) else {
            return Data()
        }
        let legacy = String(current[..<start.lowerBound]) +
            legacyUploadTransferTableDDL +
            String(current[end.lowerBound...])
        return Data(legacy.utf8)
    }

    private static func withoutTransferJournalSQL(from sql: Data) -> Data {
        let current = String(decoding: sql, as: UTF8.self)
        guard let start = current.range(of: "CREATE TABLE upload_transfers ("),
              let end = current.range(
                  of: "CREATE TABLE remote_receipts (",
                  range: start.upperBound ..< current.endIndex
              ) else {
            return sql
        }
        return Data(
            (String(current[..<start.lowerBound]) + String(current[end.lowerBound...])).utf8
        )
    }

    /// Upgrade only an attested pre-retirement v2 database. SQLite cannot
    /// alter a CHECK constraint in place, so rebuild the isolated
    /// restore_records table in one transaction and copy every byte-bearing
    /// column before updating the canonical checksum. No local snapshot or
    /// restore audit row is deleted.
    private static func migrateLegacyRestoreState(
        _ db: OpaquePointer,
        expectedSQL: Data,
        expectedChecksum: Data
    ) throws {
        guard sqlite3_exec(db, "BEGIN IMMEDIATE", nil, nil, nil) == SQLITE_OK else {
            throw SyncV2StoreError.sqlite(String(cString: sqlite3_errmsg(db)))
        }
        do {
            try execute(
                db,
                "ALTER TABLE restore_records RENAME TO restore_records_legacy"
            )
            try execute(db, restoreTableDDL(from: expectedSQL))
            try execute(
                db,
                """
                INSERT INTO restore_records(
                  restore_id,work_id,account_id,selected_snapshot_id,
                  pre_restore_snapshot_id,result_snapshot_id,intent_id,command_id,
                  selected_remote_equivalent_snapshot_id,
                  selected_remote_equivalent_generation,
                  expected_remote_head_snapshot_id,expected_remote_head_generation,state
                )
                SELECT restore_id,work_id,account_id,selected_snapshot_id,
                       pre_restore_snapshot_id,result_snapshot_id,intent_id,command_id,
                       selected_remote_equivalent_snapshot_id,
                       selected_remote_equivalent_generation,
                       expected_remote_head_snapshot_id,expected_remote_head_generation,state
                FROM restore_records_legacy
                """
            )
            try execute(db, "DROP TABLE restore_records_legacy")
            try ensureTransferJournal(db)
            try updateMetadata(db, checksum: expectedChecksum)
            try attest(db, expectedSQL: expectedSQL, expectedChecksum: expectedChecksum)
            guard sqlite3_exec(db, "COMMIT", nil, nil, nil) == SQLITE_OK else {
                throw SyncV2StoreError.sqlite(String(cString: sqlite3_errmsg(db)))
            }
        } catch {
            guard sqlite3_exec(db, "ROLLBACK", nil, nil, nil) == SQLITE_OK else {
                throw SyncV2StoreError.sqlite(String(cString: sqlite3_errmsg(db)))
            }
            throw error
        }
    }

    private static func migrateLegacyTransferSchema(
        _ db: OpaquePointer,
        expectedSQL: Data,
        expectedChecksum: Data
    ) throws {
        guard sqlite3_exec(db, "BEGIN IMMEDIATE", nil, nil, nil) == SQLITE_OK else {
            throw SyncV2StoreError.sqlite(String(cString: sqlite3_errmsg(db)))
        }
        do {
            try execute(db, "DROP INDEX IF EXISTS upload_transfers_scope")
            try execute(db, "ALTER TABLE upload_transfers RENAME TO upload_transfers_legacy")
            try execute(db, uploadTransferTableDDL(from: expectedSQL))
            try execute(
                db,
                """
                CREATE INDEX upload_transfers_scope
                  ON upload_transfers(server_instance_id, protocol_epoch, account_id, account_fence, work_id)
                """
            )
            try execute(
                db,
                """
                INSERT INTO upload_transfers(
                  transfer_id,command_id,work_id,object_id,source_snapshot_id,
                  source_generation,upload_id,capability,exact_bytes,bytes_digest,
                  acknowledged_offset,expires_at,lifecycle,server_instance_id,
                  protocol_epoch,account_id,account_fence
                )
                SELECT transfer_id,command_id,work_id,object_id,source_snapshot_id,
                       source_generation,upload_id,capability,exact_bytes,bytes_digest,
                       acknowledged_offset,expires_at,lifecycle,server_instance_id,
                       protocol_epoch,account_id,account_fence
                FROM upload_transfers_legacy
                """
            )
            try execute(db, "DROP TABLE upload_transfers_legacy")
            try updateMetadata(db, checksum: expectedChecksum)
            try attest(db, expectedSQL: expectedSQL, expectedChecksum: expectedChecksum)
            guard sqlite3_exec(db, "COMMIT", nil, nil, nil) == SQLITE_OK else {
                throw SyncV2StoreError.sqlite(String(cString: sqlite3_errmsg(db)))
            }
        } catch {
            guard sqlite3_exec(db, "ROLLBACK", nil, nil, nil) == SQLITE_OK else {
                throw SyncV2StoreError.sqlite(String(cString: sqlite3_errmsg(db)))
            }
            throw error
        }
    }

    private static func migrateLegacyTransferJournal(
        _ db: OpaquePointer,
        expectedSQL: Data,
        expectedChecksum: Data
    ) throws {
        guard sqlite3_exec(db, "BEGIN IMMEDIATE", nil, nil, nil) == SQLITE_OK else {
            throw SyncV2StoreError.sqlite(String(cString: sqlite3_errmsg(db)))
        }
        do {
            try ensureTransferJournal(db)
            try updateMetadata(db, checksum: expectedChecksum)
            try attest(db, expectedSQL: expectedSQL, expectedChecksum: expectedChecksum)
            guard sqlite3_exec(db, "COMMIT", nil, nil, nil) == SQLITE_OK else {
                throw SyncV2StoreError.sqlite(String(cString: sqlite3_errmsg(db)))
            }
        } catch {
            guard sqlite3_exec(db, "ROLLBACK", nil, nil, nil) == SQLITE_OK else {
                throw SyncV2StoreError.sqlite(String(cString: sqlite3_errmsg(db)))
            }
            throw error
        }
    }

    private static func execute(_ db: OpaquePointer, _ sql: String) throws {
        guard sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK else {
            throw SyncV2StoreError.sqlite(String(cString: sqlite3_errmsg(db)))
        }
    }

    private static func restoreTableDDL(from sql: Data) throws -> String {
        let source = String(decoding: sql, as: UTF8.self)
        guard let start = source.range(of: "CREATE TABLE restore_records ("),
              let end = source.range(
                  of: "\nCREATE TABLE snapshot_remote_equivalents",
                  range: start.upperBound ..< source.endIndex
              ) else {
            throw SyncV2StoreError.schemaMismatch
        }
        return String(source[start.lowerBound ..< end.lowerBound])
    }

    private static func uploadTransferTableDDL(from sql: Data) throws -> String {
        let source = String(decoding: sql, as: UTF8.self)
        guard let start = source.range(of: "CREATE TABLE upload_transfers ("),
              let end = source.range(
                  of: "CREATE INDEX upload_transfers_scope",
                  range: start.upperBound ..< source.endIndex
              ) else {
            throw SyncV2StoreError.schemaMismatch
        }
        return String(source[start.lowerBound ..< end.lowerBound])
    }

    private static func updateMetadata(_ db: OpaquePointer, checksum: Data) throws {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(
            db,
            "UPDATE schema_meta SET checksum=? WHERE key='schema'",
            -1,
            &statement,
            nil
        ) == SQLITE_OK else {
            throw SyncV2StoreError.sqlite(String(cString: sqlite3_errmsg(db)))
        }
        defer { sqlite3_finalize(statement) }
        let bind = checksum.withUnsafeBytes {
            sqlite3_bind_blob(
                statement,
                1,
                $0.baseAddress,
                Int32(checksum.count),
                sqliteTransient
            )
        }
        guard bind == SQLITE_OK, sqlite3_step(statement) == SQLITE_DONE else {
            throw SyncV2StoreError.sqlite(String(cString: sqlite3_errmsg(db)))
        }
    }

    /// Kept as an idempotent migration helper for databases created before
    /// upload_transfers became part of the canonical schema. It is called
    /// only after the old metadata and schema signature have been attested.
    private static func ensureTransferJournal(_ db: OpaquePointer) throws {
        let sql = """
        CREATE TABLE IF NOT EXISTS upload_transfers (
          transfer_id TEXT PRIMARY KEY,
          command_id TEXT NOT NULL UNIQUE,
          work_id TEXT NOT NULL,
          object_id BLOB NOT NULL CHECK (length(object_id) = 32),
          source_snapshot_id BLOB NOT NULL CHECK (length(source_snapshot_id) = 32),
          source_generation INTEGER NOT NULL CHECK (source_generation > 0),
          upload_id TEXT NOT NULL,
          capability TEXT NOT NULL,
          exact_bytes BLOB NOT NULL,
          bytes_digest BLOB NOT NULL CHECK (length(bytes_digest) = 32),
          acknowledged_offset INTEGER NOT NULL CHECK (
            acknowledged_offset >= 0 AND acknowledged_offset <= length(exact_bytes)
          ),
          expires_at TEXT NOT NULL,
          lifecycle TEXT NOT NULL CHECK (lifecycle IN (
            'prepared', 'sending', 'acknowledged', 'quarantined', 'parked'
          )),
          server_instance_id TEXT NOT NULL,
          protocol_epoch INTEGER NOT NULL,
          account_id TEXT NOT NULL,
          account_fence TEXT NOT NULL,
          FOREIGN KEY (work_id, source_snapshot_id) REFERENCES snapshots(work_id, snapshot_id),
          FOREIGN KEY (
            work_id, server_instance_id, protocol_epoch, account_id, account_fence
          ) REFERENCES account_bindings(
            work_id, server_instance_id, protocol_epoch, account_id, account_fence
          ),
          FOREIGN KEY (
            server_instance_id, protocol_epoch, account_id, account_fence,
            work_id, command_id, source_snapshot_id, source_generation
          ) REFERENCES sealed_commands(
            server_instance_id, protocol_epoch, account_id, account_fence,
            work_id, command_id, source_snapshot_id, source_generation
          )
        );
        CREATE INDEX IF NOT EXISTS upload_transfers_scope
          ON upload_transfers(server_instance_id, protocol_epoch, account_id, account_fence, work_id);
        """
        guard sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK else {
            throw SyncV2StoreError.sqlite(String(cString: sqlite3_errmsg(db)))
        }
    }

    private static func insertMetadata(_ db: OpaquePointer, checksum: Data) throws {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(
            db,
            "INSERT INTO schema_meta(key,value,checksum) VALUES('schema',?,?)",
            -1,
            &statement,
            nil
        ) == SQLITE_OK else {
            throw SyncV2StoreError.sqlite(String(cString: sqlite3_errmsg(db)))
        }
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_text(statement, 1, version, -1, sqliteTransient)
        let bind = checksum.withUnsafeBytes {
            sqlite3_bind_blob(
                statement,
                2,
                $0.baseAddress,
                Int32(checksum.count),
                sqliteTransient
            )
        }
        guard bind == SQLITE_OK, sqlite3_step(statement) == SQLITE_DONE else {
            throw SyncV2StoreError.sqlite(String(cString: sqlite3_errmsg(db)))
        }
    }

    private static func attest(
        _ db: OpaquePointer,
        expectedSQL: Data,
        expectedChecksum: Data,
        includeTransferJournal: Bool = true
    ) throws {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(
            db,
            "SELECT value,checksum FROM schema_meta WHERE key='schema'",
            -1,
            &statement,
            nil
        ) == SQLITE_OK else { throw SyncV2StoreError.schemaMismatch }
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW,
              String(cString: sqlite3_column_text(statement, 0)) == version,
              Data(
                  bytes: sqlite3_column_blob(statement, 1),
                  count: Int(sqlite3_column_bytes(statement, 1))
              ) == expectedChecksum,
              sqlite3_step(statement) == SQLITE_DONE else {
            throw SyncV2StoreError.schemaMismatch
        }
        let actual = try schemaSignature(db, includeTransferJournal: includeTransferJournal)
        let expected = try schemaSignature(for: expectedSQL, includeTransferJournal: includeTransferJournal)
        guard actual == expected else { throw SyncV2StoreError.schemaMismatch }
    }

    private static func schemaSignature(
        for sql: Data,
        includeTransferJournal: Bool = true
    ) throws -> Data {
        var memory: OpaquePointer?
        guard sqlite3_open_v2(
            ":memory:",
            &memory,
            SQLITE_OPEN_CREATE | SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX,
            nil
        ) == SQLITE_OK,
            let memory else { throw SyncV2StoreError.schemaMismatch }
        defer { sqlite3_close(memory) }
        guard sqlite3_exec(memory, String(decoding: sql, as: UTF8.self), nil, nil, nil) == SQLITE_OK else {
            throw SyncV2StoreError.schemaMismatch
        }
        return try schemaSignature(memory, includeTransferJournal: includeTransferJournal)
    }

    private static func schemaSignature(
        _ db: OpaquePointer,
        includeTransferJournal: Bool = true
    ) throws -> Data {
        let objects = try schemaObjects(db, includeTransferJournal: includeTransferJournal)
        var bytes = Data()
        for object in objects {
            for field in object {
                bytes.append(contentsOf: field.utf8)
                bytes.append(0)
            }
        }
        return Data(hex: SHA256Digest.hex(bytes))
    }

    private static func schemaObjects(
        _ db: OpaquePointer,
        includeTransferJournal: Bool = true
    ) throws -> [[String]] {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(
            db,
            """
            SELECT type,name,tbl_name,COALESCE(sql,'') FROM sqlite_schema
            WHERE type IN ('table','index','trigger','view') ORDER BY type,name
            """,
            -1,
            &statement,
            nil
        ) == SQLITE_OK else { throw SyncV2StoreError.schemaMismatch }
        defer { sqlite3_finalize(statement) }
        var objects: [[String]] = []
        var result = sqlite3_step(statement)
        while result == SQLITE_ROW {
            let objectName = sqlite3_column_text(statement, 1).map { String(cString: $0) } ?? ""
            let tableName = sqlite3_column_text(statement, 2).map { String(cString: $0) } ?? ""
            guard includeTransferJournal ||
                (!objectName.hasPrefix("upload_transfers") && !tableName.hasPrefix("upload_transfers")) else {
                result = sqlite3_step(statement)
                continue
            }
            objects.append((0 ..< 4).map { index in
                sqlite3_column_text(statement, Int32(index)).map {
                    String(cString: $0)
                } ?? ""
            })
            result = sqlite3_step(statement)
        }
        guard result == SQLITE_DONE else { throw SyncV2StoreError.schemaMismatch }
        return objects
    }
}

public enum SnapshotSyncV2SchemaContract {
    public static let version = V2StoreSchema.version

    public static func resourceSQL() throws -> Data {
        try V2StoreSchema.resourceSQL()
    }

    public static func checksum(_ sql: Data) -> Data {
        V2StoreSchema.checksum(sql)
    }
}

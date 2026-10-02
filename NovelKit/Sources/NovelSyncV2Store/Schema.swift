// Schema attestation and its narrow, transactional compatibility migrations
// intentionally remain co-located so every accepted checksum is auditable.
// swiftlint:disable:next blanket_disable_command
// swiftlint:disable type_body_length
import Foundation
import NovelSyncV2

enum V2StoreSchema {
    static let version = "2"
    private static let legacyRestoreStateChecksum = Data(
        hex: "745d947270838584aa854262fd794c7808316a0aa507966a22e9d33fe9cccf74"
    )!
    private static let legacyRetiredRestoreStateChecksum = Data(
        hex: "6b089b87ef6118cbf04e89b3e46295b8b1297463e68cde8e785d44149c76c467"
    )!
    private static let legacyCleanTransferStateChecksum = Data(
        hex: "e38615c6acc8bbe4b16d28ec9144bf75c1cbf239024ae06b8cb77a2729ec43fa"
    )!
    private static let legacyUnconstrainedTransferStateChecksum = Data(
        hex: "9af3fd4c7a743ccce0810aea444b93fd7df060b4d48a78fc5156555afbe98280"
    )!
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
        Data(hex: SHA256Digest.hex(sql))!
    }

    static func open(_ database: OpaquePointer, create: Bool) throws {
        let sql = try resourceSQL()
        if create {
            return try openBase(database, create: true, sql: sql)
        }
        try execute(database, "PRAGMA foreign_keys=ON; PRAGMA synchronous=FULL;")
        if (try? attest(database, expectedSQL: sql, expectedChecksum: checksum(sql))) != nil {
            return
        }
        let source = String(decoding: sql, as: UTF8.self)
        let markers = [
            "\n-- Work deletion journal.", "\n-- Shallow history (D-106).",
            "\n-- Legacy unexpected-command recovery (D-107).", "\n-- Receipt equivalence repair (D-108)."
        ]
        let boundaries = try markers.map { marker in
            guard let range = source.range(of: marker) else { throw SyncV2StoreError.schemaMismatch }
            return range.lowerBound
        }
        let versions = boundaries.map { Data(source[..<$0].utf8) } + [sql]
        // Legacy migrations apply only to the original base. Each additive
        // version is independently attested, including its exact checksum.
        if !(versions.contains { (try? attest(database, expectedSQL: $0, expectedChecksum: checksum($0))) != nil }) {
            do {
                try openBase(database, create: false, sql: versions[0])
            } catch {
                // Another opener may have completed both legacy and tail steps.
                try attest(database, expectedSQL: sql, expectedChecksum: checksum(sql))
                return
            }
        }
        try execute(database, "BEGIN IMMEDIATE")
        do {
            guard let current = versions.lastIndex(where: {
                (try? attest(database, expectedSQL: $0, expectedChecksum: checksum($0))) != nil
            }) else { throw SyncV2StoreError.schemaMismatch }
            for index in current ..< boundaries.count {
                try attest(database, expectedSQL: versions[index], expectedChecksum: checksum(versions[index]))
                let end = index + 1 < boundaries.count ? boundaries[index + 1] : source.endIndex
                try execute(database, String(source[boundaries[index] ..< end]))
                try updateMetadata(database, checksum: checksum(versions[index + 1]))
                try attest(database, expectedSQL: versions[index + 1], expectedChecksum: checksum(versions[index + 1]))
            }
            try execute(database, "COMMIT")
        } catch {
            try execute(database, "ROLLBACK")
            throw error
        }
    }

    private static func openBase(_ database: OpaquePointer, create: Bool, sql: Data) throws {
        let expectedChecksum = checksum(sql)
        try execute(database, "PRAGMA foreign_keys=ON; PRAGMA synchronous=FULL;")
        if create {
            guard try schemaObjects(database).isEmpty else {
                throw SyncV2StoreError.schemaMismatch
            }
            try execute(database, String(decoding: sql, as: UTF8.self))
            try insertMetadata(database, checksum: expectedChecksum)
        }
        if create {
            try attest(database, expectedSQL: sql, expectedChecksum: expectedChecksum)
            return
        }
        do {
            try attest(database, expectedSQL: sql, expectedChecksum: expectedChecksum)
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
                        database,
                        expectedSQL: legacySQL,
                        expectedChecksum: legacyChecksum,
                        includeTransferJournal: false
                    )
                    try migrateLegacyRestoreState(
                        database,
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
                            database,
                            expectedSQL: legacyTransferSQL,
                            expectedChecksum: legacyUnconstrainedTransferStateChecksum
                        )
                        try migrateLegacyTransferSchema(
                            database,
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
                            database,
                            expectedSQL: legacySQL,
                            expectedChecksum: legacyCleanTransferStateChecksum,
                            includeTransferJournal: false
                        )
                        try migrateLegacyTransferJournal(
                            database,
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
        try attest(database, expectedSQL: sql, expectedChecksum: expectedChecksum)
    }

    /// v2 databases created before restore retirement used the same metadata
    /// version but did not allow a closed `retired` state. Keep the exact old
    /// table DDL here so a future canonical edit cannot silently broaden the
    /// accepted legacy schema.
    static func legacyResourceSQL(from sql: Data) -> Data {
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

    static func legacyTransferResourceSQL(from sql: Data) -> Data {
        let current = String(decoding: sql, as: UTF8.self)
        guard let start = current.range(of: "CREATE TABLE upload_transfers ("),
              let end = current.range(
                  of: "CREATE TABLE remote_receipts (",
                  range: start.upperBound ..< current.endIndex
              ) else {
            return Data()
        }
        let legacy = String(current[..<start.lowerBound]) +
            legacyUploadTransferTableDDL + "\n" +
            String(current[end.lowerBound...])
        return Data(legacy.utf8)
    }

    static func withoutTransferJournalSQL(from sql: Data) -> Data {
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
        _ database: OpaquePointer,
        expectedSQL: Data,
        expectedChecksum: Data
    ) throws {
        try execute(database, "BEGIN IMMEDIATE")
        do {
            try execute(
                database,
                "ALTER TABLE restore_records RENAME TO restore_records_legacy"
            )
            try execute(database, restoreTableDDL(from: expectedSQL))
            try execute(
                database,
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
            try execute(database, "DROP TABLE restore_records_legacy")
            try ensureTransferJournal(database, expectedSQL: expectedSQL)
            try updateMetadata(database, checksum: expectedChecksum)
            try attest(database, expectedSQL: expectedSQL, expectedChecksum: expectedChecksum)
            try execute(database, "COMMIT")
        } catch {
            try execute(database, "ROLLBACK")
            throw error
        }
    }

    private static func migrateLegacyTransferSchema(
        _ database: OpaquePointer,
        expectedSQL: Data,
        expectedChecksum: Data
    ) throws {
        try execute(database, "BEGIN IMMEDIATE")
        do {
            try execute(database, "DROP INDEX IF EXISTS upload_transfers_scope")
            try execute(database, "ALTER TABLE upload_transfers RENAME TO upload_transfers_legacy")
            try execute(database, uploadTransferTableDDL(from: expectedSQL))
            try execute(
                database,
                """
                CREATE INDEX upload_transfers_scope
                  ON upload_transfers(server_instance_id, protocol_epoch, account_id, account_fence, work_id)
                """
            )
            try execute(
                database,
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
            try execute(database, "DROP TABLE upload_transfers_legacy")
            try updateMetadata(database, checksum: expectedChecksum)
            try attest(database, expectedSQL: expectedSQL, expectedChecksum: expectedChecksum)
            try execute(database, "COMMIT")
        } catch {
            try execute(database, "ROLLBACK")
            throw error
        }
    }

    private static func migrateLegacyTransferJournal(
        _ database: OpaquePointer,
        expectedSQL: Data,
        expectedChecksum: Data
    ) throws {
        try execute(database, "BEGIN IMMEDIATE")
        do {
            try ensureTransferJournal(database, expectedSQL: expectedSQL)
            try updateMetadata(database, checksum: expectedChecksum)
            try attest(database, expectedSQL: expectedSQL, expectedChecksum: expectedChecksum)
            try execute(database, "COMMIT")
        } catch {
            try execute(database, "ROLLBACK")
            throw error
        }
    }

    private static func execute(_ database: OpaquePointer, _ sql: String) throws {
        try SQLiteExecutor.execute(database, sql)
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

    private static func updateMetadata(_ database: OpaquePointer, checksum: Data) throws {
        try SQLiteExecutor.updateMetadata(database, checksum: checksum)
    }

    /// Kept as an idempotent migration helper for databases created before
    /// upload_transfers became part of the canonical schema. It is called
    /// only after the old metadata and schema signature have been attested.
    private static func ensureTransferJournal(_ database: OpaquePointer, expectedSQL: Data) throws {
        // Use the attested canonical DDL, including whitespace: schema signatures
        // compare sqlite_schema SQL exactly, not merely equivalent constraints.
        let table = try uploadTransferTableDDL(from: expectedSQL).replacingOccurrences(
            of: "CREATE TABLE upload_transfers", with: "CREATE TABLE IF NOT EXISTS upload_transfers"
        )
        try execute(database, table)
        try execute(database, """
        CREATE INDEX IF NOT EXISTS upload_transfers_scope
          ON upload_transfers(server_instance_id, protocol_epoch, account_id, account_fence, work_id)
        """)
    }

    private static func insertMetadata(_ database: OpaquePointer, checksum: Data) throws {
        try SQLiteExecutor.insertMetadata(database, checksum: checksum)
    }

    private static func attest(
        _ database: OpaquePointer,
        expectedSQL: Data,
        expectedChecksum: Data,
        includeTransferJournal: Bool = true
    ) throws {
        try SQLiteExecutor.attest(
            database,
            expectedSQL: expectedSQL,
            expectedChecksum: expectedChecksum,
            includeTransferJournal: includeTransferJournal
        )
    }

    private static func schemaSignature(
        for sql: Data,
        includeTransferJournal: Bool = true
    ) throws -> Data {
        try SQLiteExecutor.schemaSignature(for: sql, includeTransferJournal: includeTransferJournal)
    }

    private static func schemaSignature(
        _ database: OpaquePointer,
        includeTransferJournal: Bool = true
    ) throws -> Data {
        try SQLiteExecutor.schemaSignature(database, includeTransferJournal: includeTransferJournal)
    }

    private static func schemaObjects(
        _ database: OpaquePointer,
        includeTransferJournal: Bool = true
    ) throws -> [[String]] {
        try SQLiteExecutor.schemaObjects(database, includeTransferJournal: includeTransferJournal)
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

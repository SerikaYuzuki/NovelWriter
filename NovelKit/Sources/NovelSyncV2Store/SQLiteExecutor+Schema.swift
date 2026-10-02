import CSQLite
import Foundation
import NovelSyncV2

/// Raw, uncached SQLite access for schema attestation. Migration policy and SQL
/// ordering remain in Schema.swift; these helpers preserve its stepping/error rules.
extension SQLiteExecutor {
    static func execute(_ database: OpaquePointer, _ sql: String) throws {
        guard sqlite3_exec(database, sql, nil, nil, nil) == SQLITE_OK else {
            throw SyncV2StoreError.sqlite(String(cString: sqlite3_errmsg(database)))
        }
    }

    static func updateMetadata(_ database: OpaquePointer, checksum: Data) throws {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(
            database,
            "UPDATE schema_meta SET checksum=? WHERE key='schema'",
            -1,
            &statement,
            nil
        ) == SQLITE_OK else {
            throw SyncV2StoreError.sqlite(String(cString: sqlite3_errmsg(database)))
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
            throw SyncV2StoreError.sqlite(String(cString: sqlite3_errmsg(database)))
        }
    }

    static func insertMetadata(_ database: OpaquePointer, checksum: Data) throws {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(
            database,
            "INSERT INTO schema_meta(key,value,checksum) VALUES('schema',?,?)",
            -1,
            &statement,
            nil
        ) == SQLITE_OK else {
            throw SyncV2StoreError.sqlite(String(cString: sqlite3_errmsg(database)))
        }
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_text(statement, 1, V2StoreSchema.version, -1, sqliteTransient)
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
            throw SyncV2StoreError.sqlite(String(cString: sqlite3_errmsg(database)))
        }
    }

    static func attest(
        _ database: OpaquePointer,
        expectedSQL: Data,
        expectedChecksum: Data,
        includeTransferJournal: Bool = true
    ) throws {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(
            database,
            "SELECT value,checksum FROM schema_meta WHERE key='schema'",
            -1,
            &statement,
            nil
        ) == SQLITE_OK else { throw SyncV2StoreError.schemaMismatch }
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW,
              String(cString: sqlite3_column_text(statement, 0)) == V2StoreSchema.version,
              Data(
                  bytes: sqlite3_column_blob(statement, 1),
                  count: Int(sqlite3_column_bytes(statement, 1))
              ) == expectedChecksum,
              sqlite3_step(statement) == SQLITE_DONE else {
            throw SyncV2StoreError.schemaMismatch
        }
        let actual = try schemaSignature(database, includeTransferJournal: includeTransferJournal)
        let expected = try schemaSignature(for: expectedSQL, includeTransferJournal: includeTransferJournal)
        guard actual == expected else { throw SyncV2StoreError.schemaMismatch }
    }

    static func schemaSignature(
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

    static func schemaSignature(
        _ database: OpaquePointer,
        includeTransferJournal: Bool = true
    ) throws -> Data {
        let objects = try schemaObjects(database, includeTransferJournal: includeTransferJournal)
        var bytes = Data()
        for object in objects {
            for field in object {
                bytes.append(contentsOf: field.utf8)
                bytes.append(0)
            }
        }
        return Data(hex: SHA256Digest.hex(bytes))!
    }

    static func schemaObjects(
        _ database: OpaquePointer,
        includeTransferJournal: Bool = true
    ) throws -> [[String]] {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(
            database,
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

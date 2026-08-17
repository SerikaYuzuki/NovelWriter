import CSQLite
import Foundation
import NovelSyncV2

enum V2StoreSchema {
    static let version = "2"

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
        try attest(db, expectedSQL: sql, expectedChecksum: expectedChecksum)
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
        expectedChecksum: Data
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
        let actual = try schemaSignature(db)
        let expected = try schemaSignature(for: expectedSQL)
        guard actual == expected else { throw SyncV2StoreError.schemaMismatch }
    }

    private static func schemaSignature(for sql: Data) throws -> Data {
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
        return try schemaSignature(memory)
    }

    private static func schemaSignature(_ db: OpaquePointer) throws -> Data {
        let objects = try schemaObjects(db)
        var bytes = Data()
        for object in objects {
            for field in object {
                bytes.append(contentsOf: field.utf8)
                bytes.append(0)
            }
        }
        return Data(hex: SHA256Digest.hex(bytes))
    }

    private static func schemaObjects(_ db: OpaquePointer) throws -> [[String]] {
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

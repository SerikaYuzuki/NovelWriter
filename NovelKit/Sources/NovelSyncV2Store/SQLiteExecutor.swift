import CSQLite
import Foundation
import NovelCore
import NovelSyncV2

/// Confined to LocalSyncV2Store. Repositories borrow this one executor synchronously;
/// it is deliberately not Sendable and must never cross the owning actor boundary.
final class SQLiteExecutor {
    private(set) var connection: OpaquePointer?
    private var statements: [String: OpaquePointer] = [:]
    var registeredAncestorCache: WorkRepository.RegisteredAncestorCache?
    var transactionObjects: Set<ObjectID>?
    var snapshotInsertionObserver: (@Sendable (String, Duration) -> Void)?

    init(databaseURL: URL, policy: V2StoreOpenPolicy) throws {
        var handle: OpaquePointer?
        var flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX
        if policy == .createNew {
            flags |= SQLITE_OPEN_CREATE
        }
        let result = sqlite3_open_v2(databaseURL.path, &handle, flags, nil)
        guard result == SQLITE_OK, let handle else {
            throw SyncV2StoreError.sqlite("open \(result)")
        }
        connection = handle
        sqlite3_busy_timeout(handle, 5000)
        do {
            try V2StoreSchema.open(handle, create: policy == .createNew)
        } catch {
            sqlite3_close(handle)
            connection = nil
            throw error
        }
    }

    func close() {
        if let connection {
            for statement in statements.values {
                sqlite3_finalize(statement)
            }
            statements.removeAll()
            sqlite3_close(connection)
            self.connection = nil
        }
    }

    func inTransaction<T>(_ body: () throws -> T) throws -> T {
        try exec("BEGIN IMMEDIATE")
        transactionObjects = []
        defer { transactionObjects = nil }
        do {
            let result = try body()
            try exec("COMMIT")
            return result
        } catch {
            // A failed rollback is itself a fail-closed store error; never
            // hide it while reporting a transition/checkpoint as if the
            // transaction had been safely undone.
            try exec("ROLLBACK")
            throw error
        }
    }

    func changes() throws -> Int {
        guard let connection else { throw SyncV2StoreError.sqlite("closed") }
        return Int(sqlite3_changes(connection))
    }

    private func preparedStatement(_ sql: String) throws -> OpaquePointer {
        guard let connection else { throw SyncV2StoreError.sqlite("closed") }
        if let statement = statements[sql] {
            return statement
        }
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(connection, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
            throw sqliteError()
        }
        statements[sql] = statement
        return statement
    }

    func exec(_ sql: String, _ bindings: [SQLiteValue] = []) throws {
        let statement: OpaquePointer? = try preparedStatement(sql)
        defer {
            sqlite3_reset(statement)
            sqlite3_clear_bindings(statement)
        }
        try bind(statement, bindings)
        guard sqlite3_step(statement) == SQLITE_DONE else { throw sqliteError() }
    }

    func query(_ sql: String, _ bindings: [SQLiteValue] = []) throws -> [SQLiteRow] {
        let statement: OpaquePointer? = try preparedStatement(sql)
        defer {
            sqlite3_reset(statement)
            sqlite3_clear_bindings(statement)
        }
        try bind(statement, bindings)
        var rows: [SQLiteRow] = []
        var result = sqlite3_step(statement)
        while result == SQLITE_ROW {
            guard let statement else {
                throw SyncV2StoreError.sqlite("query statement unavailable")
            }
            try rows.append(Self.readRow(statement))
            result = sqlite3_step(statement)
        }
        guard result == SQLITE_DONE else { throw sqliteError() }
        return rows
    }

    func bind(_ statement: OpaquePointer?, _ values: [SQLiteValue]) throws {
        for (offset, value) in values.enumerated() {
            let index = Int32(offset + 1)
            let result: Int32 = switch value {
            case .null:
                sqlite3_bind_null(statement, index)
            case let .text(text):
                sqlite3_bind_text(statement, index, text, -1, Self.sqliteTransient)
            case let .blob(data):
                data.withUnsafeBytes {
                    sqlite3_bind_blob(
                        statement,
                        index,
                        $0.baseAddress,
                        Int32(data.count),
                        Self.sqliteTransient
                    )
                }
            case let .int(number):
                sqlite3_bind_int64(statement, index, number)
            }
            guard result == SQLITE_OK else { throw sqliteError() }
        }
    }

    func sqliteError() -> SyncV2StoreError {
        guard let connection else { return .sqlite("closed") }
        return .sqlite(String(cString: sqlite3_errmsg(connection)))
    }
}

extension SQLiteExecutor {
    private static func readValue(statement: OpaquePointer, index: Int32) throws -> SQLiteValue {
        switch sqlite3_column_type(statement, index) {
        case SQLITE_NULL:
            return .null
        case SQLITE_INTEGER:
            return .int(sqlite3_column_int64(statement, index))
        case SQLITE_BLOB:
            let count = Int(sqlite3_column_bytes(statement, index))
            guard count >= 0 else {
                throw SyncV2StoreError.sqlite("negative blob length")
            }
            guard count > 0 else {
                return .blob(Data())
            }
            guard let bytes = sqlite3_column_blob(statement, index) else {
                throw SyncV2StoreError.sqlite("blob bytes unavailable")
            }
            return .blob(Data(bytes: bytes, count: count))
        default:
            guard let text = sqlite3_column_text(statement, index) else {
                throw SyncV2StoreError.sqlite("text bytes unavailable")
            }
            return .text(String(cString: text))
        }
    }
}

extension SQLiteExecutor {
    static func readRow(_ statement: OpaquePointer) throws -> SQLiteRow {
        let names = (0 ..< sqlite3_column_count(statement)).map {
            String(cString: sqlite3_column_name(statement, $0))
        }
        let values = try (0 ..< sqlite3_column_count(statement)).map {
            try readValue(statement: statement, index: $0)
        }
        return SQLiteRow(names: names, values: values)
    }
}

extension SQLiteExecutor {
    static let sqliteTransient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
}

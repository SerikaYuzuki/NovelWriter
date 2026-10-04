import CSQLite
import Foundation
import Testing

/// 合成作品の隔離SQLiteをread-onlyで確認する。AIのEdit journalを作らないことを検証。
func workSearchJournalCount(root: URL) throws -> Int {
    var database: OpaquePointer?
    let status = sqlite3_open_v2(
        root.appendingPathComponent("writing-assistant.sqlite").path,
        &database,
        SQLITE_OPEN_READONLY,
        nil
    )
    defer {
        if let database {
            sqlite3_close(database)
        }
    }
    #expect(status == SQLITE_OK)
    let opened = try #require(database)
    var statement: OpaquePointer?
    #expect(sqlite3_prepare_v2(opened, "SELECT COUNT(*) FROM edits", -1, &statement, nil) == SQLITE_OK)
    let query = try #require(statement)
    defer { sqlite3_finalize(query) }
    #expect(sqlite3_step(query) == SQLITE_ROW)
    return Int(sqlite3_column_int(query, 0))
}

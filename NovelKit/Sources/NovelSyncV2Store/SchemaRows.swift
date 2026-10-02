import Foundation

struct SchemaMarkerRow: SQLiteRowDecodable {
    static let columns = """
    value,checksum
    """
    let value: String?
    let checksum: Data?

    init(_ row: SQLiteRow) throws {
        value = try row.text("value")
        checksum = try row.blob("checksum")
    }
}

struct SQLiteSchemaRow: SQLiteRowDecodable {
    static let columns = """
    name,sql
    """
    let name: String?
    let sql: String?

    init(_ row: SQLiteRow) throws {
        name = try row.text("name")
        sql = try row.text("sql")
    }
}

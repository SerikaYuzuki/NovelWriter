import Foundation

struct SnapshotManifestRow: SQLiteRowDecodable {
    static let columns = """
    work_id,manifest_bytes,manifest_digest
    """
    let workID: String?
    let manifestBytes: Data?
    let manifestDigest: Data?

    init(_ row: SQLiteRow) throws {
        workID = try row.text("work_id")
        manifestBytes = try row.blob("manifest_bytes")
        manifestDigest = try row.blob("manifest_digest")
    }
}

struct SnapshotEntryRow: SQLiteRowDecodable {
    static let columns = """
    entity_key,object_id,byte_count,content_type
    """
    let entityKey: String?
    let objectID: Data?
    let byteCount: Int64?
    let contentType: String?

    init(_ row: SQLiteRow) throws {
        entityKey = try row.text("entity_key")
        objectID = try row.blob("object_id")
        byteCount = try row.int64("byte_count")
        contentType = try row.text("content_type")
    }
}

struct SnapshotObjectRow: SQLiteRowDecodable {
    static let columns = """
    snapshot_id,object_id
    """
    let snapshotID: Data?
    let objectID: Data?

    init(_ row: SQLiteRow) throws {
        snapshotID = try row.blob("snapshot_id")
        objectID = try row.blob("object_id")
    }
}

struct ObjectBytesRow: SQLiteRowDecodable {
    static let columns = """
    object_id,byte_count,bytes
    """
    let objectID: Data?
    let byteCount: Int64?
    let bytes: Data?

    init(_ row: SQLiteRow) throws {
        objectID = try row.blob("object_id")
        byteCount = try row.int64("byte_count")
        bytes = try row.blob("bytes")
    }
}

struct ObjectContentRow: SQLiteRowDecodable {
    static let columns = """
    byte_count,bytes
    """
    let byteCount: Int64?
    let bytes: Data?

    init(_ row: SQLiteRow) throws {
        byteCount = try row.int64("byte_count")
        bytes = try row.blob("bytes")
    }
}

struct ResourceBytesRow: SQLiteRowDecodable {
    static let columns = """
    bytes,byte_count
    """
    let bytes: Data?
    let byteCount: Int64?

    init(_ row: SQLiteRow) throws {
        bytes = try row.blob("bytes")
        byteCount = try row.int64("byte_count")
    }
}

struct WorkResourceRow: SQLiteRowDecodable {
    static let columns = """
    path_components,kind,object_id,byte_count
    """
    let pathComponents: String?
    let kind: String?
    let objectID: Data?
    let byteCount: Int64?

    init(_ row: SQLiteRow) throws {
        pathComponents = try row.text("path_components")
        kind = try row.text("kind")
        objectID = try row.blob("object_id")
        byteCount = try row.int64("byte_count")
    }
}

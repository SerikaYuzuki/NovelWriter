import CSQLite
import Foundation
import NovelWritingSupport

private final class WritingDatabase: @unchecked Sendable {
    let handle: OpaquePointer
    init(_ path: String) throws {
        var value: OpaquePointer?
        guard sqlite3_open_v2(path, &value, SQLITE_OPEN_CREATE | SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK,
              let value else {
            if let value {
                sqlite3_close(value)
            }; throw WritingError.unavailable
        }
        handle = value
        sqlite3_busy_timeout(handle, 5000)
    }

    deinit { sqlite3_close(handle) }
}

/// Independent WAL: AI storage failures cannot fail or delay manuscript checkpoints.
public actor WritingSQLiteStore: WritingLocalPersistence {
    private let db: WritingDatabase
    private let copyRoot: URL
    public init(root: URL) throws {
        copyRoot = root.appendingPathComponent("writing-history-copies", isDirectory: true)
        db = try WritingDatabase(root.appendingPathComponent("writing-assistant.sqlite").path)
        let sql = """
        PRAGMA journal_mode=WAL; PRAGMA synchronous=FULL; PRAGMA foreign_keys=ON;
        CREATE TABLE IF NOT EXISTS records(namespace TEXT NOT NULL,id TEXT NOT NULL,bytes TEXT NOT NULL,
          sequence INTEGER NOT NULL DEFAULT 0,conflicted INTEGER NOT NULL DEFAULT 0,
          pending INTEGER NOT NULL DEFAULT 1,local_order INTEGER NOT NULL,
          PRIMARY KEY(namespace,id));
        CREATE TABLE IF NOT EXISTS cursors(namespace TEXT NOT NULL,remote TEXT NOT NULL,sequence INTEGER NOT NULL,
          PRIMARY KEY(namespace,remote));
        CREATE TABLE IF NOT EXISTS edits(namespace TEXT NOT NULL,id TEXT NOT NULL,payload TEXT NOT NULL,state TEXT NOT NULL,
          PRIMARY KEY(namespace,id));
        CREATE TABLE IF NOT EXISTS history_copies(destination TEXT PRIMARY KEY,source TEXT NOT NULL);
        """
        guard sqlite3_exec(db.handle, sql, nil, nil, nil) == SQLITE_OK else { throw WritingError.unavailable }
    }

    public func copyHistory(source: String, destination: String, newWorkID: UUID) throws {
        guard source != destination else { throw WritingError.invalidRecord }
        // An independent intent survives a database error or restart. A committed copy
        // has its own receipt; new records in the destination never hide old history.
        try FileManager.default.createDirectory(at: copyRoot, withIntermediateDirectories: true)
        let intent = HistoryCopy(source: source, destination: destination, newWorkID: newWorkID)
        let file = copyRoot.appendingPathComponent(newWorkID.uuidString + ".json")
        try JSONEncoder().encode(intent).write(to: file, options: .atomic)
        try performHistoryCopy(intent)
        try FileManager.default.removeItem(at: file)
    }

    private struct HistoryCopy: Codable {
        let source: String
        let destination: String
        let newWorkID: UUID
    }

    public func retryHistoryCopies() throws {
        guard FileManager.default.fileExists(atPath: copyRoot.path) else { return }
        for file in try FileManager.default.contentsOfDirectory(at: copyRoot, includingPropertiesForKeys: nil) where file.pathExtension == "json" {
            let intent = try JSONDecoder().decode(HistoryCopy.self, from: Data(contentsOf: file))
            try performHistoryCopy(intent)
            try FileManager.default.removeItem(at: file)
        }
    }

    private func performHistoryCopy(_ intent: HistoryCopy) throws {
        let source = intent.source, destination = intent.destination, newWorkID = intent.newWorkID
        if let receipt = try query("SELECT source FROM history_copies WHERE destination=?", [destination]).first {
            guard receipt[0] == source else { throw WritingError.invalidRecord }
            return
        }
        let original = try records(namespace: source)
        var mapping: [UUID: UUID] = [:]
        for item in original {
            mapping[item.id] = UUID()
            if let key = UUID(uuidString: item.record.key), mapping[key] == nil {
                mapping[key] = UUID()
            }
        }
        try run("BEGIN IMMEDIATE", [])
        do {
            for item in original {
                var record = item.record
                let oldID = record.id
                record.id = mapping[oldID]!
                record.workId = newWorkID
                record.parentId = record.parentId.flatMap { mapping[$0] }
                if let key = UUID(uuidString: record.key), let replacement = mapping[key] {
                    record.key = replacement.uuidString.lowercased()
                }
                guard var payload = try JSONSerialization.jsonObject(with: Data(record.payload.utf8)) as? [String: Any] else { throw WritingError.invalidRecord }
                for field in ["conversationId", "requestId"] {
                    if let text = payload[field] as? String, let id = UUID(uuidString: text), let replacement = mapping[id] {
                        payload[field] = replacement.uuidString.lowercased()
                    }
                }
                payload["recoveryProvenance"] = ["source": source, "recordId": oldID.uuidString, "capturedAt": Date().ISO8601Format()]
                if record.kind == "request" {
                    payload["state"] = "historical"
                }
                record.payload = try String(
                    decoding: JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys, .withoutEscapingSlashes]),
                    as: UTF8.self
                )
                // Historical records can grow by provenance only; external appends retain their 1 MB limit.
                let bytes = try WritingRecord.payload(record)
                try run(
                    "INSERT INTO records(namespace,id,bytes,conflicted,local_order) VALUES(?,?,?,?,(SELECT COALESCE(MAX(local_order),0)+1 FROM records))",
                    [destination, record.id.uuidString, bytes, item.conflicted ? "1" : "0"]
                )
            }
            try run("INSERT INTO history_copies(destination,source) VALUES(?,?)", [destination, source])
            try run("COMMIT", [])
        } catch { try? run("ROLLBACK", []); throw error }
    }

    public func records(namespace: String) throws -> [WritingEnvelope] {
        try query(
            "SELECT bytes,sequence,conflicted FROM records WHERE namespace=? ORDER BY CASE WHEN sequence>0 THEN 0 ELSE 1 END,sequence,local_order",
            [namespace]
        ).map {
            try WritingEnvelope(record: JSONDecoder().decode(WritingRecord.self, from: Data($0[0].utf8)),
                                sequence: Int64($0[1]) ?? 0, conflicted: $0[2] == "1")
        }
    }

    public func append(_ record: WritingRecord, namespace: String) throws {
        guard record.payload.utf8.count <= 1_000_000, ["prompt", "conversation", "message", "request", "edit"].contains(record.kind),
              !record.key.isEmpty, record.key.utf8.count <= 128,
              (try? JSONSerialization.jsonObject(with: Data(record.payload.utf8))) is [String: Any] else { throw WritingError.invalidRecord }
        let bytes = try WritingRecord.payload(record)
        if let old = try query("SELECT bytes FROM records WHERE namespace=? AND id=?", [namespace, record.id.uuidString]).first {
            var repeated = record
            let original = try JSONDecoder().decode(WritingRecord.self, from: Data(old[0].utf8))
            // Edit retries keep the original durable timestamp and payload.
            if record.kind == "edit" {
                repeated.createdAt = original.createdAt
            }
            guard repeated == original else { throw WritingError.invalidRecord }; return
        }
        try run(
            "INSERT INTO records(namespace,id,bytes,local_order) VALUES(?,?,?,(SELECT COALESCE(MAX(local_order),0)+1 FROM records))",
            [namespace, record.id.uuidString, bytes]
        )
    }

    public func pending(namespace: String) throws -> [WritingRecord] {
        try query("SELECT bytes FROM records WHERE namespace=? AND pending=1 ORDER BY local_order LIMIT 32", [namespace]).map {
            try JSONDecoder().decode(WritingRecord.self, from: Data($0[0].utf8))
        }
    }

    public func accept(_ envelope: WritingEnvelope, namespace: String) throws {
        // Acknowledgements cannot overwrite a different local record with the same ID.
        let bytes = try WritingRecord.payload(envelope.record)
        if let old = try query("SELECT bytes FROM records WHERE namespace=? AND id=?", [namespace, envelope.id.uuidString]).first {
            let oldRecord = try JSONDecoder().decode(WritingRecord.self, from: Data(old[0].utf8))
            guard oldRecord == envelope.record else { throw WritingError.invalidRecord }
        }
        try run("""
        INSERT INTO records(namespace,id,bytes,sequence,conflicted,pending,local_order)
        VALUES(?,?,?,?,?,0,(SELECT COALESCE(MAX(local_order),0)+1 FROM records))
        ON CONFLICT(namespace,id) DO UPDATE SET sequence=excluded.sequence,conflicted=excluded.conflicted,pending=0
        """, [namespace, envelope.id.uuidString, bytes, String(envelope.sequence), envelope.conflicted ? "1" : "0"])
    }

    public func cursor(namespace: String, remote: String) throws -> Int64 {
        try Int64(query("SELECT sequence FROM cursors WHERE namespace=? AND remote=?", [namespace, remote]).first?.first ?? "0") ?? 0
    }

    public func advance(_ sequence: Int64, namespace: String, remote: String) throws {
        try run(
            "INSERT INTO cursors(namespace,remote,sequence) VALUES(?,?,?) ON CONFLICT(namespace,remote) DO UPDATE SET sequence=MAX(sequence,excluded.sequence)",
            [namespace, remote, String(sequence)]
        )
    }

    public func claimEdit(id: UUID, namespace: String, payload: String) throws -> Bool {
        if let old = try query("SELECT payload FROM edits WHERE namespace=? AND id=?", [namespace, id.uuidString]).first {
            guard old[0] == payload else { throw WritingError.invalidEdit }; return false
        }
        try run("INSERT INTO edits(namespace,id,payload,state) VALUES(?,?,?,'prepared')", [namespace, id.uuidString, payload])
        return true
    }

    public func finishEdit(id: UUID, namespace: String, state: String) throws {
        guard ["applied", "rejected", "undone"].contains(state) else { throw WritingError.invalidRecord }
        try run("UPDATE edits SET state=? WHERE namespace=? AND id=?", [state, namespace, id.uuidString])
    }

    public func edit(id: UUID, namespace: String) throws -> WritingEditJournal? {
        try query("SELECT payload,state FROM edits WHERE namespace=? AND id=?", [namespace, id.uuidString]).first.map {
            WritingEditJournal(payload: $0[0], state: $0[1])
        }
    }

    private func statement(_ sql: String, _ values: [String]) throws -> OpaquePointer {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db.handle, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else { throw WritingError.unavailable }
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        for (index, value) in values.enumerated() {
            let status = value.withCString { sqlite3_bind_text(stmt, Int32(index + 1), $0, -1, transient) }
            guard status == SQLITE_OK else { sqlite3_finalize(stmt); throw WritingError.unavailable }
        }
        return stmt
    }

    private func run(_ sql: String, _ values: [String]) throws {
        let stmt = try statement(sql, values); defer { sqlite3_finalize(stmt) }
        guard sqlite3_step(stmt) == SQLITE_DONE else { throw WritingError.unavailable }
    }

    private func query(_ sql: String, _ values: [String]) throws -> [[String]] {
        let stmt = try statement(sql, values); defer { sqlite3_finalize(stmt) }
        var rows: [[String]] = []
        while true {
            let result = sqlite3_step(stmt)
            if result == SQLITE_DONE {
                return rows
            }
            guard result == SQLITE_ROW else { throw WritingError.unavailable }
            rows.append((0 ..< sqlite3_column_count(stmt)).map { index in
                sqlite3_column_text(stmt, index).map { String(cString: $0) } ?? ""
            })
        }
    }
}

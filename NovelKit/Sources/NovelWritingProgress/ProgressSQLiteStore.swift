import CSQLite
import Foundation

public struct WritingProgressRecords: Equatable, Sendable {
    public var days: [UUID: [String: WritingDay]] = [:]
    public var milestones: [UUID: [Int: WritingMilestone]] = [:]
    public init() {}
    public var isEmpty: Bool {
        days.isEmpty && milestones.isEmpty
    }

    public mutating func merge(_ other: Self) {
        for (work, entries) in other.days {
            for (day, value) in entries {
                days[work, default: [:]][day, default: WritingDay()].merge(value)
            }
        }
        for (work, values) in other.milestones {
            for (threshold, value) in values where milestones[work]?[threshold] == nil {
                milestones[work, default: [:]][threshold] = value
            }
        }
    }
}

public protocol WritingProgressPersistence: Sendable {
    func load() async throws -> WritingProgressRecords
    func append(_ records: WritingProgressRecords) async throws
}

public enum WritingProgressStoreError: Error { case unavailable, unsupportedVersion }

private final class ProgressDatabase: @unchecked Sendable {
    let handle: OpaquePointer
    init(path: String) throws {
        var handle: OpaquePointer?
        guard sqlite3_open_v2(path, &handle, SQLITE_OPEN_CREATE | SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX, nil) ==
            SQLITE_OK,
            let handle else {
            if let handle {
                sqlite3_close(handle)
            }
            throw WritingProgressStoreError.unavailable
        }
        self.handle = handle
        sqlite3_busy_timeout(handle, 1000)
    }

    deinit { sqlite3_close(handle) }
}

/// Opening, reads and transactions all execute on this actor, never on the main actor.
public actor WritingProgressSQLiteStore: WritingProgressPersistence {
    private let root: URL
    private var database: ProgressDatabase?
    public init(root: URL) {
        self.root = root
    }

    private func open() throws -> ProgressDatabase {
        if let database {
            return database
        }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let connection = try ProgressDatabase(path: root.appendingPathComponent("writing-progress.sqlite").path)
        var statement: OpaquePointer?
        let prepared = sqlite3_prepare_v2(connection.handle, "PRAGMA user_version", -1, &statement, nil)
        guard prepared == SQLITE_OK else { throw WritingProgressStoreError.unavailable }
        let step = sqlite3_step(statement)
        let version = sqlite3_column_int(statement, 0)
        sqlite3_finalize(statement)
        guard step == SQLITE_ROW else { throw WritingProgressStoreError.unavailable }
        guard version <= 1 else { throw WritingProgressStoreError.unsupportedVersion }
        guard sqlite3_exec(connection.handle, """
        PRAGMA journal_mode=WAL; PRAGMA synchronous=FULL;
        CREATE TABLE IF NOT EXISTS daily(work TEXT NOT NULL,day TEXT NOT NULL,added INTEGER NOT NULL,
          net INTEGER NOT NULL,PRIMARY KEY(work,day));
        CREATE TABLE IF NOT EXISTS milestones(work TEXT NOT NULL,threshold INTEGER NOT NULL,
          reached REAL,PRIMARY KEY(work,threshold));
        PRAGMA user_version=1;
        """, nil, nil, nil) == SQLITE_OK else { throw WritingProgressStoreError.unavailable }
        database = connection
        return connection
    }

    private func query(_ sql: String, values: [String] = [], row: (OpaquePointer) -> Void = { _ in }) throws {
        let connection = try open()
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(connection.handle, sql, -1, &statement, nil) == SQLITE_OK,
              let statement else { throw WritingProgressStoreError.unavailable }
        defer { sqlite3_finalize(statement) }
        for (index, value) in values.enumerated() {
            let result = value.withCString { sqlite3_bind_text(
                statement,
                Int32(index + 1),
                $0,
                -1,
                unsafeBitCast(-1, to: sqlite3_destructor_type.self)
            ) }
            guard result == SQLITE_OK else { throw WritingProgressStoreError.unavailable }
        }
        var result = sqlite3_step(statement)
        while result == SQLITE_ROW {
            row(statement); result = sqlite3_step(statement)
        }
        guard result == SQLITE_DONE else { throw WritingProgressStoreError.unavailable }
    }

    public func load() throws -> WritingProgressRecords {
        var records = WritingProgressRecords()
        try query("SELECT work,day,added,net FROM daily") { statement in
            guard let work = UUID(uuidString: String(cString: sqlite3_column_text(statement, 0))) else { return }
            let day = String(cString: sqlite3_column_text(statement, 1))
            records.days[work, default: [:]][day] = WritingDay(
                added: Int(sqlite3_column_int64(statement, 2)),
                net: Int(sqlite3_column_int64(statement, 3))
            )
        }
        try query("SELECT work,threshold,reached FROM milestones") { statement in
            guard let work = UUID(uuidString: String(cString: sqlite3_column_text(statement, 0))) else { return }
            let threshold = Int(sqlite3_column_int64(statement, 1))
            let date = sqlite3_column_type(statement, 2) == SQLITE_NULL ? nil :
                Date(timeIntervalSince1970: sqlite3_column_double(
                    statement,
                    2
                ))
            records.milestones[work, default: [:]][threshold] = WritingMilestone(threshold: threshold, reachedAt: date)
        }
        return records
    }

    public func append(_ records: WritingProgressRecords) throws {
        try query("BEGIN IMMEDIATE")
        do {
            for (work, entries) in records.days {
                for (day, value) in entries {
                    try query(
                        """
                        INSERT INTO daily VALUES(?,?,?,?) ON CONFLICT(work,day) DO UPDATE
                        SET added=added+excluded.added,net=net+excluded.net
                        """,
                        values: [work.uuidString, day, String(value.added), String(value.net)]
                    )
                }
            }
            for (work, values) in records.milestones {
                for value in values.values {
                    try query(
                        "INSERT OR IGNORE INTO milestones VALUES(?,?,CAST(NULLIF(?,'null') AS REAL))",
                        values: [
                            work.uuidString,
                            String(value.threshold),
                            value.reachedAt.map { String($0.timeIntervalSince1970) } ?? "null"
                        ]
                    )
                }
            }
            try query("COMMIT")
        } catch { try? query("ROLLBACK"); throw error }
    }
}

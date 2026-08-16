// SQLite's C ABI intentionally keeps this persistence boundary verbose:
// statements and bindings are grouped here so each transaction is auditable.
// The SQL helper rows are reviewed as one unit rather than split across many
// tiny files, so the project-wide size rules are scoped out for this adapter.
// swiftlint:disable file_length type_body_length function_body_length function_parameter_count line_length identifier_name

import CSQLite
import Foundation
import NovelSync

/// The only durable authority used by the post-cutover local-first runtime.
/// `.novelpkg` is intentionally not referenced here; it is an import/export
/// codec owned by NovelStorage.
public enum LocalStoreError: Error, Equatable, Sendable {
    case openFailed(String)
    case migrationFailed(String)
    case statementFailed(String)
    case invalidIdentity
    case invalidSnapshot
    case objectMismatch
    case missingWork
    case missingSnapshot
}

public enum LocalSnapshotReason: String, Codable, Sendable {
    case autosave
    case manual
    case lifecycle
    case conflictResolution
    case restoreBefore
}

public struct LocalSnapshotRecord: Codable, Hashable, Sendable, Identifiable {
    public let id: String
    public let workID: UUID
    public let parentSnapshotIDs: [String]
    public let manifest: Data
    public let reason: LocalSnapshotReason
    public let localGeneration: UInt64
    public let pinned: Bool
    public let createdAt: Date

    public init(
        id: String,
        workID: UUID,
        parentSnapshotIDs: [String],
        manifest: Data,
        reason: LocalSnapshotReason,
        localGeneration: UInt64,
        pinned: Bool,
        createdAt: Date
    ) {
        self.id = id
        self.workID = workID
        self.parentSnapshotIDs = parentSnapshotIDs
        self.manifest = manifest
        self.reason = reason
        self.localGeneration = localGeneration
        self.pinned = pinned
        self.createdAt = createdAt
    }
}

public struct LocalObject: Hashable, Sendable {
    public let objectID: String
    public let bytes: Data

    public init(objectID: String, bytes: Data) {
        self.objectID = objectID
        self.bytes = bytes
    }
}

public struct LocalSyncIntent: Codable, Hashable, Sendable, Identifiable {
    public enum Kind: String, Codable, Sendable {
        case latest
        case checkpoint
        case conflictResolution
    }

    public enum Status: String, Codable, Sendable {
        case pending
        case sealed
        case acknowledged
        case blocked
    }

    public let id: UUID
    public let workID: UUID
    public let kind: Kind
    public let localSnapshotID: String
    public let sourceLocalGeneration: UInt64
    public let expectedHeadSnapshotID: String?
    public let status: Status
    public let createdAt: Date

    public init(
        id: UUID,
        workID: UUID,
        kind: Kind,
        localSnapshotID: String,
        sourceLocalGeneration: UInt64,
        expectedHeadSnapshotID: String?,
        status: Status,
        createdAt: Date
    ) {
        self.id = id
        self.workID = workID
        self.kind = kind
        self.localSnapshotID = localSnapshotID
        self.sourceLocalGeneration = sourceLocalGeneration
        self.expectedHeadSnapshotID = expectedHeadSnapshotID
        self.status = status
        self.createdAt = createdAt
    }
}

public struct LocalWorkState: Hashable, Sendable {
    public let workID: UUID
    public let documentID: UUID
    public let documentCreatedAt: String
    public let currentLocalSnapshotID: String?
    public let acknowledgedHeadSnapshotID: String?
    public let acknowledgedHeadGeneration: UInt64?
    public let localGeneration: UInt64

    public init(
        workID: UUID,
        documentID: UUID,
        documentCreatedAt: String,
        currentLocalSnapshotID: String?,
        acknowledgedHeadSnapshotID: String?,
        acknowledgedHeadGeneration: UInt64?,
        localGeneration: UInt64
    ) {
        self.workID = workID
        self.documentID = documentID
        self.documentCreatedAt = documentCreatedAt
        self.currentLocalSnapshotID = currentLocalSnapshotID
        self.acknowledgedHeadSnapshotID = acknowledgedHeadSnapshotID
        self.acknowledgedHeadGeneration = acknowledgedHeadGeneration
        self.localGeneration = localGeneration
    }
}

/// Actor-isolated SQLite store. Every state transition that affects a work,
/// its snapshot, and its remote intent is committed in one SQLite transaction.
public actor LocalSQLiteStore {
    private let handle: SQLiteHandle
    private var database: OpaquePointer?
    private let url: URL

    public init(url: URL) throws {
        self.url = url
        try Self.prepareParentDirectory(for: url)
        var handle: OpaquePointer?
        let flags = SQLITE_OPEN_CREATE | SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX
        guard sqlite3_open_v2(url.path, &handle, flags, nil) == SQLITE_OK, let handle else {
            let message = handle.flatMap { String(cString: sqlite3_errmsg($0)) } ?? "unknown"
            if let handle {
                sqlite3_close(handle)
            }
            throw LocalStoreError.openFailed(message)
        }
        let owner = SQLiteHandle(pointer: handle)
        self.handle = owner
        database = handle
        sqlite3_busy_timeout(handle, 5000)
        do {
            try Self.migrate(handle)
        } catch {
            database = nil
            throw error
        }
    }

    /// Atomically persists the manifest, new CAS objects, local pointer, and
    /// a durable outbox intent. This is the completion boundary for autosave,
    /// navigation, backgrounding, and quit; remote I/O happens afterwards.
    @discardableResult
    public func commitSnapshot(
        workID: UUID,
        documentID: UUID,
        documentCreatedAt: String,
        snapshotID: String,
        parentSnapshotIDs: [String],
        manifest: Data,
        objects: [LocalObject],
        reason: LocalSnapshotReason,
        intentKind: LocalSyncIntent.Kind = .latest,
        pin: Bool = false,
        now: Date = Date()
    ) throws -> LocalSnapshotRecord {
        guard !manifest.isEmpty, snapshotID.count == 64,
              UUID(uuidString: workID.uuidString) != nil,
              UUID(uuidString: documentID.uuidString) != nil,
              !documentCreatedAt.isEmpty else {
            throw LocalStoreError.invalidSnapshot
        }
        guard let database else { throw LocalStoreError.statementFailed("database closed") }
        try exec(database, "BEGIN IMMEDIATE")
        do {
            let existing = try querySnapshot(database, snapshotID: snapshotID)
            if let existing {
                guard existing.workID == workID, existing.manifest == manifest else {
                    throw LocalStoreError.invalidSnapshot
                }
            } else {
                for object in objects {
                    try upsertObject(database, object: object)
                }
                let state = try queryWork(database, workID: workID)
                let generation = (state?.localGeneration ?? 0) + 1
                let timestamp = Self.timestamp(now)
                try upsertWork(
                    database,
                    workID: workID,
                    documentID: documentID,
                    documentCreatedAt: documentCreatedAt,
                    currentLocalSnapshotID: snapshotID,
                    localGeneration: generation,
                    preserveRemote: state
                )
                try insertSnapshot(
                    database,
                    snapshotID: snapshotID,
                    workID: workID,
                    parents: parentSnapshotIDs,
                    manifest: manifest,
                    reason: reason,
                    generation: generation,
                    pin: pin,
                    createdAt: timestamp
                )
                try sealLatestIntent(
                    database,
                    workID: workID,
                    localSnapshotID: snapshotID,
                    sourceLocalGeneration: generation,
                    expectedHeadSnapshotID: state?.acknowledgedHeadSnapshotID,
                    kind: intentKind,
                    createdAt: timestamp
                )
            }
            try exec(database, "COMMIT")
            guard let record = try querySnapshot(database, snapshotID: snapshotID) else {
                throw LocalStoreError.missingSnapshot
            }
            return record
        } catch {
            _ = try? exec(database, "ROLLBACK")
            throw error
        }
    }

    public func workState(for workID: UUID) throws -> LocalWorkState? {
        guard let database else { throw LocalStoreError.statementFailed("database closed") }
        return try queryWork(database, workID: workID)
    }

    /// Returns every locally known work for the startup shelf. This is a
    /// metadata-only query; manifests and manuscript bytes stay in the CAS.
    public func allWorkStates() throws -> [LocalWorkState] {
        guard let database else { throw LocalStoreError.statementFailed("database closed") }
        let statement = try Self.prepare(database, "SELECT work_id FROM works ORDER BY work_id")
        defer { sqlite3_finalize(statement) }
        var result: [LocalWorkState] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            guard let rawID = Self.columnText(statement, index: 0),
                  let workID = UUID(uuidString: rawID),
                  let state = try queryWork(database, workID: workID) else { continue }
            result.append(state)
        }
        return result
    }

    public func snapshot(id: String) throws -> LocalSnapshotRecord? {
        guard let database else { throw LocalStoreError.statementFailed("database closed") }
        return try querySnapshot(database, snapshotID: id)
    }

    /// Installs an exact remote snapshot without creating a new outbound
    /// intent. The caller must first materialize and save the document, then
    /// pass the local generation/snapshot it observed so a concurrent edit
    /// fails closed instead of being overwritten.
    @discardableResult
    public func installRemoteSnapshot(
        workID: UUID,
        documentID: UUID,
        documentCreatedAt: String,
        snapshotID: String,
        parentSnapshotIDs: [String],
        manifest: Data,
        objects: [LocalObject],
        remoteGeneration: UInt64,
        expectedLocalSnapshotID: String?,
        expectedLocalGeneration: UInt64?,
        now: Date = Date()
    ) throws -> LocalSnapshotRecord {
        guard !manifest.isEmpty, snapshotID.count == 64, !documentCreatedAt.isEmpty else {
            throw LocalStoreError.invalidSnapshot
        }
        guard let database else { throw LocalStoreError.statementFailed("database closed") }
        let existingWork = try queryWork(database, workID: workID)
        if let expectedLocalGeneration,
           existingWork?.localGeneration != expectedLocalGeneration {
            throw LocalStoreError.statementFailed("local snapshot changed")
        }
        if let expectedLocalSnapshotID,
           existingWork?.currentLocalSnapshotID != expectedLocalSnapshotID {
            throw LocalStoreError.statementFailed("local snapshot changed")
        }
        try exec(database, "BEGIN IMMEDIATE")
        do {
            // A remote-only work has no local `works` row yet. Create the
            // placeholder before inserting its snapshot because snapshots
            // reference works with a foreign key. The transaction below
            // still publishes the final acknowledged head atomically.
            if existingWork == nil {
                try exec(
                    database,
                    "INSERT INTO works(work_id, document_id, document_created_at, current_local_snapshot_id, acknowledged_head_snapshot_id, acknowledged_head_generation, local_generation) VALUES (?, ?, ?, NULL, NULL, NULL, 0)"
                ) { statement in
                    try Self.bindText(statement, index: 1, value: workID.uuidString.lowercased())
                    try Self.bindText(statement, index: 2, value: documentID.uuidString.lowercased())
                    try Self.bindText(statement, index: 3, value: documentCreatedAt)
                }
            }
            if let existing = try querySnapshot(database, snapshotID: snapshotID) {
                guard existing.workID == workID else {
                    throw LocalStoreError.invalidSnapshot
                }
                if existing.manifest != manifest {
                    // A previous server version returned JSONB manifests in
                    // a different member order. Recover only that known
                    // cache-corruption case: the incoming bytes must hash to
                    // the immutable snapshot ID while the stored bytes must
                    // not. Any two valid-but-different payloads still fail
                    // closed.
                    guard Self.matchesDigest(manifest, snapshotID: snapshotID),
                          !Self.matchesDigest(existing.manifest, snapshotID: snapshotID) else {
                        throw LocalStoreError.invalidSnapshot
                    }
                    for object in objects {
                        try upsertObject(database, object: object)
                    }
                    try replaceSnapshotPayload(
                        database,
                        snapshotID: snapshotID,
                        parentSnapshotIDs: parentSnapshotIDs,
                        manifest: manifest
                    )
                }
            } else {
                for object in objects {
                    try upsertObject(database, object: object)
                }
                let generation = (existingWork?.localGeneration ?? 0) + 1
                try insertSnapshot(
                    database,
                    snapshotID: snapshotID,
                    workID: workID,
                    parents: parentSnapshotIDs,
                    manifest: manifest,
                    reason: .autosave,
                    generation: generation,
                    pin: false,
                    createdAt: Self.timestamp(now)
                )
            }
            let generation = (existingWork?.localGeneration ?? 0) + 1
            try exec(
                database,
                "INSERT INTO works(work_id, document_id, document_created_at, current_local_snapshot_id, acknowledged_head_snapshot_id, acknowledged_head_generation, local_generation) VALUES (?, ?, ?, ?, ?, ?, ?) ON CONFLICT(work_id) DO UPDATE SET document_id = excluded.document_id, document_created_at = excluded.document_created_at, current_local_snapshot_id = excluded.current_local_snapshot_id, acknowledged_head_snapshot_id = excluded.acknowledged_head_snapshot_id, acknowledged_head_generation = excluded.acknowledged_head_generation, local_generation = excluded.local_generation"
            ) { statement in
                try Self.bindText(statement, index: 1, value: workID.uuidString.lowercased())
                try Self.bindText(statement, index: 2, value: documentID.uuidString.lowercased())
                try Self.bindText(statement, index: 3, value: documentCreatedAt)
                try Self.bindText(statement, index: 4, value: snapshotID)
                try Self.bindText(statement, index: 5, value: snapshotID)
                try Self.bindInt64(statement, index: 6, value: Int64(remoteGeneration))
                try Self.bindInt64(statement, index: 7, value: Int64(generation))
            }
            if let expectedLocalSnapshotID {
                try exec(
                    database,
                    "UPDATE sync_intents SET status = 'acknowledged' WHERE work_id = ? AND local_snapshot_id = ? AND status IN ('pending','sealed')"
                ) { statement in
                    try Self.bindText(statement, index: 1, value: workID.uuidString.lowercased())
                    try Self.bindText(statement, index: 2, value: expectedLocalSnapshotID)
                }
            }
            try exec(database, "COMMIT")
            guard let record = try querySnapshot(database, snapshotID: snapshotID) else {
                throw LocalStoreError.missingSnapshot
            }
            return record
        } catch {
            _ = try? exec(database, "ROLLBACK")
            throw error
        }
    }

    public func pendingIntents(for workID: UUID? = nil) throws -> [LocalSyncIntent] {
        guard let database else { throw LocalStoreError.statementFailed("database closed") }
        let sql = if workID == nil {
            "SELECT intent_id, work_id, kind, local_snapshot_id, source_generation, expected_head_snapshot_id, status, created_at FROM sync_intents WHERE status IN ('pending','sealed') ORDER BY created_at, intent_id"
        } else {
            "SELECT intent_id, work_id, kind, local_snapshot_id, source_generation, expected_head_snapshot_id, status, created_at FROM sync_intents WHERE work_id = ? AND status IN ('pending','sealed') ORDER BY created_at, intent_id"
        }
        let statement = try Self.prepare(database, sql)
        defer { sqlite3_finalize(statement) }
        if let workID {
            try Self.bindText(statement, index: 1, value: workID.uuidString.lowercased())
        }
        var result: [LocalSyncIntent] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            try result.append(decodeIntent(statement))
        }
        return result
    }

    /// Acknowledges only the generation that was actually sent. If editing
    /// continued meanwhile, the newer intent remains pending and the local
    /// pointer is never replaced by an older server read-back.
    @discardableResult
    public func acknowledge(
        intentID: UUID,
        remoteSnapshotID: String,
        remoteGeneration: UInt64
    ) throws -> Bool {
        guard let database else { throw LocalStoreError.statementFailed("database closed") }
        guard let intent = try queryIntent(database, id: intentID) else {
            throw LocalStoreError.statementFailed("missing intent")
        }
        guard let work = try queryWork(database, workID: intent.workID) else {
            throw LocalStoreError.missingWork
        }
        try exec(database, "BEGIN IMMEDIATE")
        do {
            try updateAcknowledgedHead(
                database,
                workID: intent.workID,
                snapshotID: remoteSnapshotID,
                generation: remoteGeneration
            )
            let shouldClear = work.localGeneration <= intent.sourceLocalGeneration
                && work.currentLocalSnapshotID == intent.localSnapshotID
            if shouldClear {
                try exec(
                    database,
                    "UPDATE sync_intents SET status = 'acknowledged' WHERE intent_id = ?",
                    bind: { statement in
                        try Self.bindText(statement, index: 1, value: intentID.uuidString.lowercased())
                    }
                )
            }
            try exec(database, "COMMIT")
            return shouldClear
        } catch {
            _ = try? exec(database, "ROLLBACK")
            throw error
        }
    }

    public func object(id: String) throws -> Data? {
        guard let database else { throw LocalStoreError.statementFailed("database closed") }
        let statement = try Self.prepare(database, "SELECT bytes FROM objects WHERE object_id = ?")
        defer { sqlite3_finalize(statement) }
        try Self.bindText(statement, index: 1, value: id)
        guard sqlite3_step(statement) == SQLITE_ROW else { return nil }
        return Self.columnData(statement, index: 0)
    }

    public func setPinned(snapshotID: String, pinned: Bool) throws {
        guard let database else { throw LocalStoreError.statementFailed("database closed") }
        try exec(
            database,
            "UPDATE snapshots SET pinned = ? WHERE snapshot_id = ?",
            bind: { statement in
                try Self.bindInt(statement, index: 1, value: pinned ? 1 : 0)
                try Self.bindText(statement, index: 2, value: snapshotID)
            }
        )
    }

    // MARK: - SQLite setup

    private static func prepareParentDirectory(for url: URL) throws {
        let directory = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    private static func migrate(_ database: OpaquePointer) throws {
        do {
            try execSQL(database, "PRAGMA journal_mode = WAL")
            try execSQL(database, "PRAGMA foreign_keys = ON")
            try exec(database, "CREATE TABLE IF NOT EXISTS schema_meta (key TEXT PRIMARY KEY, value TEXT NOT NULL)")
            try exec(database, """
            CREATE TABLE IF NOT EXISTS works (
                work_id TEXT PRIMARY KEY,
                document_id TEXT NOT NULL,
                document_created_at TEXT NOT NULL,
                current_local_snapshot_id TEXT,
                acknowledged_head_snapshot_id TEXT,
                acknowledged_head_generation INTEGER,
                local_generation INTEGER NOT NULL DEFAULT 0
            )
            """)
            try exec(database, """
            CREATE TABLE IF NOT EXISTS objects (
                object_id TEXT PRIMARY KEY,
                byte_count INTEGER NOT NULL,
                bytes BLOB NOT NULL
            )
            """)
            try exec(database, """
            CREATE TABLE IF NOT EXISTS snapshots (
                snapshot_id TEXT PRIMARY KEY,
                work_id TEXT NOT NULL REFERENCES works(work_id),
                parent_snapshot_ids TEXT NOT NULL,
                manifest BLOB NOT NULL,
                reason TEXT NOT NULL,
                local_generation INTEGER NOT NULL,
                pinned INTEGER NOT NULL DEFAULT 0,
                created_at TEXT NOT NULL
            )
            """)
            try exec(database, """
            CREATE TABLE IF NOT EXISTS sync_intents (
                intent_id TEXT PRIMARY KEY,
                work_id TEXT NOT NULL REFERENCES works(work_id),
                kind TEXT NOT NULL,
                local_snapshot_id TEXT NOT NULL REFERENCES snapshots(snapshot_id),
                source_generation INTEGER NOT NULL,
                expected_head_snapshot_id TEXT,
                status TEXT NOT NULL,
                created_at TEXT NOT NULL
            )
            """)
            try exec(database, "CREATE INDEX IF NOT EXISTS sync_intents_pending ON sync_intents(work_id, status, created_at)")
            try exec(database, "CREATE INDEX IF NOT EXISTS snapshots_work_created ON snapshots(work_id, created_at)")
            try exec(database, "INSERT OR IGNORE INTO schema_meta(key, value) VALUES ('schemaVersion', '1')")
        } catch let error as LocalStoreError {
            throw LocalStoreError.migrationFailed(String(describing: error))
        }
    }

    private static func timestamp(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withDashSeparatorInDate, .withColonSeparatorInTime]
        return formatter.string(from: date)
    }

    private static func date(_ value: String) -> Date {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withDashSeparatorInDate, .withColonSeparatorInTime]
        return formatter.date(from: value) ?? .distantPast
    }

    // MARK: - Row operations

    private func queryWork(_ database: OpaquePointer, workID: UUID) throws -> LocalWorkState? {
        let statement = try Self.prepare(database, "SELECT work_id, document_id, document_created_at, current_local_snapshot_id, acknowledged_head_snapshot_id, acknowledged_head_generation, local_generation FROM works WHERE work_id = ?")
        defer { sqlite3_finalize(statement) }
        try Self.bindText(statement, index: 1, value: workID.uuidString.lowercased())
        guard sqlite3_step(statement) == SQLITE_ROW else { return nil }
        guard let work = Self.columnText(statement, index: 0),
              let documentID = UUID(uuidString: Self.columnText(statement, index: 1) ?? ""),
              let createdAt = Self.columnText(statement, index: 2) else {
            throw LocalStoreError.invalidIdentity
        }
        return LocalWorkState(
            workID: UUID(uuidString: work) ?? workID,
            documentID: documentID,
            documentCreatedAt: createdAt,
            currentLocalSnapshotID: Self.columnText(statement, index: 3),
            acknowledgedHeadSnapshotID: Self.columnText(statement, index: 4),
            acknowledgedHeadGeneration: Self.columnUInt64(statement, index: 5),
            localGeneration: Self.columnUInt64(statement, index: 6) ?? 0
        )
    }

    private func querySnapshot(_ database: OpaquePointer, snapshotID: String) throws -> LocalSnapshotRecord? {
        let statement = try Self.prepare(database, "SELECT snapshot_id, work_id, parent_snapshot_ids, manifest, reason, local_generation, pinned, created_at FROM snapshots WHERE snapshot_id = ?")
        defer { sqlite3_finalize(statement) }
        try Self.bindText(statement, index: 1, value: snapshotID)
        guard sqlite3_step(statement) == SQLITE_ROW else { return nil }
        guard let id = Self.columnText(statement, index: 0),
              let workID = UUID(uuidString: Self.columnText(statement, index: 1) ?? ""),
              let parentsJSON = Self.columnText(statement, index: 2),
              let parentsData = parentsJSON.data(using: .utf8),
              let parents = try? JSONDecoder().decode([String].self, from: parentsData),
              let reason = LocalSnapshotReason(rawValue: Self.columnText(statement, index: 4) ?? ""),
              let createdAt = Self.columnText(statement, index: 7) else {
            throw LocalStoreError.invalidSnapshot
        }
        return LocalSnapshotRecord(
            id: id,
            workID: workID,
            parentSnapshotIDs: parents,
            manifest: Self.columnData(statement, index: 3) ?? Data(),
            reason: reason,
            localGeneration: Self.columnUInt64(statement, index: 5) ?? 0,
            pinned: sqlite3_column_int(statement, 6) != 0,
            createdAt: Self.date(createdAt)
        )
    }

    private func queryIntent(_ database: OpaquePointer, id: UUID) throws -> LocalSyncIntent? {
        let statement = try Self.prepare(database, "SELECT intent_id, work_id, kind, local_snapshot_id, source_generation, expected_head_snapshot_id, status, created_at FROM sync_intents WHERE intent_id = ?")
        defer { sqlite3_finalize(statement) }
        try Self.bindText(statement, index: 1, value: id.uuidString.lowercased())
        guard sqlite3_step(statement) == SQLITE_ROW else { return nil }
        return try decodeIntent(statement)
    }

    private func decodeIntent(_ statement: OpaquePointer) throws -> LocalSyncIntent {
        guard let id = UUID(uuidString: Self.columnText(statement, index: 0) ?? ""),
              let workID = UUID(uuidString: Self.columnText(statement, index: 1) ?? ""),
              let kind = LocalSyncIntent.Kind(rawValue: Self.columnText(statement, index: 2) ?? ""),
              let snapshotID = Self.columnText(statement, index: 3),
              let status = LocalSyncIntent.Status(rawValue: Self.columnText(statement, index: 6) ?? ""),
              let createdAt = Self.columnText(statement, index: 7) else {
            throw LocalStoreError.statementFailed("invalid intent row")
        }
        return LocalSyncIntent(
            id: id,
            workID: workID,
            kind: kind,
            localSnapshotID: snapshotID,
            sourceLocalGeneration: Self.columnUInt64(statement, index: 4) ?? 0,
            expectedHeadSnapshotID: Self.columnText(statement, index: 5),
            status: status,
            createdAt: Self.date(createdAt)
        )
    }

    private func upsertObject(_ database: OpaquePointer, object: LocalObject) throws {
        let statement = try Self.prepare(database, "SELECT byte_count, bytes FROM objects WHERE object_id = ?")
        defer { sqlite3_finalize(statement) }
        try Self.bindText(statement, index: 1, value: object.objectID)
        if sqlite3_step(statement) == SQLITE_ROW {
            let existingCount = sqlite3_column_int64(statement, 0)
            let existingBytes = Self.columnData(statement, index: 1) ?? Data()
            guard existingCount == object.bytes.count, existingBytes == object.bytes else {
                throw LocalStoreError.objectMismatch
            }
            return
        }
        try Self.exec(database, "INSERT INTO objects(object_id, byte_count, bytes) VALUES (?, ?, ?)") { statement in
            try Self.bindText(statement, index: 1, value: object.objectID)
            try Self.bindInt64(statement, index: 2, value: Int64(object.bytes.count))
            try Self.bindData(statement, index: 3, value: object.bytes)
        }
    }

    private func insertSnapshot(
        _ database: OpaquePointer,
        snapshotID: String,
        workID: UUID,
        parents: [String],
        manifest: Data,
        reason: LocalSnapshotReason,
        generation: UInt64,
        pin: Bool,
        createdAt: String
    ) throws {
        let parentsData = try JSONEncoder().encode(parents)
        try Self.exec(database, "INSERT INTO snapshots(snapshot_id, work_id, parent_snapshot_ids, manifest, reason, local_generation, pinned, created_at) VALUES (?, ?, ?, ?, ?, ?, ?, ?)") { statement in
            try Self.bindText(statement, index: 1, value: snapshotID)
            try Self.bindText(statement, index: 2, value: workID.uuidString.lowercased())
            try Self.bindText(statement, index: 3, value: String(decoding: parentsData, as: UTF8.self))
            try Self.bindData(statement, index: 4, value: manifest)
            try Self.bindText(statement, index: 5, value: reason.rawValue)
            try Self.bindInt64(statement, index: 6, value: Int64(generation))
            try Self.bindInt(statement, index: 7, value: pin ? 1 : 0)
            try Self.bindText(statement, index: 8, value: createdAt)
        }
    }

    private func replaceSnapshotPayload(
        _ database: OpaquePointer,
        snapshotID: String,
        parentSnapshotIDs: [String],
        manifest: Data
    ) throws {
        let parentsData = try JSONEncoder().encode(parentSnapshotIDs)
        try Self.exec(
            database,
            "UPDATE snapshots SET parent_snapshot_ids = ?, manifest = ? WHERE snapshot_id = ?"
        ) { statement in
            try Self.bindText(statement, index: 1, value: String(decoding: parentsData, as: UTF8.self))
            try Self.bindData(statement, index: 2, value: manifest)
            try Self.bindText(statement, index: 3, value: snapshotID)
        }
    }

    private static func matchesDigest(_ data: Data, snapshotID: String) -> Bool {
        guard String(data: data, encoding: .utf8) != nil,
              (try? JSONSerialization.jsonObject(with: data)) != nil else { return false }
        guard let text = String(data: data, encoding: .utf8) else { return false }
        return SyncContentDigest(content: text).rawValue == snapshotID
    }

    private func upsertWork(
        _ database: OpaquePointer,
        workID: UUID,
        documentID: UUID,
        documentCreatedAt: String,
        currentLocalSnapshotID: String,
        localGeneration: UInt64,
        preserveRemote: LocalWorkState?
    ) throws {
        try Self.exec(database, "INSERT INTO works(work_id, document_id, document_created_at, current_local_snapshot_id, acknowledged_head_snapshot_id, acknowledged_head_generation, local_generation) VALUES (?, ?, ?, ?, ?, ?, ?) ON CONFLICT(work_id) DO UPDATE SET current_local_snapshot_id = excluded.current_local_snapshot_id, local_generation = excluded.local_generation") { statement in
            try Self.bindText(statement, index: 1, value: workID.uuidString.lowercased())
            try Self.bindText(statement, index: 2, value: documentID.uuidString.lowercased())
            try Self.bindText(statement, index: 3, value: documentCreatedAt)
            try Self.bindText(statement, index: 4, value: currentLocalSnapshotID)
            try Self.bindOptionalText(statement, index: 5, value: preserveRemote?.acknowledgedHeadSnapshotID)
            if let generation = preserveRemote?.acknowledgedHeadGeneration {
                try Self.bindInt64(statement, index: 6, value: Int64(generation))
            } else {
                sqlite3_bind_null(statement, 6)
            }
            try Self.bindInt64(statement, index: 7, value: Int64(localGeneration))
        }
    }

    private func sealLatestIntent(
        _ database: OpaquePointer,
        workID: UUID,
        localSnapshotID: String,
        sourceLocalGeneration: UInt64,
        expectedHeadSnapshotID: String?,
        kind: LocalSyncIntent.Kind,
        createdAt: String
    ) throws {
        if kind == .latest {
            try Self.exec(database, "DELETE FROM sync_intents WHERE work_id = ? AND kind = 'latest' AND status IN ('pending','sealed')") { statement in
                try Self.bindText(statement, index: 1, value: workID.uuidString.lowercased())
            }
        }
        try Self.exec(database, "INSERT INTO sync_intents(intent_id, work_id, kind, local_snapshot_id, source_generation, expected_head_snapshot_id, status, created_at) VALUES (?, ?, ?, ?, ?, ?, 'pending', ?)") { statement in
            try Self.bindText(statement, index: 1, value: UUID().uuidString.lowercased())
            try Self.bindText(statement, index: 2, value: workID.uuidString.lowercased())
            try Self.bindText(statement, index: 3, value: kind.rawValue)
            try Self.bindText(statement, index: 4, value: localSnapshotID)
            try Self.bindInt64(statement, index: 5, value: Int64(sourceLocalGeneration))
            try Self.bindOptionalText(statement, index: 6, value: expectedHeadSnapshotID)
            try Self.bindText(statement, index: 7, value: createdAt)
        }
    }

    private func updateAcknowledgedHead(
        _ database: OpaquePointer,
        workID: UUID,
        snapshotID: String,
        generation: UInt64
    ) throws {
        try Self.exec(database, "UPDATE works SET acknowledged_head_snapshot_id = ?, acknowledged_head_generation = ? WHERE work_id = ?") { statement in
            try Self.bindText(statement, index: 1, value: snapshotID)
            try Self.bindInt64(statement, index: 2, value: Int64(generation))
            try Self.bindText(statement, index: 3, value: workID.uuidString.lowercased())
        }
    }

    // MARK: - C SQLite helpers

    private static func prepare(_ database: OpaquePointer, _ sql: String) throws -> OpaquePointer {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
            throw LocalStoreError.statementFailed(String(cString: sqlite3_errmsg(database)))
        }
        return statement
    }

    private static func exec(
        _ database: OpaquePointer,
        _ sql: String,
        bind: ((OpaquePointer) throws -> Void)? = nil
    ) throws {
        let statement = try prepare(database, sql)
        defer { sqlite3_finalize(statement) }
        try bind?(statement)
        guard sqlite3_step(statement) == SQLITE_DONE else {
            throw LocalStoreError.statementFailed(String(cString: sqlite3_errmsg(database)))
        }
    }

    private static func execSQL(_ database: OpaquePointer, _ sql: String) throws {
        var message: UnsafeMutablePointer<CChar>?
        let result = sqlite3_exec(database, sql, nil, nil, &message)
        guard result == SQLITE_OK else {
            let detail = message.map { String(cString: $0) } ?? String(cString: sqlite3_errmsg(database))
            if let message {
                sqlite3_free(message)
            }
            throw LocalStoreError.statementFailed(detail)
        }
        if let message {
            sqlite3_free(message)
        }
    }

    private func exec(
        _ database: OpaquePointer,
        _ sql: String,
        bind: ((OpaquePointer) throws -> Void)? = nil
    ) throws {
        try Self.exec(database, sql, bind: bind)
    }

    private static func bindText(_ statement: OpaquePointer, index: Int32, value: String) throws {
        guard sqlite3_bind_text(statement, index, value, -1, SQLITE_TRANSIENT) == SQLITE_OK else {
            throw LocalStoreError.statementFailed("bind text failed")
        }
    }

    private static func bindOptionalText(_ statement: OpaquePointer, index: Int32, value: String?) throws {
        if let value {
            try bindText(statement, index: index, value: value)
        } else {
            sqlite3_bind_null(statement, index)
        }
    }

    private static func bindInt(_ statement: OpaquePointer, index: Int32, value: Int) throws {
        guard sqlite3_bind_int(statement, index, Int32(value)) == SQLITE_OK else {
            throw LocalStoreError.statementFailed("bind int failed")
        }
    }

    private static func bindInt64(_ statement: OpaquePointer, index: Int32, value: Int64) throws {
        guard sqlite3_bind_int64(statement, index, value) == SQLITE_OK else {
            throw LocalStoreError.statementFailed("bind int64 failed")
        }
    }

    private static func bindData(_ statement: OpaquePointer, index: Int32, value: Data) throws {
        let result = value.withUnsafeBytes { rawBuffer in
            sqlite3_bind_blob(statement, index, rawBuffer.baseAddress, Int32(value.count), SQLITE_TRANSIENT)
        }
        guard result == SQLITE_OK else { throw LocalStoreError.statementFailed("bind blob failed") }
    }

    private static func columnText(_ statement: OpaquePointer, index: Int32) -> String? {
        guard let value = sqlite3_column_text(statement, index) else { return nil }
        return String(cString: value)
    }

    private static func columnData(_ statement: OpaquePointer, index: Int32) -> Data? {
        guard let bytes = sqlite3_column_blob(statement, index) else { return nil }
        return Data(bytes: bytes, count: Int(sqlite3_column_bytes(statement, index)))
    }

    private static func columnUInt64(_ statement: OpaquePointer, index: Int32) -> UInt64? {
        guard sqlite3_column_type(statement, index) != SQLITE_NULL else { return nil }
        let value = sqlite3_column_int64(statement, index)
        return value >= 0 ? UInt64(value) : nil
    }
}

/// Owns the C pointer without exposing it across actor isolation boundaries.
/// SQLite itself is serialized by the actor; the unchecked marker only covers
/// destruction when the actor is released.
private final class SQLiteHandle: @unchecked Sendable {
    let pointer: OpaquePointer

    init(pointer: OpaquePointer) {
        self.pointer = pointer
    }

    deinit {
        sqlite3_close(pointer)
    }
}

private let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

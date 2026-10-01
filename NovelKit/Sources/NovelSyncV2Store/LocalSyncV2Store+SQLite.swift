import CSQLite
import Foundation
import NovelCore
import NovelSyncV2

extension LocalSyncV2Store {
    static func validateRoot(_ root: URL) throws {
        guard root.isFileURL else { throw SyncV2StoreError.invalidRoot }
        var ancestor = root
        while ancestor.path != "/" {
            let systemAlias = ancestor.path == "/var" || ancestor.path == "/tmp"
            if !systemAlias,
               FileManager.default.fileExists(atPath: ancestor.path),
               try ancestor.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink == true {
                throw SyncV2StoreError.invalidRoot
            }
            ancestor.deleteLastPathComponent()
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

    func scopedWorkRow(
        workID: WorkID,
        scope: V2LocalWorkScope
    ) throws -> [SQLiteValue]? {
        let columns = """
        w.work_id,w.document_id,w.local_generation,w.current_snapshot_id,
        w.acknowledged_head_generation,w.document_created_at,w.sync_lane
        """
        switch scope {
        case .unbound:
            return try query(
                """
                SELECT \(columns) FROM works w
                WHERE w.work_id=? AND NOT EXISTS (
                  SELECT 1 FROM account_bindings b
                  WHERE b.work_id=w.work_id AND b.state IN ('bound','parked')
                )
                """,
                [.text(workID.description)]
            ).first
        case .parked:
            return try query(
                """
                SELECT \(columns) FROM works w
                WHERE w.work_id=? AND EXISTS (
                  SELECT 1 FROM account_bindings b
                  WHERE b.work_id=w.work_id AND b.state='parked'
                ) AND NOT EXISTS (
                  SELECT 1 FROM account_bindings b
                  WHERE b.work_id=w.work_id AND b.state='bound'
                )
                """,
                [.text(workID.description)]
            ).first
        case let .bound(binding):
            return try query(
                """
                SELECT \(columns) FROM works w
                JOIN account_bindings b ON b.work_id=w.work_id
                WHERE w.work_id=? AND b.server_instance_id=?
                  AND b.protocol_epoch=? AND b.account_id=?
                  AND b.account_fence=? AND b.state='bound'
                """,
                [.text(workID.description)] + binding.values
            ).first
        }
    }

    func workExists(workID: WorkID) throws -> Bool {
        try !query(
            "SELECT 1 FROM works WHERE work_id=?",
            [.text(workID.description)]
        ).isEmpty
    }

    func bindingIsActive(workID: WorkID, binding: V2AccountBinding) throws -> Bool {
        try !query(
            """
            SELECT 1 FROM account_bindings
            WHERE work_id=? AND server_instance_id=? AND protocol_epoch=?
              AND account_id=? AND account_fence=? AND state='bound'
            """,
            [.text(workID.description)] + binding.values
        ).isEmpty
    }

    func commandBindingIsActive(
        commandID: UUID,
        binding: V2AccountBinding
    ) throws -> Bool {
        let rows = try query(
            """
            SELECT 1 FROM sealed_commands c
            JOIN account_bindings b ON b.work_id=c.work_id
              AND b.server_instance_id=c.server_instance_id
              AND b.protocol_epoch=c.protocol_epoch
              AND b.account_id=c.account_id
              AND b.account_fence=c.account_fence
            WHERE c.command_id=? AND c.server_instance_id=?
              AND c.protocol_epoch=? AND c.account_id=?
              AND c.account_fence=? AND b.state='bound'
            """,
            [.text(commandID.uuidString.lowercased())] + binding.values
        )
        return !rows.isEmpty
    }

    func insertBinding(workID: WorkID, binding: V2AccountBinding) throws {
        try exec(
            """
            INSERT INTO account_bindings(
              work_id,server_instance_id,protocol_epoch,account_id,
              account_fence,state
            ) VALUES(?,?,?,?,?,'bound')
            """,
            [.text(workID.description)] + binding.values
        )
    }

    func insertWork(
        workID: WorkID,
        documentID: DocumentID,
        documentCreatedAt: String,
        lane: V2SyncLane,
        scope: V2LocalWorkScope
    ) throws {
        try exec(
            """
            INSERT INTO works(
              work_id,document_id,document_created_at,sync_lane
            ) VALUES(?,?,?,?)
            """,
            [
                .text(workID.description), .text(documentID.description),
                .text(documentCreatedAt), .text(lane.rawValue)
            ]
        )
        if case let .bound(binding) = scope {
            try insertBinding(workID: workID, binding: binding)
        }
    }

    func upsertCheckpointIntent(
        workID: WorkID,
        snapshotID: SnapshotID,
        generation: Int64,
        scope: V2LocalWorkScope
    ) throws -> UUID {
        // Every route that queues these bytes (explicit sync, recovery,
        // account replan) promotes the leaf in the caller's transaction.
        if try isUnpromotedLeaf(workID: workID, snapshotID: snapshotID) {
            try insertHistory(workID: workID, snapshotID: snapshotID, reason: "promotion",
                              pinned: true, generation: generation)
        }
        var sql = """
        SELECT intent_id FROM sync_intents
        WHERE work_id=? AND kind='checkpoint' AND status='pending'
        """
        sql += scope.intentPredicateSQL
        let values = [.text(workID.description)] + scope.intentPredicateValues
        if let text = try query(sql, values).first?[0].text,
           let existing = UUID(uuidString: text) {
            try exec(
                """
                UPDATE sync_intents
                SET source_snapshot_id=?,source_generation=?
                WHERE intent_id=? AND status='pending'
                """,
                [.blob(snapshotID.bytes), .int(generation), .text(text)]
            )
            return existing
        }
        let intentID = UUID()
        try insertIntent(
            intentID: intentID,
            workID: workID,
            snapshotID: snapshotID,
            generation: generation,
            kind: "checkpoint",
            scope: scope
        )
        return intentID
    }

    func insertIntent(
        intentID: UUID,
        workID: WorkID,
        snapshotID: SnapshotID,
        generation: Int64,
        kind: String,
        scope: V2LocalWorkScope
    ) throws {
        let fields = scope.intentFields
        try exec(
            """
            INSERT INTO sync_intents(
              intent_id,work_id,source_snapshot_id,source_generation,kind,status,
              scope_kind,server_instance_id,protocol_epoch,account_id,
              account_fence,created_at
            ) VALUES(?,?,?,?,?,'pending',?,?,?,?,?,?)
            """,
            [
                .text(intentID.uuidString.lowercased()), .text(workID.description),
                .blob(snapshotID.bytes), .int(generation), .text(kind)
            ] + fields + [.text(Self.now())]
        )
    }

    func latestPendingIntentID(
        workID: WorkID,
        scope: V2LocalWorkScope
    ) throws -> UUID? {
        var sql = """
        SELECT intent_id FROM sync_intents
        WHERE work_id=? AND status IN ('pending','sealed')
        """
        sql += scope.intentPredicateSQL
        sql += " ORDER BY source_generation DESC LIMIT 1"
        return try query(
            sql,
            [.text(workID.description)] + scope.intentPredicateValues
        ).first?[0].text.flatMap(UUID.init(uuidString:))
    }

    func insertHistory(
        workID: WorkID,
        snapshotID: SnapshotID,
        reason: String,
        pinned: Bool,
        generation: Int64
    ) throws {
        try exec(
            """
            INSERT INTO history_occurrences(
              occurrence_id,work_id,snapshot_id,reason,pinned,
              local_generation,created_at
            ) VALUES(?,?,?,?,?,?,?)
            """,
            [
                .text(UUID().uuidString.lowercased()), .text(workID.description),
                .blob(snapshotID.bytes), .text(reason), .int(pinned ? 1 : 0),
                .int(generation), .text(Self.now())
            ]
        )
    }

    func insertEncoded(_ encoded: EncodedSnapshot, workID: WorkID) throws {
        guard encoded.snapshotId == SnapshotID(data: encoded.manifestBytes),
              encoded.manifest.workId == workID else {
            throw SyncV2StoreError.invalidSnapshot
        }
        guard let work = try query(
            "SELECT document_id,document_created_at FROM works WHERE work_id=?",
            [.text(workID.description)]
        ).first else { throw SyncV2StoreError.workNotFound }
        let model = try SnapshotCodec.decode(encoded)
        guard work[0].text == DocumentID(model.document.id).description,
              try work[1].text == Self.iso8601(model.documentCreatedAt) else {
            throw SyncV2StoreError.invalidSnapshot
        }
        try insertValidatedEncoded(encoded, workID: workID, attestExistingObjects: false)
    }

    /// Caller must validate the immutable snapshot and its document anchor in this transaction.
    func insertValidatedEncoded(_ encoded: EncodedSnapshot, workID: WorkID, attestExistingObjects: Bool = true) throws {
        let alreadyExists = try !query("SELECT 1 FROM snapshots WHERE snapshot_id=?", [.blob(encoded.snapshotIDBytes)]).isEmpty
        try validateParents(encoded, workID: workID, checkCycles: alreadyExists)

        for (objectID, bytes) in encoded.objects {
            if transactionObjects?.contains(objectID) == true {
                continue
            }
            if let existing = try query(
                attestExistingObjects ? "SELECT byte_count,bytes FROM objects WHERE object_id=?" : "SELECT byte_count FROM objects WHERE object_id=?",
                [.blob(objectID.bytes)]
            ).first {
                // Incoming bytes have been digest-validated. Existing immutable CAS
                // rows are protected by attested immutability triggers. Bytes are
                // rehashed on read, rather than reread at every checkpoint.
                // Import must attest bytes it will reuse from an earlier transaction,
                // so a corrupt existing CAS row cannot turn valid input into a bad install.
                // This happens once per unique object, not once per snapshot.
                guard existing[0].int64 == Int64(bytes.count),
                      !attestExistingObjects || existing[1].blob == bytes else {
                    throw SyncV2StoreError.invalidSnapshot
                }
                if attestExistingObjects {
                    transactionObjects?.insert(objectID)
                }
            } else {
                try exec(
                    "INSERT INTO objects(object_id,byte_count,bytes) VALUES(?,?,?)",
                    [.blob(objectID.bytes), .int(Int64(bytes.count)), .blob(bytes)]
                )
                transactionObjects?.insert(objectID)
            }
        }

        if let existing = try query(
            """
            SELECT work_id,manifest_bytes,manifest_digest
            FROM snapshots WHERE snapshot_id=?
            """,
            [.blob(encoded.snapshotIDBytes)]
        ).first {
            guard existing[0].text == workID.description,
                  existing[1].blob == encoded.manifestBytes,
                  existing[2].blob == encoded.snapshotIDBytes else {
                throw SyncV2StoreError.invalidSnapshot
            }
            // Existing rows must already be exact; do not repair missing children
            // with INSERT OR IGNORE before attesting them.
            try attestEncodedRows(encoded, workID: workID)
            return
        } else {
            try exec(
                """
                INSERT INTO snapshots(
                  snapshot_id,work_id,manifest_bytes,manifest_digest,created_at
                ) VALUES(?,?,?,?,?)
                """,
                [
                    .blob(encoded.snapshotIDBytes), .text(workID.description),
                    .blob(encoded.manifestBytes), .blob(encoded.snapshotIDBytes),
                    .text(Self.now())
                ]
            )
        }
        for parent in encoded.manifest.parentSnapshotIds {
            try exec(
                """
                INSERT OR IGNORE INTO snapshot_parents(
                  work_id,snapshot_id,parent_snapshot_id
                ) VALUES(?,?,?)
                """,
                [
                    .text(workID.description), .blob(encoded.snapshotIDBytes),
                    .blob(parent.bytes)
                ]
            )
        }
        for entry in encoded.manifest.entries {
            try exec(
                """
                INSERT OR IGNORE INTO snapshot_entries(
                  snapshot_id,entity_key,object_id,byte_count,content_type
                ) VALUES(?,?,?,?,?)
                """,
                [
                    .blob(encoded.snapshotIDBytes), .text(entry.entityKey),
                    .blob(entry.objectId.bytes), .int(Int64(entry.byteCount)),
                    .text(entry.contentType.rawValue)
                ]
            )
        }
    }

    func loadEncoded(workID: WorkID, snapshotID: SnapshotID) throws -> EncodedSnapshot {
        guard let bytes = try query(
            "SELECT manifest_bytes FROM snapshots WHERE work_id=? AND snapshot_id=?",
            [.text(workID.description), .blob(snapshotID.bytes)]
        ).first?[0].blob,
            SnapshotID(data: bytes) == snapshotID else { throw SyncV2StoreError.snapshotNotFound }
        let manifest = try SnapshotValidator.validate(manifestBytes: bytes)
        guard manifest.workId == workID else { throw SyncV2StoreError.invalidSnapshot }
        var objects: [ObjectID: Data] = [:]
        for entry in manifest.entries {
            guard let object = try query(
                "SELECT byte_count,bytes FROM objects WHERE object_id=?",
                [.blob(entry.objectId.bytes)]
            ).first,
                object[0].int64 == Int64(entry.byteCount),
                let data = object[1].blob,
                ObjectID(data: data) == entry.objectId else { throw SyncV2StoreError.invalidSnapshot }
            objects[entry.objectId] = data
        }
        let encoded = EncodedSnapshot(
            manifest: manifest,
            manifestBytes: bytes,
            objects: objects
        )
        try SnapshotValidator.validateObjects(encoded)
        try attestEncodedRows(encoded, workID: workID)
        return encoded
    }

    func validateParents(_ encoded: EncodedSnapshot, workID: WorkID, checkCycles: Bool = true) throws {
        for parent in encoded.manifest.parentSnapshotIds {
            guard parent != encoded.snapshotId,
                  try !query(
                      "SELECT 1 FROM snapshots WHERE work_id=? AND snapshot_id=?",
                      [.text(workID.description), .blob(parent.bytes)]
                  ).isEmpty else {
                throw SyncV2StoreError.invalidSnapshot
            }
            // A new content-addressed manifest can only point at existing rows.
            // Immediate foreign keys make closing a cycle impossible on insertion.
            if !checkCycles {
                continue
            }
            let cycle = try query(
                """
                WITH RECURSIVE ancestors(id) AS (
                  SELECT parent_snapshot_id FROM snapshot_parents
                    WHERE work_id=? AND snapshot_id=?
                  UNION
                  SELECT p.parent_snapshot_id FROM snapshot_parents p
                    JOIN ancestors a ON p.snapshot_id=a.id
                    WHERE p.work_id=?
                ) SELECT 1 FROM ancestors WHERE id=? LIMIT 1
                """,
                [
                    .text(workID.description), .blob(parent.bytes),
                    .text(workID.description), .blob(encoded.snapshotIDBytes)
                ]
            )
            guard cycle.isEmpty else { throw SyncV2StoreError.invalidSnapshot }
        }
    }

    func attestEncodedRows(_ encoded: EncodedSnapshot, workID: WorkID) throws {
        let parents = try query(
            """
            SELECT parent_snapshot_id FROM snapshot_parents
            WHERE work_id=? AND snapshot_id=? ORDER BY parent_snapshot_id
            """,
            [.text(workID.description), .blob(encoded.snapshotIDBytes)]
        ).compactMap { $0[0].blob?.hexString }
        guard parents == encoded.manifest.parentSnapshotIds.map(\.rawValue).sorted() else {
            throw SyncV2StoreError.invalidSnapshot
        }
        let entries = try query(
            """
            SELECT entity_key,object_id,byte_count,content_type
            FROM snapshot_entries WHERE snapshot_id=? ORDER BY entity_key
            """,
            [.blob(encoded.snapshotIDBytes)]
        )
        guard entries.count == encoded.manifest.entries.count else {
            throw SyncV2StoreError.invalidSnapshot
        }
        for (row, entry) in zip(entries, encoded.manifest.entries) {
            guard row[0].text == entry.entityKey,
                  row[1].blob == entry.objectId.bytes,
                  row[2].int64 == Int64(entry.byteCount),
                  row[3].text == entry.contentType.rawValue else {
                throw SyncV2StoreError.invalidSnapshot
            }
        }
    }

    func validateAnchor(_ model: SnapshotModel, workRow: [SQLiteValue]) throws {
        guard workRow[1].text == DocumentID(model.document.id).description,
              try workRow[5].text == Self.iso8601(model.documentCreatedAt) else {
            throw SyncV2StoreError.invalidSnapshot
        }
    }

    static func summary(_ row: [SQLiteValue]) throws -> V2WorkSummary {
        guard let work = row[0].text,
              let document = row[1].text,
              let generation = row[2].int64,
              let laneText = row[6].text,
              let lane = V2SyncLane(rawValue: laneText) else {
            throw SyncV2StoreError.sqlite("work")
        }
        return try V2WorkSummary(
            workID: WorkID(uuidString: work),
            documentID: DocumentID(uuidString: document),
            localGeneration: generation,
            currentSnapshotID: row[3].blob.map {
                try SnapshotID(rawValue: $0.hexString)
            },
            acknowledgedHeadGeneration: row[4].int64,
            syncLane: lane
        )
    }

    static func pendingIntent(_ row: [SQLiteValue]) throws -> V2PendingIntent {
        guard let intent = row[0].text.flatMap(UUID.init(uuidString:)),
              let work = row[1].text,
              let snapshot = row[2].blob,
              let generation = row[3].int64,
              let kind = row[4].text,
              let status = row[5].text else {
            throw SyncV2StoreError.sqlite("intent")
        }
        return try V2PendingIntent(
            intentID: intent,
            workID: WorkID(uuidString: work),
            sourceSnapshotID: SnapshotID(rawValue: snapshot.hexString),
            sourceGeneration: generation,
            kind: kind,
            status: status
        )
    }

    static func now() -> String {
        (try? iso8601(Date())) ?? "1970-01-01T00:00:00Z"
    }

    static func iso8601(_ date: Date) throws -> String {
        CanonicalTimestamp.string(date)
    }

    func changes() throws -> Int {
        guard let db else { throw SyncV2StoreError.sqlite("closed") }
        return Int(sqlite3_changes(db))
    }

    private func preparedStatement(_ sql: String) throws -> OpaquePointer {
        guard let db else { throw SyncV2StoreError.sqlite("closed") }
        if let statement = statements[sql] {
            return statement
        }
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
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

    func query(_ sql: String, _ bindings: [SQLiteValue] = []) throws -> [[SQLiteValue]] {
        let statement: OpaquePointer? = try preparedStatement(sql)
        defer {
            sqlite3_reset(statement)
            sqlite3_clear_bindings(statement)
        }
        try bind(statement, bindings)
        var rows: [[SQLiteValue]] = []
        var result = sqlite3_step(statement)
        while result == SQLITE_ROW {
            guard let statement else {
                throw SyncV2StoreError.sqlite("query statement unavailable")
            }
            try rows.append((0 ..< sqlite3_column_count(statement)).map {
                try SQLiteValue(statement: statement, index: Int32($0))
            })
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
                sqlite3_bind_text(statement, index, text, -1, sqliteTransient)
            case let .blob(data):
                data.withUnsafeBytes {
                    sqlite3_bind_blob(
                        statement,
                        index,
                        $0.baseAddress,
                        Int32(data.count),
                        sqliteTransient
                    )
                }
            case let .int(number):
                sqlite3_bind_int64(statement, index, number)
            }
            guard result == SQLITE_OK else { throw sqliteError() }
        }
    }

    func sqliteError() -> SyncV2StoreError {
        guard let db else { return .sqlite("closed") }
        return .sqlite(String(cString: sqlite3_errmsg(db)))
    }
}

enum SQLiteValue {
    case null
    case text(String)
    case blob(Data)
    case int(Int64)

    init(statement: OpaquePointer, index: Int32) throws {
        switch sqlite3_column_type(statement, index) {
        case SQLITE_NULL:
            self = .null
        case SQLITE_INTEGER:
            self = .int(sqlite3_column_int64(statement, index))
        case SQLITE_BLOB:
            let count = Int(sqlite3_column_bytes(statement, index))
            guard count >= 0 else {
                throw SyncV2StoreError.sqlite("negative blob length")
            }
            guard count > 0 else {
                self = .blob(Data())
                return
            }
            guard let bytes = sqlite3_column_blob(statement, index) else {
                throw SyncV2StoreError.sqlite("blob bytes unavailable")
            }
            self = .blob(Data(bytes: bytes, count: count))
        default:
            guard let text = sqlite3_column_text(statement, index) else {
                throw SyncV2StoreError.sqlite("text bytes unavailable")
            }
            self = .text(String(cString: text))
        }
    }

    var text: String? {
        if case let .text(value) = self {
            return value
        }
        return nil
    }

    var blob: Data? {
        if case let .blob(value) = self {
            return value
        }
        return nil
    }

    var int64: Int64? {
        if case let .int(value) = self {
            return value
        }
        return nil
    }
}

extension V2AccountBinding {
    var values: [SQLiteValue] {
        [
            .text(serverInstanceID), .int(protocolEpoch),
            .text(accountID), .text(accountFence)
        ]
    }
}

extension V2LocalWorkScope {
    var intentPredicateSQL: String {
        switch self {
        case .unbound:
            " AND scope_kind='unbound'"
        case .parked:
            // Parked work is local-only. Its legacy/unbound intent rows are
            // retained as audit evidence but are never actionable.
            " AND 1=0"
        case .bound:
            """
             AND scope_kind='bound' AND server_instance_id=?
             AND protocol_epoch=? AND account_id=? AND account_fence=?
            """
        }
    }

    var intentPredicateValues: [SQLiteValue] {
        switch self {
        case .unbound, .parked: []
        case let .bound(binding): binding.values
        }
    }

    var intentFields: [SQLiteValue] {
        switch self {
        case .unbound, .parked:
            [.text("unbound"), .null, .null, .null, .null]
        case let .bound(binding):
            [.text("bound")] + binding.values
        }
    }
}

extension Data {
    var hexString: String {
        let digits = Array("0123456789abcdef".utf8)
        var bytes = [UInt8]()
        bytes.reserveCapacity(count * 2)
        for byte in self {
            bytes.append(digits[Int(byte >> 4)])
            bytes.append(digits[Int(byte & 0x0F)])
        }
        return String(decoding: bytes, as: UTF8.self)
    }

    init?(hex: String) {
        let input = Array(hex.utf8)
        guard input.count.isMultiple(of: 2) else { return nil }
        func nibble(_ byte: UInt8) -> UInt8? {
            switch byte {
            case 48 ... 57: byte - 48
            case 65 ... 70: byte - 65 + 10
            case 97 ... 102: byte - 97 + 10
            default: nil
            }
        }
        var bytes = Data()
        bytes.reserveCapacity(input.count / 2)
        for index in stride(from: 0, to: input.count, by: 2) {
            guard let high = nibble(input[index]), let low = nibble(input[index + 1]) else { return nil }
            bytes.append(high << 4 | low)
        }
        self = bytes
    }
}

extension ObjectID {
    var bytes: Data {
        Data(hex: rawValue)! // Typed IDs already enforce a lowercase SHA-256 digest.
    }
}

extension SnapshotID {
    var bytes: Data {
        Data(hex: rawValue)! // Typed IDs already enforce a lowercase SHA-256 digest.
    }
}

extension EncodedSnapshot {
    var snapshotIDBytes: Data {
        snapshotId.bytes
    }
}

let sqliteTransient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

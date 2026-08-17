import CSQLite
import Foundation
import NovelCore
import NovelSyncV2

public actor LocalSyncV2Store {
    public let databaseURL: URL
    var db: OpaquePointer?

    public init(root: URL, policy: V2StoreOpenPolicy) throws {
        try Self.validateRoot(root)
        databaseURL = root.appendingPathComponent("snapshot-sync-v2.sqlite")
        let exists = FileManager.default.fileExists(atPath: databaseURL.path)
        switch policy {
        case .createNew:
            guard !exists else { throw SyncV2StoreError.databaseAlreadyExists }
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        case .openExisting:
            guard exists else { throw SyncV2StoreError.databaseMissing }
        }
        if FileManager.default.fileExists(atPath: databaseURL.path),
           try databaseURL.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink == true {
            throw SyncV2StoreError.invalidRoot
        }

        var handle: OpaquePointer?
        var flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX
        if policy == .createNew {
            flags |= SQLITE_OPEN_CREATE
        }
        let result = sqlite3_open_v2(databaseURL.path, &handle, flags, nil)
        guard result == SQLITE_OK, let handle else {
            throw SyncV2StoreError.sqlite("open \(result)")
        }
        db = handle
        sqlite3_busy_timeout(handle, 5000)
        do {
            try V2StoreSchema.open(handle, create: policy == .createNew)
        } catch {
            sqlite3_close(handle)
            db = nil
            throw error
        }
    }

    public func close() {
        if let db {
            sqlite3_close(db)
            self.db = nil
        }
    }
}

public extension LocalSyncV2Store {
    func schemaVersionAndChecksum() throws -> (String, Data) {
        guard let row = try query(
            "SELECT value,checksum FROM schema_meta WHERE key='schema'"
        ).first,
            let version = row[0].text,
            let checksum = row[1].blob else { throw SyncV2StoreError.schemaMismatch }
        return (version, checksum)
    }

    func bootstrap(
        workID: WorkID,
        documentID: DocumentID,
        documentCreatedAt: Date,
        scope: V2LocalWorkScope
    ) throws {
        try inTransaction {
            let anchor = try Self.iso8601(documentCreatedAt)
            if let row = try scopedWorkRow(workID: workID, scope: scope) {
                guard row[1].text == documentID.description,
                      row[5].text == anchor else {
                    throw SyncV2StoreError.invalidSnapshot
                }
                return
            }
            guard try !workExists(workID: workID) else {
                throw SyncV2StoreError.workNotFound
            }
            try insertWork(
                workID: workID,
                documentID: documentID,
                documentCreatedAt: anchor,
                lane: .normal,
                scope: scope
            )
        }
    }

    func listWorks(scope: V2LocalWorkScope) throws -> [V2WorkSummary] {
        let rows: [[SQLiteValue]] = switch scope {
        case .unbound:
            try query(
                """
                SELECT w.work_id,w.document_id,w.local_generation,
                       w.current_snapshot_id,w.acknowledged_head_generation,
                       w.document_created_at,w.sync_lane
                FROM works w
                WHERE NOT EXISTS (
                  SELECT 1 FROM account_bindings b
                  WHERE b.work_id=w.work_id
                )
                ORDER BY lower(w.work_id)
                """
            )
        case let .bound(binding):
            try query(
                """
                SELECT w.work_id,w.document_id,w.local_generation,
                       w.current_snapshot_id,w.acknowledged_head_generation,
                       w.document_created_at,w.sync_lane
                FROM works w JOIN account_bindings b ON b.work_id=w.work_id
                WHERE b.server_instance_id=? AND b.protocol_epoch=?
                  AND b.account_id=? AND b.account_fence=? AND b.state='bound'
                ORDER BY lower(w.work_id)
                """,
                binding.values
            )
        }
        return try rows.map(Self.summary)
    }

    func open(workID: WorkID, scope: V2LocalWorkScope) throws -> V2OpenResult {
        guard let row = try scopedWorkRow(workID: workID, scope: scope) else {
            throw SyncV2StoreError.workNotFound
        }
        let summary = try Self.summary(row)
        guard let anchor = row[5].text,
              let documentCreatedAt = ISO8601DateFormatter().date(from: anchor) else {
            throw SyncV2StoreError.invalidSnapshot
        }
        guard let snapshotID = summary.currentSnapshotID else {
            return V2OpenResult(
                summary: summary,
                document: nil,
                documentCreatedAt: documentCreatedAt,
                attachments: [],
                resources: []
            )
        }
        let encoded = try loadEncoded(workID: workID, snapshotID: snapshotID)
        let model = try SnapshotCodec.decode(
            manifestBytes: encoded.manifestBytes,
            objects: encoded.objects
        )
        try validateAnchor(model, workRow: row)
        let resources = try loadPortableResources(workID: workID)
        return V2OpenResult(
            summary: summary,
            document: model.document,
            documentCreatedAt: model.documentCreatedAt,
            attachments: model.attachments,
            resources: resources
        )
    }

    func checkpoint(
        _ request: V2CheckpointRequest,
        scope: V2LocalWorkScope
    ) throws -> V2CheckpointResult {
        let existing = try scopedWorkRow(workID: request.workID, scope: scope)
        if existing == nil, try workExists(workID: request.workID) {
            throw SyncV2StoreError.workNotFound
        }
        let anchor = try Self.iso8601(request.documentCreatedAt)
        var parents: [SnapshotID] = []
        if let existing {
            guard existing[1].text == DocumentID(request.document.id).description,
                  existing[2].int64 == request.expectedGeneration,
                  existing[5].text == anchor else {
                throw SyncV2StoreError.generationMismatch
            }
            if let bytes = existing[3].blob {
                parents = try [SnapshotID(rawValue: bytes.hexString)]
            }
        }
        let encoded = try SnapshotCodec.encode(
            SnapshotModel(
                workId: request.workID,
                document: request.document,
                documentCreatedAt: request.documentCreatedAt,
                attachments: request.attachments
            ),
            parents: parents
        )
        let resourcesMatch = if let resources = request.resources {
            try portableResourcesEqual(workID: request.workID, resources: resources)
        } else {
            true
        }
        if let current = parents.first,
           try checkpointContentMatches(
               workID: request.workID,
               current: current,
               candidate: encoded
           ),
           resourcesMatch {
            return try commitNoChangeCheckpoint(
                request,
                scope: scope,
                current: current,
                anchor: anchor
            )
        }

        return try inTransaction {
            if existing == nil {
                try insertWork(
                    workID: request.workID,
                    documentID: DocumentID(request.document.id),
                    documentCreatedAt: anchor,
                    lane: .normal,
                    scope: scope
                )
            }
            guard let current = try scopedWorkRow(workID: request.workID, scope: scope),
                  current[2].int64 == request.expectedGeneration,
                  current[1].text == DocumentID(request.document.id).description,
                  current[5].text == anchor else {
                throw SyncV2StoreError.generationMismatch
            }
            try insertEncoded(encoded, workID: request.workID)
            if let resources = request.resources {
                try replacePortableResources(
                    workID: request.workID,
                    resources: resources
                )
            }
            let next = request.expectedGeneration + 1
            try exec(
                """
                UPDATE works SET current_snapshot_id=?,local_generation=?
                WHERE work_id=? AND local_generation=?
                """,
                [
                    .blob(encoded.snapshotIDBytes), .int(next),
                    .text(request.workID.description), .int(request.expectedGeneration)
                ]
            )
            guard try changes() == 1 else {
                throw SyncV2StoreError.generationMismatch
            }
            try insertHistory(
                workID: request.workID,
                snapshotID: encoded.snapshotId,
                reason: request.reason.rawValue,
                pinned: request.reason.protectsOccurrence,
                generation: next
            )
            let lane = V2SyncLane(rawValue: current[6].text ?? "")
            let intentID: UUID? = if lane == .normal {
                try upsertCheckpointIntent(
                    workID: request.workID,
                    snapshotID: encoded.snapshotId,
                    generation: next,
                    scope: scope
                )
            } else {
                nil
            }
            return V2CheckpointResult(
                snapshotID: encoded.snapshotId,
                generation: next,
                intentID: intentID,
                noChanges: false
            )
        }
    }

    func pendingIntents(
        scope: V2LocalWorkScope,
        workID: WorkID? = nil
    ) throws -> [V2PendingIntent] {
        var sql = """
        SELECT intent_id,work_id,source_snapshot_id,source_generation,kind,status
        FROM sync_intents WHERE status IN ('pending','sealed')
        """
        sql += scope.intentPredicateSQL
        var values = scope.intentPredicateValues
        if let workID {
            sql += " AND work_id=?"
            values.append(.text(workID.description))
        }
        sql += " ORDER BY work_id,source_generation"
        return try query(sql, values).map(Self.pendingIntent)
    }

    func prepareExplicitAccountClone(
        sourceWorkID: WorkID,
        sourceScope: V2LocalWorkScope,
        newWorkID: WorkID,
        newDocumentID: DocumentID,
        destination: V2AccountBinding
    ) throws -> V2CheckpointResult {
        guard sourceWorkID != newWorkID,
              let source = try scopedWorkRow(
                  workID: sourceWorkID,
                  scope: sourceScope
              ),
              let sourceSnapshotBytes = source[3].blob,
              try !workExists(workID: newWorkID) else {
            throw SyncV2StoreError.workNotFound
        }
        let sourceSnapshot = try SnapshotID(rawValue: sourceSnapshotBytes.hexString)
        let encoded = try loadEncoded(workID: sourceWorkID, snapshotID: sourceSnapshot)
        let sourceResources = try loadPortableResources(workID: sourceWorkID)
        let sourceModel = try SnapshotCodec.decode(
            manifestBytes: encoded.manifestBytes,
            objects: encoded.objects
        )
        var clonedDocument = sourceModel.document
        clonedDocument.id = newDocumentID.rawValue
        let clone = try SnapshotCodec.encode(
            SnapshotModel(
                workId: newWorkID,
                document: clonedDocument,
                documentCreatedAt: sourceModel.documentCreatedAt,
                attachments: sourceModel.attachments
            ),
            parents: []
        )
        let intentID = UUID()
        return try inTransaction {
            guard try scopedWorkRow(
                workID: sourceWorkID,
                scope: sourceScope
            )?[3].blob == sourceSnapshotBytes,
                try !workExists(workID: newWorkID) else {
                throw SyncV2StoreError.staleCAS
            }
            try insertWork(
                workID: newWorkID,
                documentID: newDocumentID,
                documentCreatedAt: Self.iso8601(sourceModel.documentCreatedAt),
                lane: .normal,
                scope: .bound(destination)
            )
            try insertEncoded(clone, workID: newWorkID)
            try replacePortableResources(
                workID: newWorkID,
                resources: sourceResources
            )
            try exec(
                """
                UPDATE works SET current_snapshot_id=?,local_generation=1
                WHERE work_id=? AND local_generation=0
                """,
                [.blob(clone.snapshotIDBytes), .text(newWorkID.description)]
            )
            guard try changes() == 1 else { throw SyncV2StoreError.staleCAS }
            try insertHistory(
                workID: newWorkID,
                snapshotID: clone.snapshotId,
                reason: "explicitAccountClone",
                pinned: false,
                generation: 1
            )
            try insertIntent(
                intentID: intentID,
                workID: newWorkID,
                snapshotID: clone.snapshotId,
                generation: 1,
                kind: "checkpoint",
                scope: .bound(destination)
            )
            return V2CheckpointResult(
                snapshotID: clone.snapshotId,
                generation: 1,
                intentID: intentID,
                noChanges: false
            )
        }
    }

    func rebindWork(
        workID: WorkID,
        from old: V2AccountBinding,
        to new: V2AccountBinding
    ) throws {
        try inTransaction {
            guard try bindingIsActive(workID: workID, binding: old) else {
                throw SyncV2StoreError.accountMismatch
            }
            let disposition = old.accountID == new.accountID &&
                old.serverInstanceID == new.serverInstanceID &&
                old.protocolEpoch == new.protocolEpoch ? "quarantined" : "parked"
            try exec(
                """
                UPDATE account_bindings SET state=?
                WHERE work_id=? AND server_instance_id=? AND protocol_epoch=?
                  AND account_id=? AND account_fence=? AND state='bound'
                """,
                [.text(disposition), .text(workID.description)] + old.values
            )
            guard try changes() == 1 else { throw SyncV2StoreError.accountMismatch }
            try exec(
                """
                UPDATE sealed_commands SET status=?
                WHERE work_id=? AND server_instance_id=? AND protocol_epoch=?
                  AND account_id=? AND account_fence=?
                  AND status IN ('sealed','sending','conflictPending')
                """,
                [.text(disposition), .text(workID.description)] + old.values
            )
            try exec(
                """
                UPDATE sync_intents SET status=?
                WHERE work_id=? AND scope_kind='bound'
                  AND server_instance_id=? AND protocol_epoch=?
                  AND account_id=? AND account_fence=?
                  AND status IN ('pending','sealed')
                """,
                [.text(disposition), .text(workID.description)] + old.values
            )
            try exec(
                """
                UPDATE inbox_batches SET state='rejected',rejection_code=?
                WHERE work_id=? AND server_instance_id=? AND protocol_epoch=?
                  AND account_id=? AND account_fence=?
                  AND state IN ('staged','verified')
                """,
                [.text(disposition), .text(workID.description)] + old.values
            )
            try exec(
                """
                UPDATE conflicts SET state=?
                WHERE work_id=? AND server_instance_id=? AND protocol_epoch=?
                  AND account_id=? AND account_fence=? AND state='active'
                """,
                [.text(disposition), .text(workID.description)] + old.values
            )
            try exec(
                """
                UPDATE pending_keep_both SET state=?
                WHERE source_work_id=? AND conflict_id IN (
                  SELECT conflict_id FROM conflicts
                  WHERE work_id=? AND server_instance_id=? AND protocol_epoch=?
                    AND account_id=? AND account_fence=? AND state=?
                ) AND state IN ('prepared','sealed')
                """,
                [
                    .text(disposition), .text(workID.description),
                    .text(workID.description)
                ] + old.values + [.text(disposition)]
            )
            if disposition == "quarantined" {
                try insertBinding(workID: workID, binding: new)
            }
            try exec(
                """
                INSERT INTO binding_transitions(
                  transition_id,work_id,old_server_instance_id,old_protocol_epoch,
                  old_account_id,old_account_fence,disposition,
                  new_server_instance_id,new_protocol_epoch,new_account_id,
                  new_account_fence,created_at
                ) VALUES(?,?,?,?,?,?,?,?,?,?,?,?)
                """,
                [.text(UUID().uuidString.lowercased()), .text(workID.description)] +
                    old.values + [.text(disposition)] + new.values + [.text(Self.now())]
            )
        }
    }

    func historyCount(workID: WorkID, scope: V2LocalWorkScope) throws -> Int {
        guard try scopedWorkRow(workID: workID, scope: scope) != nil else {
            throw SyncV2StoreError.workNotFound
        }
        return try Int(query(
            "SELECT COUNT(*) FROM history_occurrences WHERE work_id=?",
            [.text(workID.description)]
        ).first?[0].int64 ?? 0)
    }

    func history(
        workID: WorkID,
        scope: V2LocalWorkScope
    ) throws -> [V2HistoryOccurrence] {
        guard try scopedWorkRow(workID: workID, scope: scope) != nil else {
            throw SyncV2StoreError.workNotFound
        }
        return try query(
            """
            SELECT snapshot_id,reason,pinned,local_generation,occurrence_id,created_at
            FROM history_occurrences WHERE work_id=? ORDER BY rowid
            """,
            [.text(workID.description)]
        ).map { row in
            guard let snapshot = row[0].blob,
                  let reason = row[1].text,
                  let generation = row[3].int64,
                  let occurrenceText = row[4].text,
                  let occurrenceID = UUID(uuidString: occurrenceText),
                  let createdText = row[5].text,
                  let createdAt = Self.parseHistoryDate(createdText) else {
                throw SyncV2StoreError.invalidHistoryDate
            }
            return try V2HistoryOccurrence(
                occurrenceID: occurrenceID,
                snapshotID: SnapshotID(rawValue: snapshot.hexString),
                reason: reason,
                pinned: row[2].int64 == 1,
                localGeneration: generation,
                createdAt: createdAt
            )
        }
    }

    /// Returns immutable local occurrences newest-first. The cursor is an
    /// opaque `(created_at, local_generation, occurrence_id)` boundary, so inserts after a page
    /// was read cannot reorder or duplicate an already-read occurrence.
    func historyPage(
        workID: WorkID,
        scope: V2LocalWorkScope,
        cursor: String? = nil,
        pageSize: Int = 100
    ) throws -> V2HistoryPage {
        guard (1 ... 500).contains(pageSize) else {
            throw SyncV2StoreError.invalidHistoryCursor
        }
        guard try scopedWorkRow(workID: workID, scope: scope) != nil else {
            throw SyncV2StoreError.workNotFound
        }

        let boundary = try cursor.map(Self.decodeHistoryCursor)
        var sql = """
        SELECT occurrence_id,snapshot_id,reason,pinned,local_generation,created_at
        FROM history_occurrences
        WHERE work_id=?
        """
        var values: [SQLiteValue] = [.text(workID.description)]
        if let boundary {
            sql += " AND (created_at < ? OR (created_at = ? AND (local_generation < ? OR (local_generation = ? AND occurrence_id < ?))))"
            values += [
                .text(boundary.createdAt),
                .text(boundary.createdAt),
                .int(boundary.localGeneration),
                .int(boundary.localGeneration),
                .text(boundary.occurrenceID.uuidString.lowercased())
            ]
        }
        sql += " ORDER BY created_at DESC, local_generation DESC, occurrence_id DESC LIMIT ?"
        values.append(.int(Int64(pageSize)))

        let occurrences = try query(sql, values).map { row in
            guard let occurrenceText = row[0].text,
                  let occurrenceID = UUID(uuidString: occurrenceText),
                  let snapshot = row[1].blob,
                  let reason = row[2].text,
                  let pinned = row[3].int64,
                  let generation = row[4].int64,
                  let createdText = row[5].text,
                  let createdAt = Self.parseHistoryDate(createdText) else {
                throw SyncV2StoreError.invalidHistoryDate
            }
            guard pinned == 0 || pinned == 1, generation > 0 else {
                throw SyncV2StoreError.invalidHistoryDate
            }
            return try V2HistoryOccurrence(
                occurrenceID: occurrenceID,
                snapshotID: SnapshotID(rawValue: snapshot.hexString),
                reason: reason,
                pinned: pinned == 1,
                localGeneration: generation,
                createdAt: createdAt
            )
        }
        let nextCursor = occurrences.count == pageSize
            ? occurrences.last.map { Self.encodeHistoryCursor($0) }
            : nil
        return V2HistoryPage(items: occurrences, nextCursor: nextCursor)
    }

    func snapshotParents(
        workID: WorkID,
        snapshotID: SnapshotID,
        scope: V2LocalWorkScope
    ) throws -> [SnapshotID] {
        guard try scopedWorkRow(workID: workID, scope: scope) != nil else {
            throw SyncV2StoreError.workNotFound
        }
        return try query(
            """
            SELECT parent_snapshot_id FROM snapshot_parents
            WHERE work_id=? AND snapshot_id=? ORDER BY parent_snapshot_id
            """,
            [.text(workID.description), .blob(snapshotID.bytes)]
        ).map { row in
            guard let bytes = row[0].blob else {
                throw SyncV2StoreError.invalidSnapshot
            }
            return try SnapshotID(rawValue: bytes.hexString)
        }
    }
}

private extension LocalSyncV2Store {
    struct HistoryCursor {
        let createdAt: String
        let localGeneration: Int64
        let occurrenceID: UUID
    }

    static func parseHistoryDate(_ value: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.formatOptions = [
            .withInternetDateTime,
            .withDashSeparatorInDate,
            .withColonSeparatorInTime,
            .withFractionalSeconds
        ]
        if let date = formatter.date(from: value) {
            return date
        }
        formatter.formatOptions.remove(.withFractionalSeconds)
        return formatter.date(from: value)
    }

    static func encodeHistoryCursor(_ occurrence: V2HistoryOccurrence) -> String {
        let date = (try? iso8601(occurrence.createdAt)) ?? "1970-01-01T00:00:00Z"
        let raw = "\(date)|\(occurrence.localGeneration)|\(occurrence.occurrenceID.uuidString.lowercased())"
        return Data(raw.utf8).base64EncodedString()
    }

    static func decodeHistoryCursor(_ cursor: String) throws -> HistoryCursor {
        guard let data = Data(base64Encoded: cursor),
              let raw = String(data: data, encoding: .utf8),
              let lastSeparator = raw.lastIndex(of: "|"),
              let firstSeparator = raw[..<lastSeparator].lastIndex(of: "|") else {
            throw SyncV2StoreError.invalidHistoryCursor
        }
        let dateText = String(raw[..<firstSeparator])
        let generationText = String(raw[raw.index(after: firstSeparator) ..< lastSeparator])
        let idText = String(raw[raw.index(after: lastSeparator)...])
        guard let date = parseHistoryDate(dateText),
              let localGeneration = Int64(generationText),
              localGeneration > 0,
              let occurrenceID = UUID(uuidString: idText) else {
            throw SyncV2StoreError.invalidHistoryCursor
        }
        return HistoryCursor(
            createdAt: (try? iso8601(date)) ?? dateText,
            localGeneration: localGeneration,
            occurrenceID: occurrenceID
        )
    }
}

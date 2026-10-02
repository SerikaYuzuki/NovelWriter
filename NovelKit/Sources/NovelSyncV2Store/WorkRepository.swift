import Foundation
import NovelCore
import NovelSyncV2

/// Borrows the store executor; transaction ownership stays with LocalSyncV2Store.
struct WorkRepository: SQLiteRepository {
    let executor: SQLiteExecutor
}

extension WorkRepository {
    func schemaVersionAndChecksum() throws -> (String, Data) {
        guard let row = try queryRows(
            SchemaMarkerRow.self,
            "SELECT \(SchemaMarkerRow.columns) FROM schema_meta WHERE key='schema'"
        ).first,
            let version = row.value,
            let checksum = row.checksum else { throw SyncV2StoreError.schemaMismatch }
        return (version, checksum)
    }

    func listWorks(scope: V2LocalWorkScope) throws -> [V2WorkSummary] {
        let rows: [WorkRow] = switch scope {
        case .unbound:
            try queryRows(
                WorkRow.self,
                """
                SELECT \(WorkRow.columns)
                FROM works w
                WHERE NOT EXISTS (
                  SELECT 1 FROM account_bindings b
                  WHERE b.work_id=w.work_id AND b.state IN ('bound','parked')
                )
                ORDER BY lower(w.work_id)
                """
            )
        case .parked:
            try queryRows(
                WorkRow.self,
                """
                SELECT \(WorkRow.columns)
                FROM works w
                WHERE EXISTS (
                  SELECT 1 FROM account_bindings b
                  WHERE b.work_id=w.work_id AND b.state='parked'
                ) AND NOT EXISTS (
                  SELECT 1 FROM account_bindings b
                  WHERE b.work_id=w.work_id AND b.state='bound'
                )
                ORDER BY lower(w.work_id)
                """
            )
        case let .bound(binding):
            try queryRows(
                WorkRow.self,
                """
                SELECT \(WorkRow.columns)
                FROM works w JOIN account_bindings b ON b.work_id=w.work_id
                WHERE b.server_instance_id=? AND b.protocol_epoch=?
                  AND b.account_id=? AND b.account_fence=? AND b.state='bound'
                ORDER BY lower(w.work_id)
                """,
                binding.values
            )
        }
        return try rows.map(WorkRepository.summary)
    }

    func listParkedWorks() throws -> [V2WorkSummary] {
        try listWorks(scope: .parked)
    }

    func open(workID: WorkID, scope: V2LocalWorkScope) throws -> V2OpenResult {
        guard let row = try scopedWorkRow(workID: workID, scope: scope) else {
            throw SyncV2StoreError.workNotFound
        }
        let summary = try WorkRepository.summary(row)
        guard let anchor = row.documentCreatedAt,
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

    func historyCount(workID: WorkID, scope: V2LocalWorkScope) throws -> Int {
        guard try scopedWorkRow(workID: workID, scope: scope) != nil else {
            throw SyncV2StoreError.workNotFound
        }
        return try Int(query(
            "SELECT COUNT(*) FROM history_occurrences WHERE work_id=?",
            [.text(workID.description)]
        ).first?.scalar.int64 ?? 0)
    }

    func history(
        workID: WorkID,
        scope: V2LocalWorkScope
    ) throws -> [V2HistoryOccurrence] {
        guard try scopedWorkRow(workID: workID, scope: scope) != nil else {
            throw SyncV2StoreError.workNotFound
        }
        return try queryRows(
            HistoryOccurrenceRow.self,
            """
            SELECT \(HistoryOccurrenceRow.columns)
            FROM history_occurrences WHERE work_id=? ORDER BY rowid
            """,
            [.text(workID.description)]
        ).map { row in
            guard let snapshot = row.snapshotID,
                  let reason = row.reason,
                  let generation = row.localGeneration,
                  let occurrenceText = row.occurrenceID,
                  let occurrenceID = UUID(uuidString: occurrenceText),
                  let createdText = row.createdAt,
                  let createdAt = WorkRepository.parseHistoryDate(createdText) else {
                throw SyncV2StoreError.invalidHistoryDate
            }
            return try V2HistoryOccurrence(
                occurrenceID: occurrenceID,
                snapshotID: SnapshotID(rawValue: snapshot.hexString),
                reason: reason,
                pinned: row.pinned == 1,
                localGeneration: generation,
                createdAt: createdAt
            )
        }
    }

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

        let boundary = try cursor.map(WorkRepository.decodeHistoryCursor)
        let scopeKey = WorkRepository.historyScopeKey(scope)
        if let boundary, boundary.scopeKey != scopeKey {
            throw SyncV2StoreError.invalidHistoryCursor
        }
        var sql = """
        SELECT \(HistoryPageRow.columns)
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

        let occurrences = try queryRows(
            HistoryPageRow.self,
            sql, values
        ).map { row in
            guard let occurrenceText = row.occurrenceID,
                  let occurrenceID = UUID(uuidString: occurrenceText),
                  let snapshot = row.snapshotID,
                  let reason = row.reason,
                  let pinned = row.pinned,
                  let generation = row.localGeneration,
                  let createdText = row.createdAt,
                  let createdAt = WorkRepository.parseHistoryDate(createdText) else {
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
            ? occurrences.last.map { WorkRepository.encodeHistoryCursor($0, scopeKey: scopeKey) }
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
        return try loadEncoded(workID: workID, snapshotID: snapshotID).manifest.parentSnapshotIds
    }
}

extension WorkRepository {
    func workSummary(workID: WorkID, scope: V2LocalWorkScope) throws -> V2WorkSummary {
        guard let row = try scopedWorkRow(workID: workID, scope: scope) else {
            throw SyncV2StoreError.workNotFound
        }
        guard let anchor = row.documentCreatedAt,
              ISO8601DateFormatter().date(from: anchor) != nil else {
            throw SyncV2StoreError.invalidSnapshot
        }
        return try WorkRepository.summary(row)
    }
}

extension WorkRepository {
    static func summary(_ row: WorkRow) throws -> V2WorkSummary {
        guard let work = row.workID,
              let document = row.documentID,
              let generation = row.localGeneration,
              let laneText = row.syncLane,
              let lane = V2SyncLane(rawValue: laneText) else {
            throw SyncV2StoreError.sqlite("work")
        }
        return try V2WorkSummary(
            workID: WorkID(uuidString: work),
            documentID: DocumentID(uuidString: document),
            localGeneration: generation,
            currentSnapshotID: row.currentSnapshotID.map {
                try SnapshotID(rawValue: $0.hexString)
            },
            acknowledgedHeadGeneration: row.acknowledgedHeadGeneration,
            syncLane: lane
        )
    }
}

extension WorkRepository {
    static func migrationLedgerEntry(_ row: MigrationLedgerRow) -> V2MigrationLedgerEntry {
        let state = V2MigrationLedgerState(rawValue: row.state ?? "")!
        return V2MigrationLedgerEntry(
            migrationID: UUID(uuidString: row.migrationID ?? "")!,
            accountID: row.accountID,
            sourceKind: row.sourceKind ?? "",
            sourceDigest: row.sourceDigest ?? Data(),
            exportBackupMarker: row.exportBackupMarker,
            adoptionMarker: row.adoptionMarker,
            quarantinedFromState: row.quarantinedFromState.flatMap(V2MigrationLedgerState.init(rawValue:)),
            evidenceBytes: row.evidenceBytes ?? Data(),
            state: state
        )
    }
}

extension WorkRepository {
    struct HistoryCursor: Codable {
        let scopeKey: String
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

    static func historyScopeKey(_ scope: V2LocalWorkScope) -> String {
        switch scope {
        case .unbound: "unbound"
        case .parked: "parked"
        case let .bound(binding):
            "bound|\(binding.serverInstanceID)|\(binding.protocolEpoch)|\(binding.accountID)|\(binding.accountFence)"
        }
    }

    static func encodeHistoryCursor(
        _ occurrence: V2HistoryOccurrence,
        scopeKey: String
    ) -> String {
        let date = (try? StoreValueCoding.iso8601(occurrence.createdAt)) ?? "1970-01-01T00:00:00Z"
        let cursor = HistoryCursor(
            scopeKey: scopeKey,
            createdAt: date,
            localGeneration: occurrence.localGeneration,
            occurrenceID: occurrence.occurrenceID
        )
        let data = (try? JSONEncoder().encode(cursor)) ?? Data()
        return data.base64EncodedString()
    }

    static func decodeHistoryCursor(_ cursor: String) throws -> HistoryCursor {
        guard let data = Data(base64Encoded: cursor),
              let value = try? JSONDecoder().decode(HistoryCursor.self, from: data),
              let date = parseHistoryDate(value.createdAt),
              value.localGeneration > 0 else {
            throw SyncV2StoreError.invalidHistoryCursor
        }
        return HistoryCursor(
            scopeKey: value.scopeKey,
            createdAt: (try? StoreValueCoding.iso8601(date)) ?? value.createdAt,
            localGeneration: value.localGeneration,
            occurrenceID: value.occurrenceID
        )
    }
}

/// One immutable head closure, bounded to the last work/binding requested.
extension WorkRepository {
    struct RegisteredAncestorCache {
        let work: WorkID
        let binding: V2AccountBinding
        let head: SnapshotID
        let ids: Set<SnapshotID>
    }
}

import Foundation
import NovelSyncV2

public extension LocalSyncV2Store {
    func backfillState(workID: WorkID) throws -> V2BackfillState? {
        guard let row = try queryRows(
            HistoryBackfillRow.self,
            """
            SELECT \(HistoryBackfillRow.columns)
            FROM history_backfills WHERE work_id=?
            """, [.text(workID.description)]
        ).first,
            let root = row.rootSnapshotID, let server = row.serverInstanceID, let epoch = row.protocolEpoch,
            let account = row.accountID, let fence = row.accountFence,
            let status = row.state.flatMap(V2BackfillStatus.init(rawValue:)),
            let received = row.receivedSnapshots else { return nil }
        return try V2BackfillState(workID: workID, rootSnapshotID: SnapshotID(rawValue: root.hexString),
                                   binding: V2AccountBinding(accountID: account, accountFence: fence,
                                                             serverInstanceID: server, protocolEpoch: epoch),
                                   resumeCursor: row.resumeCursor, status: status, receivedSnapshots: received,
                                   totalSnapshots: row.totalSnapshots, failureCode: row.failureCode)
    }

    func backfillWorkIDs() throws -> [WorkID] {
        try query("SELECT work_id FROM history_backfills WHERE state IN ('running','paused') ORDER BY updated_at").map {
            guard let id = try $0.scalar.text else { throw SyncV2StoreError.invalidLifecycle }
            return try WorkID(uuidString: id)
        }
    }

    func snapshotAvailability(workID: WorkID, snapshotID: SnapshotID, scope: V2LocalWorkScope) throws -> V2SnapshotAvailability {
        guard try scopedWorkRow(workID: workID, scope: scope) != nil else { throw SyncV2StoreError.accountMismatch }
        if try hasSnapshot(workID: workID, snapshotID: snapshotID) {
            return .local
        }
        return try hasBoundaries(workID: workID) ? .unfetched : .unknown
    }

    /// Same account/fence restart is idempotent. Foreign accounts remain parked
    /// through the existing account binding; they cannot mutate this journal.
    func resumeBackfill(workID: WorkID, binding: V2AccountBinding, manual: Bool = false) throws -> V2BackfillState? {
        try inTransaction {
            try requireNotDeleting(workID)
            guard let state = try backfillState(workID: workID) else { return nil }
            guard state.binding.accountID == binding.accountID,
                  state.binding.serverInstanceID == binding.serverInstanceID,
                  state.binding.protocolEpoch == binding.protocolEpoch,
                  try bindingIsActive(workID: workID, binding: binding) else { throw SyncV2StoreError.accountMismatch }
            guard state.status == .running || state.status == .paused || (manual && state.status == .failed) else { return nil }
            if state.binding != binding {
                try exec("UPDATE history_backfills SET account_fence=?,resume_cursor=NULL WHERE work_id=?",
                         [.text(binding.accountFence), .text(workID.description)])
            }
            try setBackfillStatus(workID: workID, binding: binding, status: .running)
            return try backfillState(workID: workID)
        }
    }

    func setBackfillStatus(workID: WorkID, binding: V2AccountBinding, status: V2BackfillStatus, failureCode: String? = nil) throws {
        try exec("""
        UPDATE history_backfills SET state=?,failure_code=?,updated_at=?
        WHERE work_id=? AND server_instance_id=? AND protocol_epoch=? AND account_id=? AND account_fence=?
        """, [.text(status.rawValue), failureCode.map(SQLiteValue.text) ?? .null, .text(Self.now()),
              .text(workID.description)] + binding.values)
    }

    func applyBackfillPage(_ page: V2BackfillPage, workID: WorkID, binding: V2AccountBinding,
                           root: SnapshotID, expectedCursor: String?) async throws {
        try Task.checkCancellation()
        let validation = Task.detached { try SnapshotValidator.validateGraphObjects(page.snapshots) }
        try await withTaskCancellationHandler {
            try await validation.value
        } onCancel: { validation.cancel() }
        try Task.checkCancellation()
        let began = ContinuousClock.now
        try inTransaction {
            try requireNotDeleting(workID)
            guard try bindingIsActive(workID: workID, binding: binding),
                  let state = try backfillState(workID: workID), state.binding == binding,
                  state.rootSnapshotID == root, state.resumeCursor == expectedCursor,
                  state.status == .running else { throw SyncV2StoreError.staleCAS }
            let anchor = try query("SELECT object_id FROM snapshot_entries WHERE snapshot_id=? AND entity_key='work/document'",
                                   [.blob(root.bytes)]).first?.scalar.blob
            try validateBackfillBudget(page.snapshots, workID: workID)
            var received: Int64 = 0
            var seen = Set<SnapshotID>()
            for snapshot in page.snapshots {
                try Task.checkCancellation()
                guard seen.insert(snapshot.snapshotId).inserted,
                      snapshot.snapshotId == SnapshotID(data: snapshot.manifestBytes),
                      snapshot.manifest.workId == workID,
                      !snapshot.manifest.parentSnapshotIds.contains(snapshot.snapshotId),
                      Set(snapshot.objects.keys) == Set(snapshot.manifest.entries.map(\.objectId)),
                      snapshot.manifest.entries.first(where: { $0.entityKey == "work/document" })?.objectId.bytes == anchor else {
                    throw SyncV2StoreError.invalidSnapshot
                }
                let existing = try hasSnapshot(workID: workID, snapshotID: snapshot.snapshotId)
                // Children precede parents. Existing ancestors can replay after a
                // fence change, but unrelated existing local snapshots cannot.
                guard try isBoundary(workID: workID, snapshotID: snapshot.snapshotId) ||
                    (existing && isAncestorOfBackfillRoot(snapshot.snapshotId, workID: workID, root: root)) else {
                    throw SyncV2StoreError.invalidSnapshot
                }
                try insertValidatedEncoded(snapshot, workID: workID, verifiedRemote: true)
                if !existing {
                    received += 1
                }
            }
            guard try !page.terminal || !hasBoundaries(workID: workID) else { throw SyncV2StoreError.invalidSnapshot }
            try exec("""
            UPDATE history_backfills SET resume_cursor=?,received_snapshots=received_snapshots+?,state=?,updated_at=?
            WHERE work_id=?
            """, [page.resumeCursor.map(SQLiteValue.text) ?? .null, .int(received),
                  .text(page.terminal ? "complete" : "running"), .text(Self.now()), .text(workID.description)])
            try Task.checkCancellation()
        }
        lastBackfillWriteDuration = began.duration(to: .now)
        registeredAncestorCache = nil
    }
}

extension LocalSyncV2Store {
    private func isAncestorOfBackfillRoot(_ id: SnapshotID, workID: WorkID, root: SnapshotID) throws -> Bool {
        try !query("""
        WITH RECURSIVE ancestors(id) AS (
          SELECT parent_snapshot_id FROM snapshot_parents WHERE work_id=? AND snapshot_id=?
          UNION SELECT p.parent_snapshot_id FROM snapshot_parents p JOIN ancestors a ON p.snapshot_id=a.id WHERE p.work_id=?
        ) SELECT 1 FROM ancestors WHERE id=? LIMIT 1
        """, [.text(workID.description), .blob(root.bytes), .text(workID.description), .blob(id.bytes)]).isEmpty
    }
}

public extension LocalSyncV2Store {
    func backfillObject(_ entry: SnapshotEntry, workID: WorkID, binding: V2AccountBinding) throws -> Data? {
        guard try bindingIsActive(workID: workID, binding: binding) else { throw SyncV2StoreError.accountMismatch }
        guard let row = try queryRows(
            ResourceBytesRow.self,
            """
            SELECT \(ResourceBytesRow.qualifiedColumns("o")) FROM objects o WHERE o.object_id=? AND EXISTS (
              SELECT 1 FROM snapshot_entries e JOIN snapshots s ON s.snapshot_id=e.snapshot_id
              WHERE s.work_id=? AND e.object_id=o.object_id)
            """, [.blob(entry.objectId.bytes), .text(workID.description)]
        ).first else { return nil }
        guard let bytes = row.bytes, row.byteCount == Int64(entry.byteCount),
              bytes.count == entry.byteCount, ObjectID(data: bytes) == entry.objectId else { throw SyncV2StoreError.invalidSnapshot }
        return bytes
    }
}

public extension LocalSyncV2Store {
    func backfillProgressNote(workID: WorkID) throws -> String? {
        guard let state = try backfillState(workID: workID), state.status != .complete else { return nil }
        if let total = state.totalSnapshots {
            return "古い履歴を取得中 \(state.receivedSnapshots.formatted()) / \(total.formatted())"
        }
        // Wire totals count objects + manifests, not snapshots. Do not present
        // that count as a snapshot total. Until a snapshot total is available,
        // show committed history bytes (the contract's MB fallback).
        let bytes = try query("""
        WITH RECURSIVE ancestors(id) AS (
          SELECT parent_snapshot_id FROM snapshot_parents WHERE work_id=? AND snapshot_id=?
          UNION SELECT p.parent_snapshot_id FROM snapshot_parents p JOIN ancestors a ON p.snapshot_id=a.id WHERE p.work_id=?
        ) SELECT (
          SELECT COALESCE(SUM(length(s.manifest_bytes)),0) FROM snapshots s JOIN ancestors a ON s.snapshot_id=a.id
        ) + (
          SELECT COALESCE(SUM(byte_count),0) FROM objects WHERE object_id IN (
            SELECT e.object_id FROM snapshot_entries e JOIN ancestors a ON e.snapshot_id=a.id
          ) AND object_id NOT IN (SELECT object_id FROM snapshot_entries WHERE snapshot_id=?)
        )
        """, [.text(workID.description), .blob(state.rootSnapshotID.bytes), .text(workID.description),
              .blob(state.rootSnapshotID.bytes)]).first?.scalar.int64 ?? 0
        return String(format: "古い履歴を取得中 %.1f MB", Double(bytes) / 1_000_000)
    }
}

extension LocalSyncV2Store {
    private func validateBackfillBudget(_ snapshots: [EncodedSnapshot], workID: WorkID) throws {
        let existing = try query("""
        SELECT DISTINCT e.object_id FROM snapshot_entries e JOIN snapshots s ON s.snapshot_id=e.snapshot_id WHERE s.work_id=?
        """, [.text(workID.description)]).compactMap { try $0.scalar.blob }
        var objects = Set(existing)
        for snapshot in snapshots {
            for entry in snapshot.manifest.entries {
                objects.insert(entry.objectId.bytes)
            }
        }
        guard objects.count <= SnapshotSyncV2Limits.maxEntries else { throw SyncV2StoreError.invalidSnapshot }
    }
}

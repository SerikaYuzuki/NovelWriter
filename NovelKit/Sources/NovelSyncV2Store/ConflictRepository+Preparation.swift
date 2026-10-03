import Foundation
import NovelCore
import NovelSyncV2

extension ConflictRepository {
    func insertKeepBothReservation(
        request: V2KeepBothPreparationRequest,
        prepared: KeepBothPreparedMaterial
    ) throws {
        try exec(
            """
            INSERT INTO pending_keep_both(
              reservation_id,source_work_id,conflict_id,conflict_revision,
              source_generation,local_candidate_snapshot_id,
              remote_snapshot_id,new_work_id,new_document_id,
              new_root_snapshot_id,expected_original_head_snapshot_id,
              expected_original_head_generation,state,created_at
            ) VALUES(?,?,?,?,?,?,?,?,?,?,?,?, 'prepared',?)
            """,
            [
                .text(prepared.reservationID.uuidString.lowercased()),
                .text(request.workID.description),
                .text(request.conflictID.uuidString.lowercased()),
                .int(request.revision), .int(request.sourceGeneration),
                .blob(request.localSnapshotID.bytes),
                .blob(request.remoteSnapshotID.bytes),
                .text(request.newWorkID.description),
                .text(request.newDocumentID.description),
                .blob(prepared.clone.snapshotIDBytes),
                .blob(prepared.originalHead.snapshotID.bytes),
                .int(prepared.originalHead.generation), .text(StoreValueCoding.now())
            ]
        )
    }

    func installRestoreHead(
        request: V2RestorePreparationRequest,
        prepared: RestorePreparedMaterial
    ) throws {
        try exec(
            """
            UPDATE works SET current_snapshot_id=?,local_generation=?
            WHERE work_id=? AND current_snapshot_id=? AND local_generation=?
            """,
            [
                .blob(prepared.result.snapshotIDBytes), .int(prepared.nextGeneration),
                .text(request.workID.description), .blob(prepared.currentBytes),
                .int(request.expectedLocalGeneration)
            ]
        )
        guard try changes() == 1 else { throw SyncV2StoreError.staleCAS }
    }

    func insertRestoreRecord(
        request: V2RestorePreparationRequest,
        scope: V2LocalWorkScope,
        prepared: RestorePreparedMaterial
    ) throws {
        let equivalent = try queryRows(
            RemoteEquivalentRow.self,
            """
            SELECT \(RemoteEquivalentRow.columns)
            FROM snapshot_remote_equivalents
            WHERE work_id=? AND local_snapshot_id=?
            """,
            [
                .text(request.workID.description),
                .blob(request.selectedSnapshotID.bytes)
            ]
        ).first
        let account: SQLiteValue = if case let .bound(binding) = scope {
            .text(binding.accountID)
        } else {
            .null
        }
        try exec(
            """
            INSERT INTO restore_records(
              restore_id,work_id,account_id,selected_snapshot_id,
              pre_restore_snapshot_id,result_snapshot_id,intent_id,
              selected_remote_equivalent_snapshot_id,
              selected_remote_equivalent_generation,
              expected_remote_head_snapshot_id,
              expected_remote_head_generation,state
            ) VALUES(?,?,?,?,?,?,?,?,?,?,?, 'prepared')
            """,
            [
                .text(prepared.restoreID.uuidString.lowercased()),
                .text(request.workID.description), account,
                .blob(request.selectedSnapshotID.bytes), .blob(prepared.currentID.bytes),
                .blob(prepared.result.snapshotIDBytes),
                .text(prepared.intentID.uuidString.lowercased()),
                equivalent?.remoteSnapshotID.map(SQLiteValue.blob) ?? .null,
                equivalent?.remoteGeneration.map(SQLiteValue.int) ?? .null,
                prepared.expectedRemoteHead.map {
                    .blob($0.snapshotID.bytes)
                } ?? .null,
                prepared.expectedRemoteHead.map { .int($0.generation) } ?? .null
            ]
        )
    }
}

extension ConflictRepository {
    func linkPreparedAction(
        _ command: SealedCommand,
        payload: SyncV2CommandPayload,
        workID: WorkID,
        intentID: UUID?
    ) throws {
        switch command.kind {
        case .restore:
            guard let intentID else { throw SyncV2StoreError.invalidCommand }
            try exec(
                """
                UPDATE restore_records SET command_id=?,state='sealed'
                WHERE intent_id=? AND state='prepared'
                """,
                [
                    .text(command.commandId.uuidString.lowercased()),
                    .text(intentID.uuidString.lowercased())
                ]
            )
        case .cloneWork:
            try exec(
                """
                UPDATE pending_keep_both SET command_id=?,state='sealed'
                WHERE source_work_id=? AND state='prepared'
                  AND local_candidate_snapshot_id=?
                  AND new_work_id=? AND new_root_snapshot_id=?
                """,
                [
                    .text(command.commandId.uuidString.lowercased()),
                    .text(workID.description),
                    .blob(payload.snapshot("localCandidateSnapshotId").bytes),
                    .text(payload.uuid("newWorkId")),
                    .blob(payload.snapshot("newRootSnapshotId").bytes)
                ]
            )
        default:
            return
        }
        guard try changes() == 1 else { throw SyncV2StoreError.invalidCommand }
    }

    func finalizeRestoreRecord(
        record: V2SealedCommandRecord,
        intentID: UUID
    ) throws {
        try exec(
            """
            UPDATE restore_records SET state='finalized'
            WHERE command_id=? AND intent_id=? AND state='sealed'
            """,
            [
                .text(record.commandID.uuidString.lowercased()),
                .text(intentID.uuidString.lowercased())
            ]
        )
        guard try changes() == 1 else {
            throw SyncV2StoreError.invalidAcknowledgement
        }
    }
}

extension ConflictRepository {
    /// Both selected and unselected branches become restorable immediately,
    /// including while the resolution command is still offline.
    func preserveConflictBranches(local: SnapshotID, generation: Int64, graph: V2RemoteSnapshotGraph) throws {
        for snapshot in try inboxRepository.topologicalSnapshots(graph) {
            try workRepository.insertEncoded(snapshot, workID: graph.workID)
        }
        for (snapshot, reason) in [(local, "conflictLocal"), (graph.headSnapshotID, "conflictRemote")] {
            try workRepository.insertHistory(workID: graph.workID, snapshotID: snapshot,
                                             reason: reason, pinned: true, generation: generation)
        }
    }

    /// Called under BEGIN IMMEDIATE. A reservation, intent, or immutable
    /// decision occurrence consumes this candidate even before command sealing.
    func requireUnpreparedConflict(
        workID: WorkID, conflictID: UUID, revision: Int64, generation: Int64,
        local: SnapshotID, remote: SnapshotID, scope: V2LocalWorkScope
    ) throws {
        let reservations = try query("""
        SELECT 1 FROM pending_keep_both WHERE source_work_id=? AND conflict_id=? AND conflict_revision=?
        """, [.text(workID.description), .text(conflictID.uuidString.lowercased()), .int(revision)])
        var intentSQL = "SELECT 1 FROM sync_intents WHERE work_id=? AND kind='conflictResolution' AND status IN ('pending','sealed')"
        intentSQL += scope.intentPredicateSQL
        let intents = try query(intentSQL, [.text(workID.description)] + scope.intentPredicateValues)
        let decisions = try query("""
        SELECT 1 FROM history_occurrences h
        WHERE h.work_id=? AND h.reason='conflictResolution' AND h.local_generation=?
          AND (SELECT COUNT(*) FROM snapshot_parents p WHERE p.work_id=h.work_id AND p.snapshot_id=h.snapshot_id)=2
          AND EXISTS (SELECT 1 FROM snapshot_parents p WHERE p.work_id=h.work_id AND p.snapshot_id=h.snapshot_id AND p.parent_snapshot_id=?)
          AND EXISTS (SELECT 1 FROM snapshot_parents p WHERE p.work_id=h.work_id AND p.snapshot_id=h.snapshot_id AND p.parent_snapshot_id=?)
        """, [.text(workID.description), .int(generation + 1), .blob(local.bytes), .blob(remote.bytes)])
        guard reservations.isEmpty, intents.isEmpty, decisions.isEmpty else {
            throw SyncV2StoreError.staleConflictAction
        }
    }

    func preparedRestore(
        _ request: V2RestorePreparationRequest,
        scope: V2LocalWorkScope
    ) throws -> V2RestorePreparationResult? {
        var scopeSQL = """
        SELECT intent_id FROM sync_intents
        WHERE work_id=? AND kind='restore' AND status='pending'
        """
        scopeSQL += scope.intentPredicateSQL
        guard let row = try queryRows(
            PreparedRestoreRow.self,
            """
            SELECT \(PreparedRestoreRow.columns)
            FROM restore_records r JOIN sync_intents i ON i.intent_id=r.intent_id
            WHERE r.work_id=? AND r.selected_snapshot_id=?
              AND i.source_snapshot_id=r.result_snapshot_id
              AND r.pre_restore_snapshot_id IN (
                SELECT snapshot_id FROM history_occurrences
                WHERE work_id=? AND local_generation=?
              )
              AND r.state='prepared' AND r.intent_id IN (\(scopeSQL))
            ORDER BY r.rowid DESC LIMIT 1
            """,
            [
                .text(request.workID.description),
                .blob(request.selectedSnapshotID.bytes),
                .text(request.workID.description),
                .int(request.expectedLocalGeneration),
                .text(request.workID.description)
            ] + scope.intentPredicateValues
        ).first,
            let restoreID = row.restoreID.flatMap(UUID.init(uuidString:)),
            let resultBytes = row.resultSnapshotID,
            let intentID = row.intentID.flatMap(UUID.init(uuidString:)),
            let generation = row.sourceGeneration,
            generation == request.expectedLocalGeneration + 1 else { return nil }
        return try V2RestorePreparationResult(
            restoreID: restoreID,
            checkpoint: V2CheckpointResult(
                snapshotID: SnapshotID(rawValue: resultBytes.hexString),
                generation: generation,
                intentID: intentID,
                noChanges: false
            ),
            expectedRemoteHead: StoreValueCoding.head(
                snapshot: row.expectedRemoteHeadSnapshotID,
                generation: row.expectedRemoteHeadGeneration
            )
        )
    }

    func acknowledgedHead(workID: WorkID) throws -> V2RemoteHead? {
        guard let row = try queryRows(
            AcknowledgedHeadRow.self,
            """
            SELECT \(AcknowledgedHeadRow.columns)
            FROM works WHERE work_id=?
            """,
            [.text(workID.description)]
        ).first else { throw SyncV2StoreError.workNotFound }
        return try StoreValueCoding.head(
            snapshot: row.acknowledgedHeadSnapshotID,
            generation: row.acknowledgedHeadGeneration
        )
    }
}

extension ConflictRepository {
    func restoreCommandSource(workID: WorkID, intentID: UUID,
                              scope: V2LocalWorkScope) throws -> V2RestoreCommandSource {
        guard try workRepository.scopedWorkRow(workID: workID, scope: scope) != nil,
              let intent = try outboxRepository.pendingIntents(scope: scope, workID: workID)
              .first(where: { $0.intentID == intentID }),
              intent.kind == "restore", intent.sourceGeneration > 1,
              let row = try queryRows(
                  RestoreCommandRow.self,
                  """
                  SELECT \(RestoreCommandRow.columns)
                  FROM restore_records WHERE work_id=? AND intent_id=? AND state='prepared'
                  """, [.text(workID.description), .text(intentID.uuidString.lowercased())]
              ).first,
              let previous = row.preRestoreSnapshotID, let selected = row.selectedSnapshotID,
              row.resultSnapshotID == intent.sourceSnapshotID.bytes else { throw SyncV2StoreError.invalidCommand }
        return try V2RestoreCommandSource(
            previousSnapshotID: SnapshotID(rawValue: previous.hexString),
            selectedSnapshotID: SnapshotID(rawValue: selected.hexString),
            restoredSnapshotID: intent.sourceSnapshotID,
            previousGeneration: intent.sourceGeneration - 1,
            expectedRemoteHead: StoreValueCoding.head(
                snapshot: row.expectedRemoteHeadSnapshotID,
                generation: row.expectedRemoteHeadGeneration
            )
        )
    }
}

struct KeepBothPreparedMaterial {
    let candidateModel: SnapshotModel
    let clone: EncodedSnapshot
    let originalHead: V2RemoteHead
    let reservationID: UUID
}

struct RestorePreparedMaterial {
    let currentBytes: Data
    let currentID: SnapshotID
    let result: EncodedSnapshot
    let intentID: UUID
    let restoreID: UUID
    let nextGeneration: Int64
    let expectedRemoteHead: V2RemoteHead?
}

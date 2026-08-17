import Foundation
import NovelSyncV2

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

extension LocalSyncV2Store {
    func persistKeepBothReservation(
        request: V2KeepBothPreparationRequest,
        scope: V2LocalWorkScope,
        prepared: KeepBothPreparedMaterial
    ) throws -> V2KeepBothReservation {
        try inTransaction {
            _ = try requireConflict(
                workID: request.workID,
                conflictID: request.conflictID,
                revision: request.revision,
                generation: request.sourceGeneration,
                local: request.localSnapshotID,
                remote: request.remoteSnapshotID,
                scope: scope
            )
            try insertWork(
                workID: request.newWorkID,
                documentID: request.newDocumentID,
                documentCreatedAt: Self.iso8601(
                    prepared.candidateModel.documentCreatedAt
                ),
                lane: .keepBothReserved,
                scope: scope
            )
            try insertEncoded(prepared.clone, workID: request.newWorkID)
            try exec(
                """
                UPDATE works SET current_snapshot_id=?,local_generation=1
                WHERE work_id=? AND local_generation=0
                """,
                [
                    .blob(prepared.clone.snapshotIDBytes),
                    .text(request.newWorkID.description)
                ]
            )
            guard try changes() == 1 else { throw SyncV2StoreError.staleCAS }
            try insertHistory(
                workID: request.newWorkID,
                snapshotID: prepared.clone.snapshotId,
                reason: V2CheckpointReason.keepBoth.rawValue,
                pinned: false,
                generation: 1
            )
            try insertKeepBothReservation(request: request, prepared: prepared)
            return V2KeepBothReservation(
                reservationID: prepared.reservationID,
                sourceWorkID: request.workID,
                newWorkID: request.newWorkID,
                newDocumentID: request.newDocumentID,
                newRootSnapshotID: prepared.clone.snapshotId,
                sourceGeneration: request.sourceGeneration,
                expectedOriginalHead: prepared.originalHead,
                state: "prepared"
            )
        }
    }

    private func insertKeepBothReservation(
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
                .int(prepared.originalHead.generation), .text(Self.now())
            ]
        )
    }

    func persistRestore(
        request: V2RestorePreparationRequest,
        scope: V2LocalWorkScope,
        prepared: RestorePreparedMaterial
    ) throws -> V2RestorePreparationResult {
        try inTransaction {
            guard let latest = try scopedWorkRow(workID: request.workID, scope: scope),
                  latest[2].int64 == request.expectedLocalGeneration,
                  latest[3].blob == prepared.currentBytes else {
                throw SyncV2StoreError.staleCAS
            }
            guard try acknowledgedHead(workID: request.workID) ==
                prepared.expectedRemoteHead else {
                throw SyncV2StoreError.staleCAS
            }
            try insertEncoded(prepared.result, workID: request.workID)
            try insertHistory(
                workID: request.workID,
                snapshotID: prepared.currentID,
                reason: "preRestore",
                pinned: true,
                generation: request.expectedLocalGeneration
            )
            try installRestoreHead(request: request, prepared: prepared)
            try insertHistory(
                workID: request.workID,
                snapshotID: prepared.result.snapshotId,
                reason: V2CheckpointReason.restore.rawValue,
                pinned: false,
                generation: prepared.nextGeneration
            )
            try insertIntent(
                intentID: prepared.intentID,
                workID: request.workID,
                snapshotID: prepared.result.snapshotId,
                generation: prepared.nextGeneration,
                kind: "restore",
                scope: scope
            )
            try insertRestoreRecord(request: request, scope: scope, prepared: prepared)
            return V2RestorePreparationResult(
                restoreID: prepared.restoreID,
                checkpoint: V2CheckpointResult(
                    snapshotID: prepared.result.snapshotId,
                    generation: prepared.nextGeneration,
                    intentID: prepared.intentID,
                    noChanges: false
                ),
                expectedRemoteHead: prepared.expectedRemoteHead
            )
        }
    }

    private func installRestoreHead(
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

    private func insertRestoreRecord(
        request: V2RestorePreparationRequest,
        scope: V2LocalWorkScope,
        prepared: RestorePreparedMaterial
    ) throws {
        let equivalent = try query(
            """
            SELECT remote_snapshot_id,remote_generation
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
                equivalent?[0].blob.map(SQLiteValue.blob) ?? .null,
                equivalent?[1].int64.map(SQLiteValue.int) ?? .null,
                prepared.expectedRemoteHead.map {
                    .blob($0.snapshotID.bytes)
                } ?? .null,
                prepared.expectedRemoteHead.map { .int($0.generation) } ?? .null
            ]
        )
    }
}

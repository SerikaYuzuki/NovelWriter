import Foundation
import NovelCore
import NovelSyncV2

/// Borrows the store executor; transaction ownership stays with LocalSyncV2Store.
struct ConflictRepository: SQLiteRepository {
    let executor: SQLiteExecutor
}

extension ConflictRepository {
    func commitConflictDelivery(
        _ material: ConflictAppendMaterial,
        scope: V2LocalWorkScope,
        remoteIdentity: (id: UUID, revision: Int64)? = nil
    ) throws -> V2ConflictCandidate {
        guard let current = try workRepository.scopedWorkRow(workID: material.workID, scope: scope),
              current.localGeneration == material.sourceGeneration,
              current.currentSnapshotID == material.localSnapshotID.bytes else {
            throw SyncV2StoreError.staleConflictAction
        }
        let graph = try inboxRepository.loadInboxGraph(
            inboxID: material.remote.inboxID,
            binding: material.binding
        )
        try validateConflictBase(
            material.baseSnapshotID,
            localSnapshotID: material.localSnapshotID,
            remoteSnapshotID: material.remote.encoded.snapshotId,
            workID: material.workID,
            graph: graph
        )
        let activeRow = try activeConflictRow(
            workID: material.workID,
            binding: material.binding
        )
        if let existing = try matchingConflict(activeRow, material: material) {
            if let remoteIdentity {
                guard existing.conflictID == remoteIdentity.id,
                      existing.revision == remoteIdentity.revision else {
                    throw SyncV2StoreError.staleConflictAction
                }
            }
            return existing
        }
        if let remoteIdentity, let activeRow {
            guard activeRow.conflictID == remoteIdentity.id.uuidString.lowercased(),
                  let previous = activeRow.currentRevision,
                  remoteIdentity.revision > previous else {
                throw SyncV2StoreError.staleConflictAction
            }
        }
        let conflictID = remoteIdentity?.id ?? activeRow?.conflictID.flatMap(UUID.init(uuidString:)) ?? UUID()
        let revision = remoteIdentity?.revision ?? (activeRow?.currentRevision ?? 0) + 1
        try persistConflictHead(
            activeRow: activeRow,
            conflictID: conflictID,
            revision: revision,
            material: material
        )
        try persistConflictCandidate(
            conflictID: conflictID,
            revision: revision,
            material: material
        )
        return conflictCandidate(
            conflictID: conflictID,
            revision: revision,
            material: material
        )
    }

    func matchingConflict(
        _ row: ConflictCandidateRow?,
        material: ConflictAppendMaterial
    ) throws -> V2ConflictCandidate? {
        guard let row,
              row.baseSnapshotID == material.baseSnapshotID?.bytes,
              row.localSnapshotID == material.localSnapshotID.bytes,
              row.remoteSnapshotID == material.remote.encoded.snapshotIDBytes,
              row.sourceGeneration == material.sourceGeneration,
              let conflictID = row.conflictID.flatMap(UUID.init(uuidString:)),
              let revision = row.currentRevision else { return nil }
        if row.remoteInboxID != material.remote.inboxID.uuidString.lowercased() {
            try exec(
                """
                UPDATE inbox_batches
                SET state='rejected',rejection_code='duplicateConflictDelivery'
                WHERE inbox_id=? AND state IN ('staged','verified')
                """,
                [.text(material.remote.inboxID.uuidString.lowercased())]
            )
        }
        return conflictCandidate(
            conflictID: conflictID,
            revision: revision,
            material: material
        )
    }

    func persistConflictHead(
        activeRow: ConflictCandidateRow?,
        conflictID: UUID,
        revision: Int64,
        material: ConflictAppendMaterial
    ) throws {
        if activeRow == nil {
            try exec(
                """
                INSERT INTO conflicts(
                  conflict_id,work_id,server_instance_id,protocol_epoch,
                  account_id,account_fence,current_revision,
                  source_generation,state
                ) VALUES(?,?,?,?,?,?,?,?, 'active')
                """,
                [
                    .text(conflictID.uuidString.lowercased()),
                    .text(material.workID.description)
                ] + material.binding.values + [
                    .int(revision),
                    .int(material.sourceGeneration)
                ]
            )
            return
        }
        try exec(
            """
            UPDATE conflicts SET current_revision=?,source_generation=?
            WHERE conflict_id=? AND work_id=? AND state='active'
              AND server_instance_id=? AND protocol_epoch=?
              AND account_id=? AND account_fence=?
            """,
            [
                .int(revision), .int(material.sourceGeneration),
                .text(conflictID.uuidString.lowercased()),
                .text(material.workID.description)
            ] + material.binding.values
        )
        guard try changes() == 1 else {
            throw SyncV2StoreError.staleConflictAction
        }
    }

    func persistConflictCandidate(
        conflictID: UUID,
        revision: Int64,
        material: ConflictAppendMaterial
    ) throws {
        try exec(
            """
            INSERT INTO conflict_candidates(
              conflict_id,work_id,revision,base_snapshot_id,
              local_snapshot_id,remote_snapshot_id,remote_inbox_id,
              source_generation,pinned
            ) VALUES(?,?,?,?,?,?,?,?,0)
            """,
            [
                .text(conflictID.uuidString.lowercased()),
                .text(material.workID.description), .int(revision),
                material.baseSnapshotID.map { .blob($0.bytes) } ?? .null,
                .blob(material.localSnapshotID.bytes),
                .blob(material.remote.encoded.snapshotIDBytes),
                .text(material.remote.inboxID.uuidString.lowercased()),
                .int(material.sourceGeneration)
            ]
        )
    }

    func conflictCandidate(
        conflictID: UUID,
        revision: Int64,
        material: ConflictAppendMaterial
    ) -> V2ConflictCandidate {
        V2ConflictCandidate(
            conflictID: conflictID,
            revision: revision,
            workID: material.workID,
            baseSnapshotID: material.baseSnapshotID,
            localSnapshotID: material.localSnapshotID,
            remoteSnapshotID: material.remote.encoded.snapshotId,
            sourceGeneration: material.sourceGeneration
        )
    }
}

extension ConflictRepository {
    func activeConflict(
        workID: WorkID,
        scope: V2LocalWorkScope
    ) throws -> V2ConflictCandidate? {
        guard case let .bound(binding) = scope,
              try workRepository.scopedWorkRow(workID: workID, scope: scope) != nil else {
            throw SyncV2StoreError.workNotFound
        }
        guard let row = try activeConflictRow(workID: workID, binding: binding),
              let conflict = row.conflictID.flatMap(UUID.init(uuidString:)),
              let revision = row.currentRevision,
              let local = row.localSnapshotID,
              let remote = row.remoteSnapshotID,
              let generation = row.sourceGeneration else { return nil }
        return try V2ConflictCandidate(
            conflictID: conflict,
            revision: revision,
            workID: workID,
            baseSnapshotID: row.baseSnapshotID.map {
                try SnapshotID(rawValue: $0.hexString)
            },
            localSnapshotID: SnapshotID(rawValue: local.hexString),
            remoteSnapshotID: SnapshotID(rawValue: remote.hexString),
            sourceGeneration: generation
        )
    }

    func keepBothReservation(
        sourceWorkID: WorkID,
        newWorkID: WorkID,
        scope: V2LocalWorkScope
    ) throws -> V2KeepBothReservation? {
        guard try workRepository.scopedWorkRow(workID: sourceWorkID, scope: scope) != nil else {
            throw SyncV2StoreError.workNotFound
        }
        return try loadKeepBothReservation(
            sourceWorkID: sourceWorkID,
            newWorkID: newWorkID
        )
    }

    func latestKeepBothReservation(
        sourceWorkID: WorkID,
        conflictID: UUID,
        scope: V2LocalWorkScope
    ) throws -> V2KeepBothReservation? {
        guard case .bound = scope else { throw SyncV2StoreError.accountMismatch }
        return try loadKeepBothReservation(sourceWorkID: sourceWorkID, conflictID: conflictID)
    }

    func loadKeepBothReservation(
        sourceWorkID: WorkID,
        newWorkID: WorkID
    ) throws -> V2KeepBothReservation? {
        guard let row = try queryRows(
            KeepBothReservationRow.self,
            """
            SELECT \(KeepBothReservationRow.columns)
            FROM pending_keep_both
            WHERE source_work_id=? AND new_work_id=?
            """,
            [.text(sourceWorkID.description), .text(newWorkID.description)]
        ).first,
            let reservation = row.reservationID.flatMap(UUID.init(uuidString:)),
            let document = row.newDocumentID,
            let root = row.newRootSnapshotID,
            let generation = row.sourceGeneration,
            let expected = try StoreValueCoding.head(
                snapshot: row.expectedOriginalHeadSnapshotID,
                generation: row.expectedOriginalHeadGeneration
            ),
            let state = row.state else { return nil }
        return try V2KeepBothReservation(
            reservationID: reservation,
            sourceWorkID: sourceWorkID,
            newWorkID: newWorkID,
            newDocumentID: DocumentID(uuidString: document),
            newRootSnapshotID: SnapshotID(rawValue: root.hexString),
            sourceGeneration: generation,
            expectedOriginalHead: expected,
            state: state
        )
    }

    func loadKeepBothReservation(
        sourceWorkID: WorkID,
        conflictID: UUID
    ) throws -> V2KeepBothReservation? {
        guard let newWork = try query(
            """
            SELECT new_work_id FROM pending_keep_both
            WHERE source_work_id=? AND conflict_id=?
            """,
            [
                .text(sourceWorkID.description),
                .text(conflictID.uuidString.lowercased())
            ]
        ).first?.scalar.text else { return nil }
        return try loadKeepBothReservation(
            sourceWorkID: sourceWorkID,
            newWorkID: WorkID(uuidString: newWork)
        )
    }

    func prepareUseServer(
        _ request: V2ServerResolutionRequest,
        scope: V2LocalWorkScope
    ) throws -> V2CheckpointResult {
        guard case let .bound(binding) = scope else { throw SyncV2StoreError.accountMismatch }
        try validateExactConflict(request, binding: binding)
        guard try inboxRepository.inboxState(inboxID: request.inboxID, binding: binding) == "verified",
              let current = try workRepository.scopedWorkRow(workID: request.workID, scope: scope),
              (current.localGeneration.map { $0 >= request.sourceGeneration } == true) else {
            throw SyncV2StoreError.staleConflictAction
        }
        let existing = try outboxRepository.pendingIntents(scope: scope, workID: request.workID)
            .first {
                $0.kind == "conflictResolution" && $0.sourceSnapshotID == request.localSnapshotID && $0
                    .sourceGeneration == request.sourceGeneration
            }
        if let existing {
            return V2CheckpointResult(
                snapshotID: existing.sourceSnapshotID,
                generation: existing.sourceGeneration,
                intentID: existing.intentID,
                noChanges: false
            )
        }
        let intentID = UUID()
        try outboxRepository.insertIntent(.init(
            intentID: intentID,
            workID: request.workID,
            snapshotID: request.localSnapshotID,
            generation: request.sourceGeneration,
            kind: "conflictResolution",
            scope: scope
        ))
        return V2CheckpointResult(
            snapshotID: request.localSnapshotID,
            generation: request.sourceGeneration,
            intentID: intentID,
            noChanges: false
        )
    }
}

struct ConflictAppendMaterial {
    let workID: WorkID
    let baseSnapshotID: SnapshotID?
    let localSnapshotID: SnapshotID
    let remote: V2RemoteSnapshot
    let sourceGeneration: Int64
    let binding: V2AccountBinding
}

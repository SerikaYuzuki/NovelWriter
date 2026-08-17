import Foundation
import NovelSyncV2

extension LocalSyncV2Store {
    func commitConflictDelivery(
        _ material: ConflictAppendMaterial,
        scope: V2LocalWorkScope
    ) throws -> V2ConflictCandidate {
        guard let current = try scopedWorkRow(workID: material.workID, scope: scope),
              current[2].int64 == material.sourceGeneration,
              current[3].blob == material.localSnapshotID.bytes else {
            throw SyncV2StoreError.staleConflictAction
        }
        let graph = try loadInboxGraph(
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
            return existing
        }
        let conflictID = activeRow?[0].text.flatMap(UUID.init(uuidString:)) ?? UUID()
        let revision = (activeRow?[1].int64 ?? 0) + 1
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

    private func matchingConflict(
        _ row: [SQLiteValue]?,
        material: ConflictAppendMaterial
    ) throws -> V2ConflictCandidate? {
        guard let row,
              row[2].blob == material.baseSnapshotID?.bytes,
              row[3].blob == material.localSnapshotID.bytes,
              row[4].blob == material.remote.encoded.snapshotIDBytes,
              row[5].int64 == material.sourceGeneration,
              let conflictID = row[0].text.flatMap(UUID.init(uuidString:)),
              let revision = row[1].int64 else { return nil }
        if row[6].text != material.remote.inboxID.uuidString.lowercased() {
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

    private func persistConflictHead(
        activeRow: [SQLiteValue]?,
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

    private func persistConflictCandidate(
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

    private func conflictCandidate(
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

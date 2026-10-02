import Foundation
import NovelCore
import NovelSyncV2

extension LocalSyncV2Store {
    func preparedDeviceResolution(
        _ request: V2DeviceResolutionRequest,
        scope: V2LocalWorkScope
    ) throws -> V2CheckpointResult? {
        var sql = """
        SELECT \(PreparedIntentRow.columns)
        FROM sync_intents
        WHERE work_id=? AND kind='conflictResolution' AND status='pending'
        """
        sql += scope.intentPredicateSQL
        sql += " ORDER BY source_generation DESC LIMIT 1"
        guard let row = try queryRows(
            PreparedIntentRow.self,
            sql,
            [.text(request.workID.description)] + scope.intentPredicateValues
        ).first,
            let intentID = row.intentID.flatMap(UUID.init(uuidString:)),
            let decisionBytes = row.sourceSnapshotID,
            let generation = row.sourceGeneration,
            generation == request.sourceGeneration + 1 else { return nil }
        let decision = try SnapshotID(rawValue: decisionBytes.hexString)
        let parents = try snapshotParents(
            workID: request.workID,
            snapshotID: decision,
            scope: scope
        )
        let expected = [request.localSnapshotID, request.remoteSnapshotID]
            .sorted { $0.rawValue < $1.rawValue }
        guard parents == expected else {
            throw SyncV2StoreError.invalidSnapshot
        }
        return V2CheckpointResult(
            snapshotID: decision,
            generation: generation,
            intentID: intentID,
            noChanges: false
        )
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
            expectedRemoteHead: Self.head(
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
        return try Self.head(
            snapshot: row.acknowledgedHeadSnapshotID,
            generation: row.acknowledgedHeadGeneration
        )
    }
}

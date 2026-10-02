import Foundation
import NovelCore
import NovelSyncV2

/// Uses the caller-owned transaction; never begins or commits one.
extension OutboxRepository {
    func hasNoPendingOrSealedIntents(workID: WorkID) throws -> Bool {
        try query("SELECT 1 FROM sync_intents WHERE work_id=? AND status IN ('pending','sealed') LIMIT 1",
                  [.text(workID.description)]).isEmpty
    }
}

extension OutboxRepository {
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

    func upsertCheckpointIntent(
        workID: WorkID,
        snapshotID: SnapshotID,
        generation: Int64,
        scope: V2LocalWorkScope
    ) throws -> UUID? {
        guard try !workRepository.isAcknowledgedContent(workID: workID, snapshotID: snapshotID, scope: scope) else {
            return nil
        }
        // Every route that queues these bytes (explicit sync, recovery,
        // account replan) promotes the leaf in the caller's transaction.
        if try workRepository.isUnpromotedLeaf(workID: workID, snapshotID: snapshotID) {
            try workRepository.insertHistory(workID: workID, snapshotID: snapshotID, reason: "promotion",
                                             pinned: true, generation: generation)
        }
        var sql = """
        SELECT intent_id FROM sync_intents
        WHERE work_id=? AND kind='checkpoint' AND status='pending'
        """
        sql += scope.intentPredicateSQL
        let values = [.text(workID.description)] + scope.intentPredicateValues
        if let text = try query(sql, values).first?.scalar.text,
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
        try insertIntent(.init(
            intentID: intentID,
            workID: workID,
            snapshotID: snapshotID,
            generation: generation,
            kind: "checkpoint",
            scope: scope
        ))
        return intentID
    }

    func insertIntent(_ insertion: IntentInsertion) throws {
        let intentID = insertion.intentID
        let workID = insertion.workID
        let snapshotID = insertion.snapshotID
        let generation = insertion.generation
        let kind = insertion.kind
        let scope = insertion.scope

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
            ] + fields + [.text(StoreValueCoding.now())]
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
        ).first?.scalar.text.flatMap(UUID.init(uuidString:))
    }
}

extension OutboxRepository {
    func pendingIntents(
        scope: V2LocalWorkScope,
        workID: WorkID? = nil
    ) throws -> [V2PendingIntent] {
        var sql = """
        SELECT \(IntentRow.columns)
        FROM sync_intents
        WHERE status IN ('pending','sealed')
          -- A publish that already received conflictPending is immutable
          -- evidence, not an actionable retry. Its resolution intent (a
          -- different row) remains visible and is selected explicitly.
          AND NOT EXISTS (
            SELECT 1 FROM sealed_commands blocked
            WHERE blocked.intent_id=sync_intents.intent_id
              AND blocked.command_kind='publish'
              AND blocked.status='conflictPending'
          )
        """
        sql += scope.intentPredicateSQL
        var values = scope.intentPredicateValues
        if let workID {
            sql += " AND work_id=?"
            values.append(.text(workID.description))
        }
        sql += " ORDER BY CASE WHEN kind='conflictResolution' THEN 0 ELSE 1 END, work_id,source_generation, rowid"
        return try queryRows(
            IntentRow.self,
            sql, values
        ).map(OutboxRepository.pendingIntent)
    }
}

extension OutboxRepository {
    func automaticSyncCandidate(
        workID: WorkID, scope: V2LocalWorkScope
    ) throws -> (generation: Int64, head: V2RemoteHead)? {
        guard case .bound = scope,
              let row = try workRepository.scopedWorkRow(workID: workID, scope: scope),
              let generation = row.localGeneration,
              row.syncLane == V2SyncLane.normal.rawValue,
              try conflictRepository.activeConflict(workID: workID, scope: scope) == nil,
              try pendingIntents(scope: scope, workID: workID).isEmpty,
              let head = try conflictRepository.acknowledgedHead(workID: workID) else { return nil }
        return (generation, head)
    }
}

extension OutboxRepository {
    func retryInitialCreateWork(workID: WorkID, scope: V2LocalWorkScope) throws {
        let records = try allSealedCommands(scope: scope, workID: workID)
        guard !records.isEmpty,
              records.allSatisfy({ $0.kind == .createWork && $0.lifecycle == .quarantined }),
              let first = records.first else { return }
        try transitionCommand(commandID: first.commandID, scope: scope, from: ["quarantined"], to: "sealed")
    }

    func retryQuarantinedPublish(workID: WorkID, scope: V2LocalWorkScope) throws {
        let intents = try pendingIntents(scope: scope, workID: workID)
        guard let intent = intents.first, intent.status == "sealed" else { return }
        let records = try allSealedCommands(scope: scope, workID: workID)
        guard let command = records.first(where: {
            $0.kind == .publish && $0.lifecycle == .quarantined &&
                $0.intentID == intent.intentID && $0.sourceSnapshotID == intent.sourceSnapshotID &&
                $0.sourceGeneration == intent.sourceGeneration
        }) else { return }
        try transitionCommand(commandID: command.commandID, scope: scope, from: ["quarantined"], to: "sealed")
    }
}

extension OutboxRepository {
    func recordCommandFailureReason(commandID: UUID, reason: String) throws {
        let id = commandID.uuidString.lowercased()
        try exec("""
        INSERT INTO quarantine_records(quarantine_id,work_id,account_id,reason,evidence_bytes,created_at)
        SELECT command_id,work_id,account_id,?,X'',? FROM sealed_commands WHERE command_id=?
        ON CONFLICT(quarantine_id) DO UPDATE SET reason=excluded.reason
        """, [.text("command:" + reason), .text(StoreValueCoding.iso8601(Date())), .text(id)])
    }

    func quarantinedCommandReason(workID: WorkID, scope: V2LocalWorkScope) throws -> String? {
        guard case let .bound(binding) = scope,
              try workRepository.scopedWorkRow(workID: workID, scope: scope) != nil else {
            throw SyncV2StoreError.accountMismatch
        }
        let reason = try query("""
        SELECT q.reason FROM sealed_commands c JOIN quarantine_records q ON q.quarantine_id=c.command_id
        WHERE c.work_id=? AND c.server_instance_id=? AND c.protocol_epoch=?
          AND c.account_id=? AND c.account_fence=? AND c.status='quarantined'
          AND q.reason LIKE 'command:%' ORDER BY q.created_at LIMIT 1
        """, [.text(workID.description)] + binding.values).first?.scalar.text
        return reason.map { String($0.dropFirst("command:".count)) }
    }
}

extension OutboxRepository {
    func oldestUnreceivedChange(workID: WorkID, scope: V2LocalWorkScope) throws -> Date? {
        let rows = try query("""
        SELECT MIN(created_at) FROM sync_intents
        WHERE work_id=? AND scope_kind='bound'
          AND status IN ('pending','sealed','quarantined','parked')
          AND NOT EXISTS (SELECT 1 FROM intent_subsumptions s WHERE s.intent_id=sync_intents.intent_id)
        """ + scope.intentPredicateSQL, [.text(workID.description)] + scope.intentPredicateValues)
        guard let text = try rows.first?.scalar.text else { return nil }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let value = formatter.date(from: text) {
            return value
        }
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: text) ?? .distantFuture
    }
}

extension OutboxRepository {
    func planningGuardCommands(
        scope: V2LocalWorkScope,
        workID: WorkID
    ) throws -> [V2SealedCommandRecord] {
        guard case let .bound(binding) = scope else { throw SyncV2StoreError.accountMismatch }
        return try queryRows(
            SealedCommandRow.self,
            OutboxRepository.commandSelect + """
             WHERE work_id=? AND server_instance_id=? AND protocol_epoch=?
               AND account_id=? AND account_fence=?
               AND (command_kind='createWork' OR status='quarantined') ORDER BY rowid
            """,
            [.text(workID.description)] + binding.values
        ).map(OutboxRepository.commandRecord)
    }

    func completedTransferCommands(
        scope: V2LocalWorkScope,
        workID: WorkID,
        snapshotID: SnapshotID,
        generation: Int64
    ) throws -> [V2SealedCommandRecord] {
        guard case let .bound(binding) = scope else { throw SyncV2StoreError.accountMismatch }
        return try queryRows(
            SealedCommandRow.self,
            OutboxRepository.commandSelect + """
             WHERE work_id=? AND server_instance_id=? AND protocol_epoch=?
               AND account_id=? AND account_fence=? AND status='completed'
               AND source_snapshot_id=? AND source_generation=? ORDER BY rowid
            """,
            [.text(workID.description)] + binding.values + [.blob(snapshotID.bytes), .int(generation)]
        ).map(OutboxRepository.commandRecord)
    }
}

/// Uses the caller-owned transaction; never begins or commits one.
extension OutboxRepository {
    func quarantineRejectedIntentInTransaction(intentID: UUID) throws {
        try exec("UPDATE sync_intents SET status='quarantined' WHERE intent_id=? AND status='sealed'",
                 [.text(intentID.uuidString.lowercased())])
        guard try changes() == 1 else { throw SyncV2StoreError.invalidCommand }
    }
}

/// Values for the same immutable intent insertion, kept separate from its SQL executor.
struct IntentInsertion {
    let intentID: UUID
    let workID: WorkID
    let snapshotID: SnapshotID
    let generation: Int64
    let kind: String
    let scope: V2LocalWorkScope
}

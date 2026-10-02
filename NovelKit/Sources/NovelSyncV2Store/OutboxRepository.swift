import Foundation
import NovelCore
import NovelSyncV2

/// Borrows the store executor; transaction ownership stays with LocalSyncV2Store.
struct OutboxRepository: SQLiteRepository {
    let executor: SQLiteExecutor
}

extension OutboxRepository {
    func allSealedCommands(
        scope: V2LocalWorkScope,
        workID: WorkID
    ) throws -> [V2SealedCommandRecord] {
        guard case let .bound(binding) = scope else { throw SyncV2StoreError.accountMismatch }
        return try queryRows(
            SealedCommandRow.self,
            OutboxRepository.commandSelect + """
             WHERE work_id=? AND server_instance_id=? AND protocol_epoch=?
               AND account_id=? AND account_fence=? ORDER BY rowid
            """,
            [.text(workID.description)] + binding.values
        ).map(OutboxRepository.commandRecord)
    }

    func pendingSealedCommands(
        scope: V2LocalWorkScope,
        workID: WorkID? = nil
    ) throws -> [V2SealedCommandRecord] {
        guard case let .bound(binding) = scope else {
            throw SyncV2StoreError.accountMismatch
        }
        var sql = OutboxRepository.commandSelect + """
         WHERE server_instance_id=? AND protocol_epoch=?
           AND account_id=? AND account_fence=?
           AND status IN ('sealed','sending')
        """
        var values = binding.values
        if let workID {
            sql += " AND work_id=?"
            values.append(.text(workID.description))
        }
        sql += " ORDER BY rowid"
        return try queryRows(
            SealedCommandRow.self,
            sql, values
        ).map(OutboxRepository.commandRecord)
    }

    func markSending(
        commandID: UUID,
        scope: V2LocalWorkScope
    ) throws -> V2SealedCommandRecord {
        guard case let .bound(binding) = scope else {
            throw SyncV2StoreError.accountMismatch
        }
        try exec(
            """
            UPDATE sealed_commands SET status='sending'
            WHERE command_id=? AND server_instance_id=? AND protocol_epoch=?
              AND account_id=? AND account_fence=? AND status='sealed'
              AND EXISTS (
                SELECT 1 FROM account_bindings b
                WHERE b.work_id=sealed_commands.work_id
                  AND b.server_instance_id=sealed_commands.server_instance_id
                  AND b.protocol_epoch=sealed_commands.protocol_epoch
                  AND b.account_id=sealed_commands.account_id
                  AND b.account_fence=sealed_commands.account_fence
                  AND b.state='bound'
              )
            """,
            [.text(commandID.uuidString.lowercased())] + binding.values
        )
        guard let record = try sealedRecord(commandID: commandID, binding: binding),
              record.lifecycle == .sending else {
            throw SyncV2StoreError.invalidLifecycle
        }
        return record
    }

    func requeue(
        commandID: UUID,
        scope: V2LocalWorkScope
    ) throws {
        try transitionCommand(
            commandID: commandID,
            scope: scope,
            from: ["sending"],
            to: "sealed"
        )
    }

    func park(
        commandID: UUID,
        scope: V2LocalWorkScope
    ) throws {
        try transitionCommand(
            commandID: commandID,
            scope: scope,
            from: ["sealed", "sending", "conflictPending"],
            to: "parked"
        )
    }

    func receiptReadback(
        commandID: UUID,
        scope: V2LocalWorkScope
    ) throws -> V2ReceiptReadback? {
        guard case let .bound(binding) = scope else {
            throw SyncV2StoreError.accountMismatch
        }
        guard try commandBindingIsActive(commandID: commandID, binding: binding) else {
            throw SyncV2StoreError.accountMismatch
        }
        guard let row = try queryRows(
            ReceiptRow.self,
            """
            SELECT \(ReceiptRow.columns)
            FROM remote_receipts
            WHERE account_id=? AND command_id=? AND work_id IN (
              SELECT work_id FROM sealed_commands
              WHERE command_id=? AND server_instance_id=? AND protocol_epoch=?
                AND account_id=? AND account_fence=?
            )
            """,
            [
                .text(binding.accountID), .text(commandID.uuidString.lowercased()),
                .text(commandID.uuidString.lowercased())
            ] + binding.values
        ).first else { return nil }
        return try OutboxRepository.receipt(commandID: commandID, row: row)
    }

    func validatePublishNoChangesGraph(
        inboxID: UUID,
        record: V2SealedCommandRecord,
        acknowledgement: DecodedCommandAcknowledgement,
        binding: V2AccountBinding
    ) throws {
        guard acknowledgement.result == .noChanges,
              let remoteHead = acknowledgement.remoteHead else {
            throw SyncV2StoreError.invalidAcknowledgement
        }
        let graph = try inboxRepository.loadInboxGraph(inboxID: inboxID, binding: binding)
        guard try inboxRepository.inboxState(inboxID: inboxID, binding: binding) == "verified",
              graph.workID == record.workID,
              graph.headSnapshotID == remoteHead.snapshotID,
              graph.expectedRemoteHead == remoteHead,
              graph.expectedRemoteHead?.generation == remoteHead.generation else {
            throw SyncV2StoreError.invalidAcknowledgement
        }
        let command = try SealedCommand.decodeCanonical(record.canonicalRequest)
        let payload = command.payload
        let candidate = try payload.snapshot("candidateSnapshotId")
        guard candidate == record.sourceSnapshotID,
              try conflictRepository.graphHead(graph, containsAncestor: candidate) else {
            throw SyncV2StoreError.invalidAcknowledgement
        }
        _ = try inboxRepository.validateGraph(graph)
        try inboxRepository.validateGraphParents(graph)
    }
}

extension OutboxRepository {
    func retryUnacknowledgedCommandsTransaction(
        workID: WorkID,
        scope: V2LocalWorkScope,
        legacyOnly: Bool = false
    ) throws {
        guard case let .bound(binding) = scope,
              let work = try workRepository.scopedWorkRow(workID: workID, scope: scope) else {
            throw SyncV2StoreError.accountMismatch
        }
        guard work.syncLane == V2SyncLane.normal.rawValue,
              try deletionRepository.workDeletion(workID: workID) == nil else { return }
        // Automatic recovery also requires an unconsumed upgrade candidate.
        // Manual sync may retry a new response-less unexpected failure.
        // A response/receipt, existing prepare transfer or any other reason
        // keeps automatic recovery blocked. Explicit sync has separate manual retries.
        let rows = try query("""
        SELECT c.command_id FROM sealed_commands c
        JOIN quarantine_records q ON q.quarantine_id=c.command_id
        WHERE c.work_id=? AND c.server_instance_id=? AND c.protocol_epoch=?
          AND c.account_id=? AND c.account_fence=? AND c.status='quarantined'
          AND c.command_kind IN ('createWork','prepareObject','finalizeObject','registerSnapshot',
                                'publish','resolveDevice','resolveServer','cloneWork','restore')
          AND (?=0 OR EXISTS (SELECT 1 FROM legacy_command_recovery l
                              WHERE l.command_id=c.command_id AND l.consumed=0))
          AND q.reason='command:unexpected' AND length(q.evidence_bytes)=0
          AND c.canonical_response IS NULL AND c.response_status IS NULL AND c.receipt_verified=0
          AND NOT EXISTS (SELECT 1 FROM remote_receipts r WHERE r.command_id=c.command_id)
          AND NOT EXISTS (SELECT 1 FROM upload_transfers u WHERE u.command_id=c.command_id)
        """, [.text(workID.description)] + binding.values + [.int(legacyOnly ? 1 : 0)])
        for row in rows {
            guard let raw = try row.scalar.text, let id = UUID(uuidString: raw) else {
                throw SyncV2StoreError.invalidCommand
            }
            try transitionCommand(commandID: id, scope: scope, from: ["quarantined"], to: "sealed")
        }
    }
}

extension OutboxRepository {
    static func pendingIntent(_ row: IntentRow) throws -> V2PendingIntent {
        guard let intent = row.intentID.flatMap(UUID.init(uuidString:)),
              let work = row.workID,
              let snapshot = row.sourceSnapshotID,
              let generation = row.sourceGeneration,
              let kind = row.kind,
              let status = row.status else {
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
}

extension OutboxRepository {
    static let validUploadTransferLifecycles: Set<String> = [
        "prepared", "sending", "acknowledged", "quarantined", "parked"
    ]
}

extension OutboxRepository {
    static let commandSelect = """
    SELECT \(SealedCommandRow.columns)
    FROM sealed_commands
    """

    static func commandRecord(_ row: SealedCommandRow) throws -> V2SealedCommandRecord {
        guard let commandID = row.commandID.flatMap(UUID.init(uuidString:)),
              let work = row.workID,
              let account = row.accountID,
              let fence = row.accountFence,
              let server = row.serverInstanceID,
              let epoch = row.protocolEpoch,
              let kind = row.commandKind,
              let request = row.canonicalRequest,
              let digest = row.requestDigest,
              let snapshot = row.sourceSnapshotID,
              let generation = row.sourceGeneration,
              let statusText = row.status,
              let status = V2SealedCommandLifecycle(rawValue: statusText) else {
            throw SyncV2StoreError.sqlite("command")
        }
        return try V2SealedCommandRecord(
            commandID: commandID,
            workID: WorkID(uuidString: work),
            intentID: row.intentID.flatMap(UUID.init(uuidString:)),
            binding: V2AccountBinding(
                accountID: account,
                accountFence: fence,
                serverInstanceID: server,
                protocolEpoch: epoch
            ),
            commandKind: kind,
            canonicalRequest: request,
            requestDigest: ObjectID(rawValue: digest.hexString),
            sourceSnapshotID: SnapshotID(rawValue: snapshot.hexString),
            sourceGeneration: generation,
            lifecycle: status
        )
    }

    static func receipt(commandID: UUID, row: ReceiptRow) throws -> V2ReceiptReadback {
        guard let resultText = row.terminalResult,
              let result = V2CommandTerminalResult(rawValue: resultText),
              let status = row.responseStatus,
              let response = row.canonicalResponse else {
            throw SyncV2StoreError.sqlite("receipt")
        }
        return try V2ReceiptReadback(
            commandID: commandID,
            result: result,
            responseStatus: Int(status),
            canonicalResponse: response,
            predicates: V2ReadBackPredicates(
                accountMatched: row.accountMatched == 1,
                commandDigestMatched: row.commandDigestMatched == 1,
                resourceMatched: row.resourceMatched == 1,
                headMatched: row.headMatched == 1,
                stateMatched: row.stateMatched == 1
            ),
            remoteHead: StoreValueCoding.head(snapshot: row.remoteHeadSnapshotID, generation: row.remoteHeadGeneration),
            cloneRemoteHead: StoreValueCoding.head(
                snapshot: row.cloneHeadSnapshotID,
                generation: row.cloneHeadGeneration
            )
        )
    }
}

struct CommandValidationContext {
    let command: SealedCommand
    let payload: SyncV2CommandPayload
    let workID: WorkID
    let intentID: UUID?
    let work: WorkRow
}

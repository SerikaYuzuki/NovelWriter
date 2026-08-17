import Foundation
import NovelSyncV2

public extension LocalSyncV2Store {
    func seal(
        _ command: SealedCommand,
        intentID: UUID? = nil,
        scope: V2LocalWorkScope
    ) throws {
        guard case let .bound(binding) = scope,
              command.binding.accountId == binding.accountID,
              command.binding.accountFence == binding.accountFence,
              command.binding.serverInstanceId == binding.serverInstanceID,
              command.binding.protocolEpoch == binding.protocolEpoch,
              SealedCommand.requestDigest(for: command.canonicalBytes) == command.requestDigest,
              SealedCommand.isCanonical(command.canonicalBytes) else {
            throw SyncV2StoreError.invalidCommand
        }
        let payload = try command.payloadDictionary()
        let workID = try commandWorkID(command.commandKind, payload: payload)
        guard try scopedWorkRow(workID: workID, scope: scope) != nil else {
            throw SyncV2StoreError.accountMismatch
        }
        if let existing = try sealedRecord(
            commandID: command.commandId,
            binding: binding
        ) {
            guard existing.canonicalRequest == command.canonicalBytes,
                  existing.requestDigest == command.requestDigest,
                  existing.workID == workID,
                  existing.intentID == intentID else {
                throw SyncV2StoreError.commandAlreadySealed
            }
            return
        }

        let intentRequired = Set(["publish", "resolveDevice", "restore"])
        guard intentRequired.contains(command.commandKind) == (intentID != nil) else {
            throw SyncV2StoreError.invalidCommand
        }
        try persistSealedCommand(
            command,
            payload: payload,
            workID: workID,
            scope: scope,
            binding: binding,
            intentID: intentID
        )
    }

    func pendingSealedCommands(
        scope: V2LocalWorkScope,
        workID: WorkID? = nil
    ) throws -> [V2SealedCommandRecord] {
        guard case let .bound(binding) = scope else {
            throw SyncV2StoreError.accountMismatch
        }
        var sql = Self.commandSelect + """
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
        return try query(sql, values).map(Self.commandRecord)
    }

    @discardableResult
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

    func quarantine(
        commandID: UUID,
        scope: V2LocalWorkScope
    ) throws {
        try transitionCommand(
            commandID: commandID,
            scope: scope,
            from: ["sealed", "sending", "conflictPending"],
            to: "quarantined"
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
        guard let row = try query(
            """
            SELECT terminal_result,response_status,canonical_response,
                   command_matched,digest_matched,resource_matched,head_matched,
                   remote_head_snapshot_id,remote_head_generation,
                   clone_head_snapshot_id,clone_head_generation
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
        return try Self.receipt(commandID: commandID, row: row)
    }

    func acknowledge(
        _ acknowledgement: V2CommandAcknowledgement,
        scope: V2LocalWorkScope
    ) throws {
        guard case let .bound(binding) = scope else {
            throw SyncV2StoreError.accountMismatch
        }
        try CanonicalJSON.validate(acknowledgement.canonicalResponse)
        guard let record = try sealedRecord(
            commandID: acknowledgement.commandID,
            binding: binding
        ) else { throw SyncV2StoreError.invalidCommand }

        if let existing = try receiptReadback(
            commandID: acknowledgement.commandID,
            scope: scope
        ) {
            try validateDuplicateReceipt(existing, acknowledgement: acknowledgement)
            return
        }
        guard [.sealed, .sending, .conflictPending].contains(record.lifecycle) else {
            throw SyncV2StoreError.invalidLifecycle
        }

        if acknowledgement.result == .retryable {
            try requeueRetryableAcknowledgement(
                acknowledgement,
                record: record,
                binding: binding
            )
            return
        }
        guard acknowledgement.responseStatus >= 100,
              acknowledgement.responseStatus <= 599,
              acknowledgement.predicates.allVerified else {
            throw SyncV2StoreError.invalidAcknowledgement
        }
        try inTransaction {
            try persistTerminalAcknowledgement(
                acknowledgement,
                record: record,
                binding: binding
            )
        }
    }
}

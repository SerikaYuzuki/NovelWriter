import Foundation
import NovelSyncV2

public extension LocalSyncV2Store {
    func allSealedCommands(
        scope: V2LocalWorkScope,
        workID: WorkID
    ) throws -> [V2SealedCommandRecord] {
        try outboxRepository.allSealedCommands(scope: scope, workID: workID)
    }

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
        let payload = command.payload
        let workID = try payload.workID
        guard try workRepository.scopedWorkRow(workID: workID, scope: scope) != nil else {
            throw SyncV2StoreError.accountMismatch
        }
        if let existing = try outboxRepository.sealedRecord(
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

        let intentRequired: Set<SyncV2CommandKind> = [.publish, .resolveDevice, .restore]
        let intentCapable = intentRequired.union([.resolveServer, .cloneWork])
        guard (intentRequired.contains(command.kind) && intentID != nil) ||
            (!intentRequired.contains(command.kind) &&
                (intentID == nil || intentCapable.contains(command.kind))) else {
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
        try outboxRepository.pendingSealedCommands(scope: scope, workID: workID)
    }

    @discardableResult
    func markSending(
        commandID: UUID,
        scope: V2LocalWorkScope
    ) throws -> V2SealedCommandRecord {
        try preservingCheckpointValidation {
            try outboxRepository.markSending(commandID: commandID, scope: scope)
        }
    }

    func requeue(
        commandID: UUID,
        scope: V2LocalWorkScope
    ) throws {
        try preservingCheckpointValidation {
            try outboxRepository.requeue(commandID: commandID, scope: scope)
        }
    }

    func quarantine(
        commandID: UUID,
        scope: V2LocalWorkScope,
        reason: String? = nil
    ) throws {
        try inCheckpointNeutralTransaction {
            try outboxRepository.transitionCommand(
                commandID: commandID, scope: scope,
                from: ["sealed", "sending", "conflictPending"], to: "quarantined"
            )
            if let reason {
                try outboxRepository.recordCommandFailureReason(commandID: commandID, reason: reason)
            }
        }
    }

    func park(
        commandID: UUID,
        scope: V2LocalWorkScope
    ) throws {
        try preservingCheckpointValidation {
            try outboxRepository.park(commandID: commandID, scope: scope)
        }
    }

    func receiptReadback(
        commandID: UUID,
        scope: V2LocalWorkScope
    ) throws -> V2ReceiptReadback? {
        try outboxRepository.receiptReadback(commandID: commandID, scope: scope)
    }

    func acknowledge(
        _ acknowledgement: V2CommandAcknowledgement,
        scope: V2LocalWorkScope,
        verifiedPublishInboxID: UUID? = nil
    ) throws {
        guard case let .bound(binding) = scope else {
            throw SyncV2StoreError.accountMismatch
        }
        guard try outboxRepository.commandBindingIsActive(
            commandID: acknowledgement.commandID,
            binding: binding
        ) else {
            throw SyncV2StoreError.accountMismatch
        }
        guard let record = try outboxRepository.sealedRecord(
            commandID: acknowledgement.commandID,
            binding: binding
        ) else { throw SyncV2StoreError.invalidCommand }
        let decoded = try outboxRepository.decodeAcknowledgement(
            acknowledgement,
            record: record
        )

        if let existing = try outboxRepository.receiptReadback(
            commandID: acknowledgement.commandID,
            scope: scope
        ) {
            try outboxRepository.validateDuplicateReceipt(existing, acknowledgement: decoded)
            return
        }
        guard [.sealed, .sending, .conflictPending].contains(record.lifecycle) else {
            throw SyncV2StoreError.invalidLifecycle
        }

        guard decoded.predicates.allVerified else {
            throw SyncV2StoreError.invalidAcknowledgement
        }
        let preservesContent = [.createWork, .prepareObject, .finalizeObject, .registerSnapshot, .publish].contains(record.kind)
        try inTransaction(preservingCheckpoint: preservesContent) {
            if decoded.result == .noChanges, record.kind == .publish {
                guard let verifiedPublishInboxID else {
                    throw SyncV2StoreError.invalidAcknowledgement
                }
                try outboxRepository.validatePublishNoChangesGraph(
                    inboxID: verifiedPublishInboxID,
                    record: record,
                    acknowledgement: decoded,
                    binding: binding
                )
            }
            try outboxRepository.persistTerminalAcknowledgement(
                decoded,
                record: record,
                binding: binding
            )
        }
    }
}

extension LocalSyncV2Store {
    func persistSealedCommand(
        _ command: SealedCommand,
        payload: SyncV2CommandPayload,
        workID: WorkID,
        scope: V2LocalWorkScope,
        binding: V2AccountBinding,
        intentID: UUID?
    ) throws {
        let preservesContent = [.createWork, .prepareObject, .finalizeObject, .registerSnapshot, .publish].contains(command.kind)
        try inTransaction(preservingCheckpoint: preservesContent) {
            try outboxRepository.validateCommandSource(
                command,
                payload: payload,
                workID: workID,
                scope: scope,
                intentID: intentID
            )
            try outboxRepository.insertSealedCommand(
                command,
                workID: workID,
                binding: binding,
                intentID: intentID
            )
            if let intentID {
                try outboxRepository.sealIntent(intentID)
            }
            try conflictRepository.linkPreparedAction(
                command,
                payload: payload,
                workID: workID,
                intentID: intentID
            )
        }
    }
}

public extension LocalSyncV2Store {
    /// Upgrade recovery runs before the normal wake scans its pending lanes.
    /// No intent, source generation, command ID, digest or request is replaced.
    func retryUnacknowledgedCommands(scope: V2LocalWorkScope) throws {
        guard case .bound = scope else { throw SyncV2StoreError.accountMismatch }
        try inCheckpointNeutralTransaction {
            for work in try workRepository.listWorks(scope: scope) {
                try outboxRepository.retryUnacknowledgedCommandsTransaction(
                    workID: work.workID,
                    scope: scope,
                    legacyOnly: true
                )
            }
        }
    }

    func retryUnacknowledgedCommands(workID: WorkID, scope: V2LocalWorkScope) throws {
        try inCheckpointNeutralTransaction { try outboxRepository.retryUnacknowledgedCommandsTransaction(
            workID: workID,
            scope: scope,
            legacyOnly: true
        ) }
    }
}

public extension LocalSyncV2Store {
    /// Queue only unreceived content; the application reads remote updates for
    /// already received current snapshots without creating another publish.
    /// Existing durable commands keep their identity and retry ordering.
    func requestSynchronization(workID: WorkID, scope: V2LocalWorkScope) throws {
        guard case .bound = scope else { throw SyncV2StoreError.accountMismatch }
        try inCheckpointNeutralTransaction {
            guard let row = try workRepository.scopedWorkRow(workID: workID, scope: scope),
                  let generation = row.localGeneration,
                  let snapshot = row.currentSnapshotID,
                  row.syncLane == V2SyncLane.normal.rawValue else {
                throw SyncV2StoreError.accountMismatch
            }
            _ = try workRepository.promoteCurrentLeafTransaction(workID: workID, scope: scope)
            try outboxRepository.retryQuarantinedUploads(workID: workID, scope: scope)
            try outboxRepository.retryInitialCreateWork(workID: workID, scope: scope)
            try outboxRepository.retryQuarantinedPublish(workID: workID, scope: scope)
            try outboxRepository.retryUnacknowledgedCommandsTransaction(workID: workID, scope: scope)
            guard try outboxRepository.pendingIntents(scope: scope, workID: workID).isEmpty else { return }
            _ = try outboxRepository.upsertCheckpointIntent(
                workID: workID,
                snapshotID: SnapshotID(rawValue: snapshot.hexString),
                generation: generation,
                scope: scope
            )
        }
    }
}

public extension LocalSyncV2Store {
    /// Metadata-only read: periodic checks never decode every work on the shelf.
    func automaticSyncCandidate(
        workID: WorkID, scope: V2LocalWorkScope
    ) throws -> (generation: Int64, head: V2RemoteHead)? {
        try outboxRepository.automaticSyncCandidate(workID: workID, scope: scope)
    }

    /// A head check may race a local checkpoint. Queue only the exact clean
    /// generation inspected by that check; never retry a quarantined command.
    func requestAutomaticSynchronization(
        workID: WorkID, scope: V2LocalWorkScope, expectedLocalGeneration: Int64
    ) throws -> Bool {
        guard case .bound = scope else { return false }
        return try inCheckpointNeutralTransaction {
            guard let row = try workRepository.scopedWorkRow(workID: workID, scope: scope),
                  row.localGeneration == expectedLocalGeneration,
                  let snapshot = row.currentSnapshotID,
                  row.syncLane == V2SyncLane.normal.rawValue,
                  try conflictRepository.activeConflict(workID: workID, scope: scope) == nil,
                  try outboxRepository.pendingIntents(scope: scope, workID: workID).isEmpty,
                  try outboxRepository.allSealedCommands(scope: scope, workID: workID).allSatisfy({
                      $0.lifecycle == .completed || $0.sourceGeneration < expectedLocalGeneration
                  }) else { return false }
            _ = try workRepository.promoteCurrentLeafTransaction(workID: workID, scope: scope)
            let intent = try outboxRepository.upsertCheckpointIntent(
                workID: workID, snapshotID: SnapshotID(rawValue: snapshot.hexString),
                generation: expectedLocalGeneration, scope: scope
            )
            return intent != nil
        }
    }
}

public extension LocalSyncV2Store {
    func quarantinedCommandReason(workID: WorkID, scope: V2LocalWorkScope) throws -> String? {
        try outboxRepository.quarantinedCommandReason(workID: workID, scope: scope)
    }
}

public extension LocalSyncV2Store {
    /// The first unreceived intent survives coalescing and process restarts.
    func oldestUnreceivedChange(workID: WorkID, scope: V2LocalWorkScope) throws -> Date? {
        try outboxRepository.oldestUnreceivedChange(workID: workID, scope: scope)
    }
}

public extension LocalSyncV2Store {
    /// Called only for the server's exact pre-commit lineage rejection. Keep
    /// old command bytes and its intent as evidence; checkpoint data is retained.
    func replanRejectedPublish(commandID: UUID, scope: V2LocalWorkScope) throws {
        guard case let .bound(binding) = scope else { throw SyncV2StoreError.accountMismatch }
        try inCheckpointNeutralTransaction {
            guard let record = try outboxRepository.sealedRecord(commandID: commandID, binding: binding),
                  record.kind == .publish, record.lifecycle == .sending,
                  let intentID = record.intentID,
                  try outboxRepository.receiptReadback(commandID: commandID, scope: scope) == nil,
                  let row = try workRepository.scopedWorkRow(workID: record.workID, scope: scope),
                  let current = row.currentSnapshotID, let generation = row.localGeneration else {
                throw SyncV2StoreError.invalidCommand
            }
            let command = try SealedCommand.decodeCanonical(record.canonicalRequest)
            let payload = command.payload
            guard try payload.remoteHead("expectedRemoteHead") !=
                workRepository.publishBaseHead(workID: record.workID, snapshotID: record.sourceSnapshotID) else {
                throw SyncV2StoreError.invalidCommand
            }
            try outboxRepository.transitionCommand(
                commandID: commandID,
                scope: scope,
                from: ["sending"],
                to: "quarantined"
            )
            try outboxRepository.quarantineRejectedIntentInTransaction(intentID: intentID)
            _ = try outboxRepository.upsertCheckpointIntent(workID: record.workID,
                                                            snapshotID: SnapshotID(rawValue: current.hexString),
                                                            generation: generation, scope: scope)
        }
    }
}

public extension LocalSyncV2Store {
    func persistUploadTransfer(
        _ transfer: V2UploadTransferRecord,
        scope: V2LocalWorkScope
    ) throws {
        guard case let .bound(binding) = scope,
              OutboxRepository.validUploadTransferLifecycles.contains(transfer.lifecycle),
              transfer.objectID == ObjectID(data: transfer.exactBytes),
              transfer.bytesDigest == ObjectID(data: transfer.exactBytes),
              transfer.sourceGeneration > 0,
              transfer.acknowledgedOffset >= 0,
              transfer.acknowledgedOffset <= transfer.exactBytes.count,
              transfer.objectID.bytes.count == 32,
              transfer.sourceSnapshotID.bytes.count == 32,
              transfer.bytesDigest.bytes.count == 32 else {
            throw SyncV2StoreError.invalidCommand
        }
        try inCheckpointNeutralTransaction {
            try outboxRepository.persistUploadTransferInTransaction(transfer, binding: binding)
        }
    }

    func uploadTransfer(
        commandID: UUID,
        scope: V2LocalWorkScope
    ) throws -> V2UploadTransferRecord? {
        try outboxRepository.uploadTransfer(commandID: commandID, scope: scope)
    }

    func acknowledgeUploadTransfer(
        transferID: UUID,
        byteCount: Int,
        scope: V2LocalWorkScope
    ) throws {
        try preservingCheckpointValidation {
            try outboxRepository.acknowledgeUploadTransfer(transferID: transferID, byteCount: byteCount, scope: scope)
        }
    }
}

public extension LocalSyncV2Store {
    func quarantineUpload(transferID: UUID, workID: WorkID, reason: String, scope: V2LocalWorkScope) throws {
        guard case let .bound(binding) = scope else { throw SyncV2StoreError.accountMismatch }
        try inCheckpointNeutralTransaction {
            guard try workRepository.scopedWorkRow(workID: workID, scope: scope) != nil else {
                throw SyncV2StoreError.accountMismatch
            }
            try outboxRepository.quarantineUploadInTransaction(
                transferID: transferID,
                workID: workID,
                reason: reason,
                binding: binding
            )
        }
    }

    func quarantinedUploadReason(workID: WorkID, scope: V2LocalWorkScope) throws -> String? {
        try outboxRepository.quarantinedUploadReason(workID: workID, scope: scope)
    }
}

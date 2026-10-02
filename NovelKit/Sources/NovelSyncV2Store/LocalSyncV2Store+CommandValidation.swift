import Foundation
import NovelSyncV2

private struct CommandValidationContext {
    let command: SealedCommand
    let payload: SyncV2CommandPayload
    let workID: WorkID
    let intentID: UUID?
    let work: WorkRow
}

extension LocalSyncV2Store {
    static let commandSelect = """
    SELECT \(SealedCommandRow.columns)
    FROM sealed_commands
    """

    func sealedRecord(
        commandID: UUID,
        binding: V2AccountBinding
    ) throws -> V2SealedCommandRecord? {
        try queryRows(
            SealedCommandRow.self,
            Self.commandSelect + """
             WHERE command_id=? AND server_instance_id=? AND protocol_epoch=?
               AND account_id=? AND account_fence=?
            """,
            [.text(commandID.uuidString.lowercased())] + binding.values
        ).first.map(Self.commandRecord)
    }

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

    func transitionCommand(
        commandID: UUID,
        scope: V2LocalWorkScope,
        from: [String],
        to: String
    ) throws {
        guard case let .bound(binding) = scope else {
            throw SyncV2StoreError.accountMismatch
        }
        let placeholders = from.map { _ in "?" }.joined(separator: ",")
        try exec(
            """
            UPDATE sealed_commands SET status=?
            WHERE command_id=? AND server_instance_id=? AND protocol_epoch=?
              AND account_id=? AND account_fence=?
              AND status IN (\(placeholders))
            """,
            [.text(to), .text(commandID.uuidString.lowercased())] +
                binding.values + from.map(SQLiteValue.text)
        )
        guard try changes() == 1 else { throw SyncV2StoreError.invalidLifecycle }
        if from.contains("quarantined"), to == "sealed" {
            // Explicit and automatic release both consume the upgrade candidate.
            // These releases run inside their caller's transaction.
            try exec("UPDATE legacy_command_recovery SET consumed=1 WHERE command_id=?",
                     [.text(commandID.uuidString.lowercased())])
        }
    }

    func validateCommandSource(
        _ command: SealedCommand,
        payload: SyncV2CommandPayload,
        workID: WorkID,
        scope: V2LocalWorkScope,
        intentID: UUID?
    ) throws {
        guard let work = try scopedWorkRow(workID: workID, scope: scope),
              try !query(
                  """
                  SELECT 1 FROM history_occurrences
                  WHERE work_id=? AND snapshot_id=? AND local_generation=?
                  """,
                  [
                      .text(workID.description), .blob(command.sourceSnapshotId.bytes),
                      .int(command.sourceGeneration)
                  ]
              ).isEmpty else { throw SyncV2StoreError.invalidCommand }
        let context = CommandValidationContext(
            command: command,
            payload: payload,
            workID: workID,
            intentID: intentID,
            work: work
        )
        if intentID != nil,
           ![.publish, .resolveDevice, .resolveServer, .cloneWork, .restore].contains(command.kind) {
            throw SyncV2StoreError.invalidCommand
        }
        switch command.kind {
        case .createWork:
            try validateCreateWork(context)
        case .prepareObject, .finalizeObject:
            try validateObjectCommand(context)
        case .registerSnapshot:
            try validateRegisterSnapshot(context)
        case .publish:
            try validatePublish(context)
        case .resolveDevice:
            try validateResolveDevice(context)
        case .resolveServer:
            try validateResolveServer(context)
        case .cloneWork:
            try validateCloneWork(context)
        case .restore:
            try validateRestore(context)
        }
    }

    private func requireCurrent(
        _ context: CommandValidationContext,
        snapshotID: SnapshotID,
        generation: Int64
    ) throws {
        guard context.work.localGeneration == generation,
              context.work.currentSnapshotID == snapshotID.bytes else {
            throw SyncV2StoreError.invalidCommand
        }
    }

    private func requireCurrentAtLeast(
        _ context: CommandValidationContext,
        generation: Int64
    ) throws {
        guard context.work.localGeneration.map({ $0 >= generation }) == true else {
            throw SyncV2StoreError.invalidCommand
        }
    }

    private func requireIntent(
        _ context: CommandValidationContext,
        snapshotID: SnapshotID,
        generation: Int64,
        kind: String
    ) throws {
        let binding = V2AccountBinding(
            accountID: context.command.binding.accountId,
            accountFence: context.command.binding.accountFence,
            serverInstanceID: context.command.binding.serverInstanceId,
            protocolEpoch: context.command.binding.protocolEpoch
        )
        guard let intentID = context.intentID,
              let intent = try queryRows(
                  IntentValidationRow.self,
                  """
                  SELECT \(IntentValidationRow.columns)
                  FROM sync_intents
                  WHERE intent_id=? AND server_instance_id=? AND protocol_epoch=?
                    AND account_id=? AND account_fence=?
                  """,
                  [.text(intentID.uuidString.lowercased())] + binding.values
              ).first,
              intent.workID == context.workID.description,
              intent.sourceSnapshotID == snapshotID.bytes,
              intent.sourceGeneration == generation,
              intent.kind == kind,
              intent.status == "pending" else {
            throw SyncV2StoreError.invalidCommand
        }
    }

    private func validateCreateWork(_ context: CommandValidationContext) throws {
        try requireCurrent(
            context,
            snapshotID: context.command.sourceSnapshotId,
            generation: context.command.sourceGeneration
        )
        guard try context.payload.uuid("documentId") == context.work.documentID else {
            throw SyncV2StoreError.invalidCommand
        }
    }

    private func validateObjectCommand(_ context: CommandValidationContext) throws {
        try requireCurrentAtLeast(
            context,
            generation: context.command.sourceGeneration
        )
        let object = try context.payload.object("objectId")
        guard let row = try query(
            """
            SELECT o.byte_count FROM snapshot_entries e
            JOIN objects o ON o.object_id=e.object_id
            WHERE e.snapshot_id=? AND e.object_id=? LIMIT 1
            """,
            [.blob(context.command.sourceSnapshotId.bytes), .blob(object.bytes)]
        ).first,
            try row.scalar.int64 == context.payload.integer("byteCount") else {
            throw SyncV2StoreError.invalidCommand
        }
    }

    private func validateRegisterSnapshot(_ context: CommandValidationContext) throws {
        try requireCurrentAtLeast(
            context,
            generation: context.command.sourceGeneration
        )
        let snapshot = try context.payload.snapshot("snapshotId")
        let digest = try context.payload.snapshot("manifestBytesDigest")
        guard snapshot == context.command.sourceSnapshotId,
              digest == snapshot,
              let base64 = context.payload.string("manifestBase64URL"),
              let manifest = Data(base64URLEncoded: base64),
              SnapshotID(data: manifest) == snapshot,
              try loadEncoded(
                  workID: context.workID,
                  snapshotID: snapshot
              ).manifestBytes == manifest else {
            throw SyncV2StoreError.invalidCommand
        }
    }

    private func validatePublish(_ context: CommandValidationContext) throws {
        let binding = V2AccountBinding(
            accountID: context.command.binding.accountId,
            accountFence: context.command.binding.accountFence,
            serverInstanceID: context.command.binding.serverInstanceId,
            protocolEpoch: context.command.binding.protocolEpoch
        )
        let conflictRow = try activeConflictRow(workID: context.workID, binding: binding)
        if conflictRow != nil {
            throw SyncV2StoreError.staleConflictAction
        }
        let currentMatches = try publishSourceIsCurrentOrStableParent(
            command: context.command, workID: context.workID, work: context.work
        )
        let candidateMatches = try context.payload.snapshot("candidateSnapshotId") ==
            context.command.sourceSnapshotId
        let headMatches = try context.payload.remoteHead("expectedRemoteHead") ==
            publishBaseHead(workID: context.workID, snapshotID: context.command.sourceSnapshotId)
        let intentMatches: Bool
        do {
            try requireIntent(
                context,
                snapshotID: context.command.sourceSnapshotId,
                generation: context.command.sourceGeneration,
                kind: "checkpoint"
            )
            intentMatches = true
        } catch {
            intentMatches = false
        }
        guard currentMatches, candidateMatches, headMatches, intentMatches else {
            throw SyncV2StoreError.invalidCommand
        }
    }

    private func validateResolveDevice(_ context: CommandValidationContext) throws {
        let decision = try context.payload.snapshot("decisionSnapshotId")
        try requireIntent(
            context,
            snapshotID: decision,
            generation: context.command.sourceGeneration + 1,
            kind: "conflictResolution"
        )
        guard try context.payload.snapshot("localCandidateSnapshotId") ==
            context.command.sourceSnapshotId else {
            throw SyncV2StoreError.invalidCommand
        }
        try validateConflictPayload(context.payload, workID: context.workID)
        try validateConflictCandidateSnapshots(
            workID: context.workID,
            local: context.command.sourceSnapshotId
        )
        let binding = try activeBinding(workID: context.workID)
        guard let active = try activeConflict(
            workID: context.workID,
            scope: .bound(binding)
        ),
            try snapshotParents(
                workID: context.workID,
                snapshotID: decision,
                scope: .bound(binding)
            ) == [active.localSnapshotID, active.remoteSnapshotID].sorted(by: {
                $0.rawValue < $1.rawValue
            }) else {
            throw SyncV2StoreError.invalidCommand
        }
        try validateConflictExpectedHead(context.payload, workID: context.workID)
    }

    private func validateResolveServer(_ context: CommandValidationContext) throws {
        try requireCurrentAtLeast(context, generation: context.command.sourceGeneration)
        guard try context.payload.snapshot("preAdoptionSnapshotId") ==
            context.command.sourceSnapshotId,
            try context.payload.snapshot("expectedCurrentSnapshotId") ==
            context.command.sourceSnapshotId,
            context.payload.integer("expectedLocalGeneration") ==
            context.command.sourceGeneration else {
            throw SyncV2StoreError.invalidCommand
        }
        try validateConflictPayload(context.payload, workID: context.workID)
        try validateConflictCandidateSnapshots(
            workID: context.workID,
            local: context.command.sourceSnapshotId,
            remote: context.payload.snapshot("remoteSnapshotId")
        )
    }

    private func validateCloneWork(_ context: CommandValidationContext) throws {
        let newWorkID = try WorkID(uuidString: context.payload.uuid("newWorkId"))
        let localCandidate = try context.payload.snapshot("localCandidateSnapshotId")
        let binding = V2AccountBinding(
            accountID: context.command.binding.accountId,
            accountFence: context.command.binding.accountFence,
            serverInstanceID: context.command.binding.serverInstanceId,
            protocolEpoch: context.command.binding.protocolEpoch
        )
        let active = try activeConflict(workID: context.workID, scope: .bound(binding))
        let reservation = try loadKeepBothReservation(
            sourceWorkID: context.workID,
            newWorkID: newWorkID
        )
        let newRootSnapshotID = try context.payload.snapshot("newRootSnapshotId")
        let newDocumentID = try context.payload.uuid("newDocumentId")
        let expected = try context.payload.remoteHead("expectedOriginalHead")
        let stored = try reservationExpectedHead(
            sourceWorkID: context.workID,
            newWorkID: newWorkID
        )
        guard let active,
              localCandidate == active.localSnapshotID,
              let reservation,
              reservation.newRootSnapshotID == newRootSnapshotID,
              reservation.newDocumentID.description == newDocumentID,
              let expected,
              let stored,
              expected == stored else {
            throw SyncV2StoreError.invalidCommand
        }
        try validateConflictPayload(context.payload, workID: context.workID)
        try validateConflictCandidateSnapshots(
            workID: context.workID,
            local: localCandidate
        )
    }

    private func validateRestore(_ context: CommandValidationContext) throws {
        let result = try context.payload.snapshot("newSnapshotId")
        let selected = try context.payload.snapshot("selectedSnapshotId")
        try requireIntent(
            context,
            snapshotID: result,
            generation: context.command.sourceGeneration + 1,
            kind: "restore"
        )
        guard try context.payload.snapshot("expectedCurrentSnapshotId") ==
            context.command.sourceSnapshotId,
            context.payload.integer("expectedLocalGeneration") ==
            context.command.sourceGeneration,
            let intentID = context.intentID,
            let restore = try queryRows(
                RestoreExpectedHeadRow.self,
                """
                SELECT \(RestoreExpectedHeadRow.columns)
                FROM restore_records
                WHERE intent_id=? AND result_snapshot_id=?
                  AND pre_restore_snapshot_id=? AND selected_snapshot_id=?
                  AND state='prepared'
                """,
                [
                    .text(intentID.uuidString.lowercased()),
                    .blob(result.bytes), .blob(context.command.sourceSnapshotId.bytes),
                    .blob(selected.bytes)
                ]
            ).first,
            try Self.head(
                snapshot: restore.expectedRemoteHeadSnapshotID,
                generation: restore.expectedRemoteHeadGeneration
            ) == context.payload.remoteHead("expectedRemoteHead") else {
            throw SyncV2StoreError.invalidCommand
        }
    }

    func validateConflictPayload(_ payload: SyncV2CommandPayload, workID: WorkID) throws {
        let conflictID = try payload.uuid("conflictId")
        let revision = payload.integer("conflictRevision")
        guard let active = try activeConflict(workID: workID, scope: .bound(
            activeBinding(workID: workID)
        )),
            active.conflictID.uuidString.lowercased() == conflictID,
            active.revision == revision else {
            throw SyncV2StoreError.staleConflictAction
        }
    }

    func validateConflictCandidateSnapshots(
        workID: WorkID,
        local: SnapshotID,
        remote: SnapshotID? = nil
    ) throws {
        guard let active = try activeConflict(
            workID: workID,
            scope: .bound(activeBinding(workID: workID))
        ),
            active.localSnapshotID == local,
            remote == nil || active.remoteSnapshotID == remote else {
            throw SyncV2StoreError.staleConflictAction
        }
    }

    func validateConflictExpectedHead(
        _ payload: SyncV2CommandPayload,
        workID: WorkID
    ) throws {
        guard let expected = try payload.remoteHead("expectedRemoteHead"),
              let row = try activeConflictRow(
                  workID: workID,
                  binding: activeBinding(workID: workID)
              ),
              let inbox = row.remoteInboxID.flatMap(UUID.init(uuidString:)),
              try loadInboxGraph(
                  inboxID: inbox,
                  binding: activeBinding(workID: workID)
              ).expectedRemoteHead == expected else {
            throw SyncV2StoreError.invalidCommand
        }
    }

    func expectedHeadMatchesWork(
        payload: SyncV2CommandPayload,
        key: String,
        workID: WorkID
    ) throws -> Bool {
        let expected = try payload.remoteHead(key)
        guard let row = try queryRows(
            AcknowledgedHeadRow.self,
            """
            SELECT \(AcknowledgedHeadRow.columns)
            FROM works WHERE work_id=?
            """,
            [.text(workID.description)]
        ).first else { return false }
        return try Self.head(
            snapshot: row.acknowledgedHeadSnapshotID,
            generation: row.acknowledgedHeadGeneration
        ) == expected
    }

    func reservationExpectedHead(
        sourceWorkID: WorkID,
        newWorkID: WorkID
    ) throws -> V2RemoteHead? {
        guard let row = try queryRows(
            ReservationExpectedHeadRow.self,
            """
            SELECT \(ReservationExpectedHeadRow.columns)
            FROM pending_keep_both
            WHERE source_work_id=? AND new_work_id=?
            """,
            [.text(sourceWorkID.description), .text(newWorkID.description)]
        ).first else { return nil }
        return try Self.head(
            snapshot: row.expectedOriginalHeadSnapshotID,
            generation: row.expectedOriginalHeadGeneration
        )
    }

    func activeBinding(workID: WorkID) throws -> V2AccountBinding {
        guard let row = try queryRows(
            ActiveAccountBindingRow.self,
            """
            SELECT \(ActiveAccountBindingRow.columns)
            FROM account_bindings WHERE work_id=? AND state='bound'
            """,
            [.text(workID.description)]
        ).first,
            let account = row.accountID,
            let fence = row.accountFence,
            let server = row.serverInstanceID,
            let epoch = row.protocolEpoch else {
            throw SyncV2StoreError.accountMismatch
        }
        return V2AccountBinding(
            accountID: account,
            accountFence: fence,
            serverInstanceID: server,
            protocolEpoch: epoch
        )
    }

    func validateMonotonicHead(workID: WorkID, newHead: V2RemoteHead?) throws {
        guard let newHead,
              let row = try queryRows(
                  AcknowledgedHeadRow.self,
                  """
                  SELECT \(AcknowledgedHeadRow.columns)
                  FROM works WHERE work_id=?
                  """,
                  [.text(workID.description)]
              ).first,
              let oldGeneration = row.acknowledgedHeadGeneration else { return }
        // A delayed receipt may be older than the already acknowledged head.
        // It remains valid for its exact command/intent, but must not regress
        // the stored remote head. Equal-generation forks are still rejected.
        guard newHead.generation >= oldGeneration else { return }
        if newHead.generation == oldGeneration,
           row.acknowledgedHeadSnapshotID != newHead.snapshotID.bytes {
            throw SyncV2StoreError.invalidRemoteHead
        }
    }

    func receiptLocalSnapshot(_ record: V2SealedCommandRecord) throws -> SnapshotID {
        guard let intentID = record.intentID else { return record.sourceSnapshotID }
        guard let bytes = try query(
            """
            SELECT source_snapshot_id FROM sync_intents
            WHERE intent_id=? AND work_id=? AND server_instance_id=?
              AND protocol_epoch=? AND account_id=? AND account_fence=?
            """,
            [
                .text(intentID.uuidString.lowercased()),
                .text(record.workID.description)
            ] + record.binding.values
        ).first?.scalar.blob else { throw SyncV2StoreError.invalidAcknowledgement }
        return try SnapshotID(rawValue: bytes.hexString)
    }

    func applyRemoteHead(_ head: V2RemoteHead, workID: WorkID) throws {
        if let row = try queryRows(
            AcknowledgedHeadRow.self,
            """
            SELECT \(AcknowledgedHeadRow.columns)
            FROM works WHERE work_id=?
            """,
            [.text(workID.description)]
        ).first {
            if let oldGeneration = row.acknowledgedHeadGeneration {
                if head.generation < oldGeneration {
                    return
                }
                if head.generation == oldGeneration {
                    guard row.acknowledgedHeadSnapshotID == head.snapshotID.bytes else {
                        throw SyncV2StoreError.invalidRemoteHead
                    }
                    return
                }
            }
        }
        try exec(
            """
            UPDATE works SET acknowledged_head_snapshot_id=?,
                             acknowledged_head_generation=?
            WHERE work_id=? AND (
              acknowledged_head_generation IS NULL OR
              acknowledged_head_generation<? OR
              (acknowledged_head_generation=? AND acknowledged_head_snapshot_id=?)
            )
            """,
            [
                .blob(head.snapshotID.bytes), .int(head.generation),
                .text(workID.description), .int(head.generation),
                .int(head.generation), .blob(head.snapshotID.bytes)
            ]
        )
        guard try changes() == 1 else { throw SyncV2StoreError.invalidRemoteHead }
    }

    func insertReceipt(
        _ acknowledgement: DecodedCommandAcknowledgement,
        record: V2SealedCommandRecord,
        binding: V2AccountBinding
    ) throws {
        try exec(
            """
            INSERT INTO remote_receipts(
              account_id,work_id,command_id,command_kind,request_digest,
              response_status,canonical_response,terminal_result,
              account_matched,command_digest_matched,resource_matched,
              head_matched,state_matched,
              remote_head_snapshot_id,remote_head_generation,
              clone_head_snapshot_id,clone_head_generation
            ) VALUES(?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)
            """,
            [
                .text(binding.accountID), .text(record.workID.description),
                .text(record.commandID.uuidString.lowercased()),
                .text(record.commandKind), .blob(record.requestDigest.bytes),
                .int(Int64(acknowledgement.responseStatus)),
                .blob(acknowledgement.canonicalResponse),
                .text(acknowledgement.result.rawValue),
                .int(acknowledgement.predicates.accountMatched ? 1 : 0),
                .int(acknowledgement.predicates.commandDigestMatched ? 1 : 0),
                .int(acknowledgement.predicates.resourceMatched ? 1 : 0),
                .int(acknowledgement.predicates.headMatched ? 1 : 0),
                .int(acknowledgement.predicates.stateMatched ? 1 : 0),
                acknowledgement.remoteHead.map { .blob($0.snapshotID.bytes) } ?? .null,
                acknowledgement.remoteHead.map { .int($0.generation) } ?? .null,
                acknowledgement.cloneRemoteHead.map {
                    .blob($0.snapshotID.bytes)
                } ?? .null,
                acknowledgement.cloneRemoteHead.map { .int($0.generation) } ?? .null
            ]
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
            remoteHead: head(snapshot: row.remoteHeadSnapshotID, generation: row.remoteHeadGeneration),
            cloneRemoteHead: head(snapshot: row.cloneHeadSnapshotID, generation: row.cloneHeadGeneration)
        )
    }

    static func head(snapshot: Data?, generation: Int64?) throws -> V2RemoteHead? {
        guard let snapshot, let generation else { return nil }
        return try V2RemoteHead(
            snapshotID: SnapshotID(rawValue: snapshot.hexString),
            generation: generation
        )
    }
}

extension SyncV2CommandPayload {
    func remoteHead(_ key: String) throws -> V2RemoteHead? {
        try head(key).map { try V2RemoteHead(snapshotID: $0.snapshotID, generation: $0.generation) }
    }
}

private extension Data {
    init?(base64URLEncoded text: String) {
        var base64 = text.replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        base64 += String(repeating: "=", count: (4 - base64.count % 4) % 4)
        self.init(base64Encoded: base64)
    }
}

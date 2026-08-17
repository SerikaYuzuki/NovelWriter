import Foundation
import NovelSyncV2

private struct CommandValidationContext {
    let command: SealedCommand
    let payload: [String: Any]
    let workID: WorkID
    let intentID: UUID?
    let work: [SQLiteValue]
}

extension LocalSyncV2Store {
    static let commandSelect = """
    SELECT command_id,work_id,intent_id,account_id,account_fence,
           server_instance_id,protocol_epoch,command_kind,canonical_request,
           request_digest,source_snapshot_id,source_generation,status
    FROM sealed_commands
    """

    func sealedRecord(
        commandID: UUID,
        binding: V2AccountBinding
    ) throws -> V2SealedCommandRecord? {
        try query(
            Self.commandSelect + """
             WHERE command_id=? AND server_instance_id=? AND protocol_epoch=?
               AND account_id=? AND account_fence=?
            """,
            [.text(commandID.uuidString.lowercased())] + binding.values
        ).first.map(Self.commandRecord)
    }

    static func commandRecord(_ row: [SQLiteValue]) throws -> V2SealedCommandRecord {
        guard let commandID = row[0].text.flatMap(UUID.init(uuidString:)),
              let work = row[1].text,
              let account = row[3].text,
              let fence = row[4].text,
              let server = row[5].text,
              let epoch = row[6].int64,
              let kind = row[7].text,
              let request = row[8].blob,
              let digest = row[9].blob,
              let snapshot = row[10].blob,
              let generation = row[11].int64,
              let statusText = row[12].text,
              let status = V2SealedCommandLifecycle(rawValue: statusText) else {
            throw SyncV2StoreError.sqlite("command")
        }
        return try V2SealedCommandRecord(
            commandID: commandID,
            workID: WorkID(uuidString: work),
            intentID: row[2].text.flatMap(UUID.init(uuidString:)),
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
    }

    func validateCommandSource(
        _ command: SealedCommand,
        payload: [String: Any],
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
           !["publish", "resolveDevice", "resolveServer", "cloneWork", "restore"].contains(command.commandKind) {
            throw SyncV2StoreError.invalidCommand
        }
        switch command.commandKind {
        case "createWork":
            try validateCreateWork(context)
        case "prepareObject", "finalizeObject":
            try validateObjectCommand(context)
        case "registerSnapshot":
            try validateRegisterSnapshot(context)
        case "publish":
            try validatePublish(context)
        case "resolveDevice":
            try validateResolveDevice(context)
        case "resolveServer":
            try validateResolveServer(context)
        case "cloneWork":
            try validateCloneWork(context)
        case "restore":
            try validateRestore(context)
        default:
            throw SyncV2StoreError.invalidCommand
        }
    }

    private func requireCurrent(
        _ context: CommandValidationContext,
        snapshotID: SnapshotID,
        generation: Int64
    ) throws {
        guard context.work[2].int64 == generation,
              context.work[3].blob == snapshotID.bytes else {
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
              let intent = try query(
                  """
                  SELECT work_id,source_snapshot_id,source_generation,kind,status
                  FROM sync_intents
                  WHERE intent_id=? AND server_instance_id=? AND protocol_epoch=?
                    AND account_id=? AND account_fence=?
                  """,
                  [.text(intentID.uuidString.lowercased())] + binding.values
              ).first,
              intent[0].text == context.workID.description,
              intent[1].blob == snapshotID.bytes,
              intent[2].int64 == generation,
              intent[3].text == kind,
              intent[4].text == "pending" else {
            throw SyncV2StoreError.invalidCommand
        }
    }

    private func validateCreateWork(_ context: CommandValidationContext) throws {
        try requireCurrent(
            context,
            snapshotID: context.command.sourceSnapshotId,
            generation: context.command.sourceGeneration
        )
        guard try context.payload.uuid("documentId") == context.work[1].text else {
            throw SyncV2StoreError.invalidCommand
        }
    }

    private func validateObjectCommand(_ context: CommandValidationContext) throws {
        try requireCurrent(
            context,
            snapshotID: context.command.sourceSnapshotId,
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
            row[0].int64 == (context.payload["byteCount"] as? NSNumber)?.int64Value else {
            throw SyncV2StoreError.invalidCommand
        }
    }

    private func validateRegisterSnapshot(_ context: CommandValidationContext) throws {
        try requireCurrent(
            context,
            snapshotID: context.command.sourceSnapshotId,
            generation: context.command.sourceGeneration
        )
        let snapshot = try context.payload.snapshot("snapshotId")
        let digest = try context.payload.snapshot("manifestBytesDigest")
        guard snapshot == context.command.sourceSnapshotId,
              digest == snapshot,
              let base64 = context.payload["manifestBase64URL"] as? String,
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
        guard try activeConflictRow(
            workID: context.workID,
            binding: binding
        ) == nil else {
            throw SyncV2StoreError.staleConflictAction
        }
        try requireCurrent(
            context,
            snapshotID: context.command.sourceSnapshotId,
            generation: context.command.sourceGeneration
        )
        try requireIntent(
            context,
            snapshotID: context.command.sourceSnapshotId,
            generation: context.command.sourceGeneration,
            kind: "checkpoint"
        )
        guard try context.payload.snapshot("candidateSnapshotId") ==
            context.command.sourceSnapshotId,
            try expectedHeadMatchesWork(
                payload: context.payload,
                key: "expectedRemoteHead",
                workID: context.workID
            ) else { throw SyncV2StoreError.invalidCommand }
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
        try requireCurrent(
            context,
            snapshotID: context.command.sourceSnapshotId,
            generation: context.command.sourceGeneration
        )
        guard try context.payload.snapshot("preAdoptionSnapshotId") ==
            context.command.sourceSnapshotId,
            try context.payload.snapshot("expectedCurrentSnapshotId") ==
            context.command.sourceSnapshotId,
            (context.payload["expectedLocalGeneration"] as? NSNumber)?.int64Value ==
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
        guard try context.payload.snapshot("localCandidateSnapshotId") ==
            context.command.sourceSnapshotId,
            let reservation = try loadKeepBothReservation(
                sourceWorkID: context.workID,
                newWorkID: newWorkID
            ),
            try reservation.newRootSnapshotID ==
            context.payload.snapshot("newRootSnapshotId"),
            try reservation.newDocumentID.description ==
            context.payload.uuid("newDocumentId"),
            let expected = try context.payload.remoteHead("expectedOriginalHead"),
            let stored = try reservationExpectedHead(
                sourceWorkID: context.workID,
                newWorkID: newWorkID
            ),
            expected == stored else {
            throw SyncV2StoreError.invalidCommand
        }
        try validateConflictPayload(context.payload, workID: context.workID)
        try validateConflictCandidateSnapshots(
            workID: context.workID,
            local: context.command.sourceSnapshotId
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
            (context.payload["expectedLocalGeneration"] as? NSNumber)?.int64Value ==
            context.command.sourceGeneration,
            let intentID = context.intentID,
            let restore = try query(
                """
                SELECT expected_remote_head_snapshot_id,
                       expected_remote_head_generation
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
                snapshot: restore[0].blob,
                generation: restore[1].int64
            ) == context.payload.remoteHead("expectedRemoteHead") else {
            throw SyncV2StoreError.invalidCommand
        }
    }

    func validateConflictPayload(_ payload: [String: Any], workID: WorkID) throws {
        let conflictID = try payload.uuid("conflictId")
        let revision = (payload["conflictRevision"] as? NSNumber)?.int64Value
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
        _ payload: [String: Any],
        workID: WorkID
    ) throws {
        guard let expected = try payload.remoteHead("expectedRemoteHead"),
              let row = try activeConflictRow(
                  workID: workID,
                  binding: activeBinding(workID: workID)
              ),
              let inbox = row[6].text.flatMap(UUID.init(uuidString:)),
              try loadInboxGraph(
                  inboxID: inbox,
                  binding: activeBinding(workID: workID)
              ).expectedRemoteHead == expected else {
            throw SyncV2StoreError.invalidCommand
        }
    }

    func expectedHeadMatchesWork(
        payload: [String: Any],
        key: String,
        workID: WorkID
    ) throws -> Bool {
        let expected = try payload.remoteHead(key)
        guard let row = try query(
            """
            SELECT acknowledged_head_snapshot_id,acknowledged_head_generation
            FROM works WHERE work_id=?
            """,
            [.text(workID.description)]
        ).first else { return false }
        return try Self.head(snapshot: row[0].blob, generation: row[1].int64) == expected
    }

    func reservationExpectedHead(
        sourceWorkID: WorkID,
        newWorkID: WorkID
    ) throws -> V2RemoteHead? {
        guard let row = try query(
            """
            SELECT expected_original_head_snapshot_id,
                   expected_original_head_generation
            FROM pending_keep_both
            WHERE source_work_id=? AND new_work_id=?
            """,
            [.text(sourceWorkID.description), .text(newWorkID.description)]
        ).first else { return nil }
        return try Self.head(snapshot: row[0].blob, generation: row[1].int64)
    }

    func activeBinding(workID: WorkID) throws -> V2AccountBinding {
        guard let row = try query(
            """
            SELECT account_id,account_fence,server_instance_id,protocol_epoch
            FROM account_bindings WHERE work_id=? AND state='bound'
            """,
            [.text(workID.description)]
        ).first,
            let account = row[0].text,
            let fence = row[1].text,
            let server = row[2].text,
            let epoch = row[3].int64 else {
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
              let row = try query(
                  """
                  SELECT acknowledged_head_snapshot_id,acknowledged_head_generation
                  FROM works WHERE work_id=?
                  """,
                  [.text(workID.description)]
              ).first,
              let oldGeneration = row[1].int64 else { return }
        // A delayed receipt may be older than the already acknowledged head.
        // It remains valid for its exact command/intent, but must not regress
        // the stored remote head. Equal-generation forks are still rejected.
        guard newHead.generation >= oldGeneration else { return }
        if newHead.generation == oldGeneration,
           row[0].blob != newHead.snapshotID.bytes {
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
        ).first?[0].blob else { throw SyncV2StoreError.invalidAcknowledgement }
        return try SnapshotID(rawValue: bytes.hexString)
    }

    func applyRemoteHead(_ head: V2RemoteHead, workID: WorkID) throws {
        if let row = try query(
            """
            SELECT acknowledged_head_snapshot_id,acknowledged_head_generation
            FROM works WHERE work_id=?
            """,
            [.text(workID.description)]
        ).first {
            if let oldGeneration = row[1].int64 {
                if head.generation < oldGeneration {
                    return
                }
                if head.generation == oldGeneration {
                    guard row[0].blob == head.snapshotID.bytes else {
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

    static func receipt(commandID: UUID, row: [SQLiteValue]) throws -> V2ReceiptReadback {
        guard let resultText = row[0].text,
              let result = V2CommandTerminalResult(rawValue: resultText),
              let status = row[1].int64,
              let response = row[2].blob else {
            throw SyncV2StoreError.sqlite("receipt")
        }
        return try V2ReceiptReadback(
            commandID: commandID,
            result: result,
            responseStatus: Int(status),
            canonicalResponse: response,
            predicates: V2ReadBackPredicates(
                accountMatched: row[3].int64 == 1,
                commandDigestMatched: row[4].int64 == 1,
                resourceMatched: row[5].int64 == 1,
                headMatched: row[6].int64 == 1,
                stateMatched: row[7].int64 == 1
            ),
            remoteHead: head(snapshot: row[8].blob, generation: row[9].int64),
            cloneRemoteHead: head(snapshot: row[10].blob, generation: row[11].int64)
        )
    }

    static func head(snapshot: Data?, generation: Int64?) throws -> V2RemoteHead? {
        guard let snapshot, let generation else { return nil }
        return try V2RemoteHead(
            snapshotID: SnapshotID(rawValue: snapshot.hexString),
            generation: generation
        )
    }

    func commandWorkID(_ kind: String, payload: [String: Any]) throws -> WorkID {
        let key = kind == "cloneWork" ? "sourceWorkId" : "workId"
        return try WorkID(uuidString: payload.uuid(key))
    }
}

extension SealedCommand {
    func payloadDictionary() throws -> [String: Any] {
        guard let dictionary = try JSONSerialization.jsonObject(with: payloadBytes) as? [String: Any] else {
            throw SyncV2StoreError.invalidCommand
        }
        return dictionary
    }
}

extension [String: Any] {
    func uuid(_ key: String) throws -> String {
        guard let value = self[key] as? String,
              let parsed = UUID(uuidString: value),
              parsed.uuidString.lowercased() == value else {
            throw SyncV2StoreError.invalidCommand
        }
        return value
    }

    func snapshot(_ key: String) throws -> SnapshotID {
        guard let value = self[key] as? String else {
            throw SyncV2StoreError.invalidCommand
        }
        return try SnapshotID(rawValue: value)
    }

    func object(_ key: String) throws -> ObjectID {
        guard let value = self[key] as? String else {
            throw SyncV2StoreError.invalidCommand
        }
        return try ObjectID(rawValue: value)
    }

    func remoteHead(_ key: String) throws -> V2RemoteHead? {
        guard let value = self[key] else { throw SyncV2StoreError.invalidCommand }
        if value is NSNull {
            return nil
        }
        guard let object = value as? [String: Any],
              let generation = (object["generation"] as? NSNumber)?.int64Value,
              let snapshot = object["snapshotId"] as? String else {
            throw SyncV2StoreError.invalidCommand
        }
        return try V2RemoteHead(
            snapshotID: SnapshotID(rawValue: snapshot),
            generation: generation
        )
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

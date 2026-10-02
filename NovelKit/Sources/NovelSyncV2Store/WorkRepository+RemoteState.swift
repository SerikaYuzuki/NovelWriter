import Foundation
import NovelCore
import NovelSyncV2

extension WorkRepository {
    func hasUnpromotedLeaf(workID: WorkID, scope: V2LocalWorkScope) throws -> Bool {
        guard let row = try scopedWorkRow(workID: workID, scope: scope),
              let bytes = row.currentSnapshotID else { return false }
        return try isUnpromotedLeaf(workID: workID, snapshotID: SnapshotID(rawValue: bytes.hexString))
    }

    func isUnpromotedLeaf(workID: WorkID, snapshotID: SnapshotID) throws -> Bool {
        let rows = try queryRows(
            HistoryPromotionRow.self,
            """
            SELECT \(HistoryPromotionRow.columns) FROM history_occurrences
            WHERE work_id=? AND snapshot_id=?
            """, [.text(workID.description), .blob(snapshotID.bytes)]
        )
        return !rows.isEmpty && rows.allSatisfy {
            $0.reason == "autosaveLeaf" && $0.pinned == 0
        }
    }

    func checkpointParents(workID: WorkID, current: SnapshotID) throws -> [SnapshotID] {
        guard try isUnpromotedLeaf(workID: workID, snapshotID: current) else { return [current] }
        return try query(
            "SELECT parent_snapshot_id FROM snapshot_parents WHERE work_id=? AND snapshot_id=?",
            [.text(workID.description), .blob(current.bytes)]
        ).map { row in
            guard let bytes = try row.scalar.blob else { throw SyncV2StoreError.invalidSnapshot }
            return try SnapshotID(rawValue: bytes.hexString)
        }
    }

    func publishSourceIsCurrentOrStableParent(
        command: SealedCommand, workID: WorkID, work: WorkRow
    ) throws -> Bool {
        guard let bytes = work.currentSnapshotID, let generation = work.localGeneration else { return false }
        let current = try SnapshotID(rawValue: bytes.hexString)
        if generation == command.sourceGeneration, current == command.sourceSnapshotId {
            return true
        }
        guard generation > command.sourceGeneration,
              try isUnpromotedLeaf(workID: workID, snapshotID: current) else { return false }
        return try checkpointParents(workID: workID, current: current) == [command.sourceSnapshotId]
    }

    func isAcknowledgedContent(workID: WorkID, snapshotID: SnapshotID, scope: V2LocalWorkScope) throws -> Bool {
        guard case let .bound(binding) = scope,
              let row = try scopedWorkRow(workID: workID, scope: scope),
              let headGeneration = row.acknowledgedHeadGeneration else { return false }
        return try !query("""
            SELECT 1 FROM snapshot_remote_equivalents e
            WHERE e.work_id=? AND e.local_snapshot_id=? AND e.remote_snapshot_id=e.local_snapshot_id
              AND e.remote_generation<=?
              AND EXISTS (SELECT 1 FROM sealed_commands c JOIN sync_intents i ON i.intent_id=c.intent_id
                WHERE c.work_id=e.work_id AND i.source_snapshot_id=e.local_snapshot_id
                  AND c.status='completed' AND c.receipt_verified=1
                  AND c.server_instance_id=? AND c.protocol_epoch=? AND c.account_id=? AND c.account_fence=?)
            UNION SELECT 1 FROM works w
            WHERE w.work_id=? AND w.current_snapshot_id=? AND w.acknowledged_head_snapshot_id=w.current_snapshot_id
              AND EXISTS (SELECT 1 FROM inbox_batches b WHERE b.work_id=w.work_id AND b.snapshot_id=w.current_snapshot_id
                AND b.state='adopted' AND b.server_instance_id=? AND b.protocol_epoch=? AND b.account_id=? AND b.account_fence=?)
            """, [.text(workID.description), .blob(snapshotID.bytes), .int(headGeneration)] + binding.values +
                [.text(workID.description), .blob(snapshotID.bytes)] + binding.values).isEmpty
    }

    @discardableResult
    func promoteCurrentLeafTransaction(
        workID: WorkID, scope: V2LocalWorkScope, reason: String = "promotion"
    ) throws -> Bool {
        try deletionRepository.requireNotDeleting(workID)
        guard let row = try scopedWorkRow(workID: workID, scope: scope),
              let bytes = row.currentSnapshotID, let generation = row.localGeneration,
              row.syncLane == V2SyncLane.normal.rawValue else { return false }
        let current = try SnapshotID(rawValue: bytes.hexString)
        guard try isUnpromotedLeaf(workID: workID, snapshotID: current),
              try !isAcknowledgedContent(workID: workID, snapshotID: current, scope: scope) else { return false }
        // A parked work remains local. A later same-account resume/open can
        // promote it, without creating an unbound lane for another account.
        if case .parked = scope {
            return false
        }
        try insertHistory(workID: workID, snapshotID: current, reason: reason,
                          pinned: true, generation: generation)
        _ = try outboxRepository.upsertCheckpointIntent(workID: workID, snapshotID: current,
                                                        generation: generation, scope: scope)
        return true
    }
}

extension WorkRepository {
    func publishBaseHead(workID: WorkID, snapshotID: SnapshotID) throws -> V2RemoteHead? {
        let acknowledged = try conflictRepository.acknowledgedHead(workID: workID)
        let ancestry = """
        WITH RECURSIVE ancestry(snapshot_id) AS (
          SELECT ? UNION
          SELECT p.parent_snapshot_id FROM snapshot_parents p
          JOIN ancestry a ON a.snapshot_id=p.snapshot_id WHERE p.work_id=?
        )
        """
        let prefix: [SQLiteValue] = [.blob(snapshotID.bytes), .text(workID.description)]
        if let acknowledged,
           try !query(ancestry + "SELECT 1 FROM ancestry WHERE snapshot_id=?",
                      prefix + [.blob(acknowledged.snapshotID.bytes)]).isEmpty {
            return acknowledged
        }
        let binding = try accountRepository.activeBinding(workID: workID)
        let rows = try queryRows(
            ReceiptHeadRow.self,
            ancestry + """
            SELECT \(ReceiptHeadRow.qualifiedColumns("r"))
            FROM remote_receipts r
            JOIN sealed_commands c ON c.account_id=r.account_id AND c.command_id=r.command_id
            JOIN ancestry a ON a.snapshot_id=r.remote_head_snapshot_id
            WHERE r.work_id=? AND c.server_instance_id=? AND c.protocol_epoch=?
              AND c.account_id=? AND c.account_fence=? AND c.receipt_verified=1
            UNION
            SELECT \(InboxHeadRow.qualifiedColumns("i"))
            FROM inbox_batches i JOIN ancestry a ON a.snapshot_id=i.snapshot_id
            WHERE i.work_id=? AND i.server_instance_id=? AND i.protocol_epoch=?
              AND i.account_id=? AND i.account_fence=? AND i.state IN ('verified','adopted')
            ORDER BY 2 DESC LIMIT 1
            """, prefix + [.text(workID.description)] + binding.values +
                [.text(workID.description)] + binding.values
        )
        guard let row = rows.first,
              let head = try StoreValueCoding.head(
                  snapshot: row.remoteHeadSnapshotID,
                  generation: row.remoteHeadGeneration
              ) else {
            if acknowledged == nil {
                return nil
            }
            throw SyncV2StoreError.invalidSnapshot
        }
        return head
    }
}

extension WorkRepository {
    func immutableTransferView(
        workID: WorkID,
        scope: V2LocalWorkScope
    ) throws -> V2ImmutableTransferView? {
        guard case let .bound(binding) = scope,
              let row = try scopedWorkRow(workID: workID, scope: scope),
              row.currentSnapshotID != nil else {
            return nil
        }
        let summary = try WorkRepository.summary(row)
        guard let intent = try outboxRepository.pendingIntents(scope: scope, workID: workID).first else {
            return nil
        }
        let snapshot = try loadEncoded(
            workID: workID,
            // The intent is the durable source of truth for the bytes to
            // send. The Work head may have advanced after a conflict choice;
            // reading the current head here would turn a decision snapshot
            // into a publish of a newer edit (or make resolution validation
            // fail after silently selecting the wrong bytes).
            snapshotID: intent.sourceSnapshotID
        )
        return try V2ImmutableTransferView(
            workID: workID,
            binding: binding,
            summary: summary,
            snapshot: snapshot,
            pendingIntent: intent,
            expectedRemoteHead: intent.kind == "checkpoint"
                ? publishBaseHead(workID: workID, snapshotID: intent.sourceSnapshotID)
                : conflictRepository.acknowledgedHead(workID: workID)
        )
    }

    func nextSnapshotTransferView(
        for target: V2ImmutableTransferView,
        scope: V2LocalWorkScope
    ) throws -> V2ImmutableTransferView? {
        guard scope == .bound(target.binding),
              try scopedWorkRow(workID: target.workID, scope: scope) != nil else {
            throw SyncV2StoreError.accountMismatch
        }
        let known = try registeredSnapshotIDs(workID: target.workID, binding: target.binding)
        var stack: [(SnapshotID, Bool)] = [(target.snapshot.snapshotId, false)]
        var visiting = Set<SnapshotID>()
        while let (id, expanded) = stack.popLast() {
            if known.contains(id) {
                continue
            }
            if expanded {
                let generation: Int64
                if id == target.snapshot.snapshotId {
                    generation = target.sourceGeneration
                } else {
                    guard let storedGeneration = try query(
                        "SELECT MIN(local_generation) FROM history_occurrences WHERE work_id=? AND snapshot_id=?",
                        [.text(target.workID.description), .blob(id.bytes)]
                    ).first?.scalar.int64 else { throw SyncV2StoreError.invalidCommand }
                    generation = storedGeneration
                }
                return try V2ImmutableTransferView(
                    workID: target.workID, binding: target.binding, summary: target.summary,
                    snapshot: loadEncoded(workID: target.workID, snapshotID: id),
                    pendingIntent: target.pendingIntent, expectedRemoteHead: target.expectedRemoteHead,
                    sourceGeneration: generation
                )
            }
            guard visiting.insert(id).inserted else { throw SyncV2StoreError.invalidCommand }
            stack.append((id, true))
            let parents = try query(
                "SELECT parent_snapshot_id FROM snapshot_parents WHERE work_id=? AND snapshot_id=? ORDER BY parent_snapshot_id",
                [.text(target.workID.description), .blob(id.bytes)]
            ).map { row -> SnapshotID in
                guard let bytes = try row.scalar.blob else { throw SyncV2StoreError.invalidCommand }
                return try SnapshotID(rawValue: bytes.hexString)
            }
            for parent in parents.reversed() {
                stack.append((parent, false))
            }
        }
        return nil
    }

    func registeredSnapshotIDs(workID: WorkID, binding: V2AccountBinding) throws -> Set<SnapshotID> {
        // A completed register receipt or a verified server Inbox proves
        // registration. Merely having a local snapshot does not.
        let commands = try query(
            """
            SELECT source_snapshot_id FROM sealed_commands
            WHERE work_id=? AND server_instance_id=? AND protocol_epoch=?
              AND account_id=? AND account_fence=? AND command_kind='registerSnapshot'
              AND status='completed' AND receipt_verified=1
            """, [.text(workID.description)] + binding.values
        )
        let inbox = try query(
            """
            SELECT s.snapshot_id FROM inbox_snapshots s JOIN inbox_batches b ON b.inbox_id=s.inbox_id
            WHERE b.work_id=? AND b.server_instance_id=? AND b.protocol_epoch=?
              AND b.account_id=? AND b.account_fence=? AND s.work_id=b.work_id
              AND b.state IN ('verified','adopted') AND s.verified=1
            """, [.text(workID.description)] + binding.values
        )
        var ids = try Set((commands + inbox).map { row -> SnapshotID in
            guard let bytes = try row.scalar.blob else { throw SyncV2StoreError.invalidCommand }
            return try SnapshotID(rawValue: bytes.hexString)
        })
        if let head = try conflictRepository.acknowledgedHead(workID: workID) {
            if let cached = executor.registeredAncestorCache,
               cached.work == workID, cached.binding == binding, cached.head == head.snapshotID {
                ids.formUnion(cached.ids)
            } else {
                let rows = try query("""
                WITH RECURSIVE ancestors(id) AS (
                  SELECT ? UNION
                  SELECT p.parent_snapshot_id FROM snapshot_parents p JOIN ancestors a ON p.snapshot_id=a.id
                  WHERE p.work_id=?
                ) SELECT id FROM ancestors
                """, [.blob(head.snapshotID.bytes), .text(workID.description)])
                let ancestors = try Set(rows.map { row -> SnapshotID in
                    guard let bytes = try row.scalar.blob else { throw SyncV2StoreError.invalidSnapshot }
                    return try SnapshotID(rawValue: bytes.hexString)
                })
                executor.registeredAncestorCache = WorkRepository.RegisteredAncestorCache(
                    work: workID, binding: binding, head: head.snapshotID, ids: ancestors
                )
                ids.formUnion(ancestors)
            }
        }
        return ids
    }

    func knownRemoteObjectIDs(workID: WorkID, scope: V2LocalWorkScope) throws -> Set<ObjectID> {
        guard case let .bound(binding) = scope,
              try scopedWorkRow(workID: workID, scope: scope) != nil else {
            throw SyncV2StoreError.accountMismatch
        }
        let registered = try registeredSnapshotIDs(workID: workID, binding: binding)
        let registeredBytes = Set(registered.map(\.bytes))
        var objectBytes = Set<Data>()
        for row in try queryRows(
            SnapshotObjectRow.self, """
            SELECT \(SnapshotObjectRow.qualifiedColumns("e")) FROM snapshot_entries e
            JOIN snapshots s ON s.snapshot_id=e.snapshot_id WHERE s.work_id=?
            """, [.text(workID.description)]
        ) {
            guard let snapshot = row.snapshotID, let object = row.objectID else {
                throw SyncV2StoreError.invalidSnapshot
            }
            if registeredBytes.contains(snapshot) {
                objectBytes.insert(object)
            }
        }
        let inboxObjects = try query("""
        SELECT DISTINCT o.object_id FROM inbox_objects o JOIN inbox_batches b ON b.inbox_id=o.inbox_id
        WHERE b.work_id=? AND b.server_instance_id=? AND b.protocol_epoch=?
          AND b.account_id=? AND b.account_fence=? AND b.state IN ('verified','adopted') AND o.verified=1
        """, [.text(workID.description)] + binding.values)
        for row in inboxObjects {
            guard let bytes = try row.scalar.blob else { throw SyncV2StoreError.invalidSnapshot }
            objectBytes.insert(bytes)
        }
        var objects = try Set(objectBytes.map { try ObjectID(rawValue: $0.hexString) })
        // Object commands whose source snapshot is registered are already
        // covered by snapshot_entries. Read only IDs here, not all historical
        // canonical requests (tens of thousands on an established work).
        let commands = try queryRows(
            AcknowledgedCommandRow.self,
            """
            SELECT \(AcknowledgedCommandRow.qualifiedColumns("c")) FROM sealed_commands c JOIN remote_receipts r
              ON r.command_id=c.command_id AND r.account_id=c.account_id
            WHERE c.work_id=? AND c.server_instance_id=? AND c.protocol_epoch=?
              AND c.account_id=? AND c.account_fence=? AND c.status='completed' AND c.receipt_verified=1
              AND (c.command_kind='finalizeObject' OR
                   (c.command_kind='prepareObject' AND r.terminal_result='noChanges'))
            """, [.text(workID.description)] + binding.values
        )
        for row in commands {
            guard let rawID = row.commandID, let commandID = UUID(uuidString: rawID),
                  let source = row.sourceSnapshotID else { throw SyncV2StoreError.invalidCommand }
            if registeredBytes.contains(source) {
                continue
            }
            try objects.formUnion(acknowledgedRemoteObjectIDs(commandID: commandID, scope: scope))
        }
        return objects
    }

    func acknowledgedRemoteObjectIDs(
        commandID: UUID, verifiedInboxID: UUID? = nil, scope: V2LocalWorkScope
    ) throws -> Set<ObjectID> {
        guard case let .bound(binding) = scope,
              try outboxRepository.commandBindingIsActive(commandID: commandID, binding: binding),
              let row = try queryRows(
                  AcknowledgedObjectRow.self,
                  """
                  SELECT \(AcknowledgedObjectRow.columns)
                  FROM sealed_commands c JOIN remote_receipts r
                    ON r.command_id=c.command_id AND r.account_id=c.account_id
                  LEFT JOIN upload_transfers t ON t.command_id=c.command_id
                  WHERE c.command_id=? AND c.server_instance_id=? AND c.protocol_epoch=?
                    AND c.account_id=? AND c.account_fence=?
                    AND c.status IN ('completed','conflictPending') AND c.receipt_verified=1
                  """, [.text(commandID.uuidString.lowercased())] + binding.values
              ).first,
              let work = row.workID, let kind = row.commandKind,
              let source = row.sourceSnapshotID, let result = row.terminalResult else {
            throw SyncV2StoreError.invalidCommand
        }
        var objects = Set<ObjectID>()
        if SyncV2CommandKind(rawValue: kind) == .finalizeObject ||
            (SyncV2CommandKind(rawValue: kind) == .prepareObject && result == "noChanges") {
            if let bytes = row.objectID {
                try objects.insert(ObjectID(rawValue: bytes.hexString))
            } else {
                // finalize commands do not own the prepare command's transfer
                // row; noChanges prepares normally have no upload row at all.
                guard let bytes = row.canonicalRequest,
                      let command = try CanonicalJSON.parseObject(bytes).objectDictionary,
                      let payload = command["payload"]?.objectDictionary,
                      let raw = payload["objectId"]?.stringContents else { throw SyncV2StoreError.invalidCommand }
                try objects.insert(ObjectID(rawValue: raw))
            }
        } else if SyncV2CommandKind(rawValue: kind) == .registerSnapshot {
            for entry in try query(
                "SELECT DISTINCT object_id FROM snapshot_entries WHERE snapshot_id=?",
                [.blob(source)]
            ) {
                guard let bytes = try entry.scalar.blob else { throw SyncV2StoreError.invalidSnapshot }
                try objects.insert(ObjectID(rawValue: bytes.hexString))
            }
        }
        if let verifiedInboxID {
            for entry in try query("""
            SELECT o.object_id FROM inbox_objects o JOIN inbox_batches b ON b.inbox_id=o.inbox_id
            WHERE b.inbox_id=? AND b.work_id=? AND b.server_instance_id=? AND b.protocol_epoch=?
              AND b.account_id=? AND b.account_fence=? AND b.state IN ('verified','adopted') AND o.verified=1
            """, [.text(verifiedInboxID.uuidString.lowercased()), .text(work)] + binding.values) {
                guard let bytes = try entry.scalar.blob else { throw SyncV2StoreError.invalidSnapshot }
                try objects.insert(ObjectID(rawValue: bytes.hexString))
            }
        }
        return objects
    }

    func pendingWorkIDs(scope: V2LocalWorkScope) throws -> [WorkID] {
        let summaries = try listWorks(scope: scope)
        return try summaries.compactMap { summary in
            let pending = try outboxRepository.pendingIntents(scope: scope, workID: summary.workID)
            let commands = try outboxRepository.pendingSealedCommands(scope: scope, workID: summary.workID)
            return pending.isEmpty && commands.isEmpty ? nil : summary.workID
        }
    }
}

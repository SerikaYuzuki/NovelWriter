import Foundation
import NovelSyncV2

public extension LocalSyncV2Store {
    /// Returns the exact current manifest/object bytes and the intent that the
    /// worker is allowed to replicate.  No JSON decode/re-encode happens here.
    func immutableTransferView(
        workID: WorkID,
        scope: V2LocalWorkScope
    ) throws -> V2ImmutableTransferView? {
        guard case let .bound(binding) = scope,
              let row = try scopedWorkRow(workID: workID, scope: scope),
              row[3].blob != nil else {
            return nil
        }
        let summary = try Self.summary(row)
        guard let intent = try pendingIntents(scope: scope, workID: workID).first else {
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
                : acknowledgedHead(workID: workID)
        )
    }

    /// Selects the first unregistered dependency in parent-first order. The
    /// checkpoint intent remains unchanged; only object/registration commands
    /// use this historical snapshot's real local occurrence as their source.
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
                    ).first?.first?.int64 else { throw SyncV2StoreError.invalidCommand }
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
                guard let bytes = row.first?.blob else { throw SyncV2StoreError.invalidCommand }
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
            guard let bytes = row.first?.blob else { throw SyncV2StoreError.invalidCommand }
            return try SnapshotID(rawValue: bytes.hexString)
        })
        if let head = try acknowledgedHead(workID: workID) {
            if let cached = registeredAncestorCache,
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
                    guard let bytes = row.first?.blob else { throw SyncV2StoreError.invalidSnapshot }
                    return try SnapshotID(rawValue: bytes.hexString)
                })
                registeredAncestorCache = (workID, binding, head.snapshotID, ancestors)
                ids.formUnion(ancestors)
            }
        }
        return ids
    }

    /// Evidence is scoped to the complete binding. Local bytes alone never
    /// prove availability; registered closure or a verified receipt does.
    func knownRemoteObjectIDs(workID: WorkID, scope: V2LocalWorkScope) throws -> Set<ObjectID> {
        guard case let .bound(binding) = scope,
              try scopedWorkRow(workID: workID, scope: scope) != nil else {
            throw SyncV2StoreError.accountMismatch
        }
        let registered = try registeredSnapshotIDs(workID: workID, binding: binding)
        let registeredBytes = Set(registered.map(\.bytes))
        var objectBytes = Set<Data>()
        for row in try query("SELECT e.snapshot_id,e.object_id FROM snapshot_entries e JOIN snapshots s ON s.snapshot_id=e.snapshot_id WHERE s.work_id=?",
                             [.text(workID.description)]) {
            guard let snapshot = row[0].blob, let object = row[1].blob else { throw SyncV2StoreError.invalidSnapshot }
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
            guard let bytes = row[0].blob else { throw SyncV2StoreError.invalidSnapshot }
            objectBytes.insert(bytes)
        }
        var objects = try Set(objectBytes.map { try ObjectID(rawValue: $0.hexString) })
        // Object commands whose source snapshot is registered are already
        // covered by snapshot_entries. Read only IDs here, not all historical
        // canonical requests (tens of thousands on an established work).
        let commands = try query("""
        SELECT c.command_id,c.source_snapshot_id FROM sealed_commands c JOIN remote_receipts r
          ON r.command_id=c.command_id AND r.account_id=c.account_id
        WHERE c.work_id=? AND c.server_instance_id=? AND c.protocol_epoch=?
          AND c.account_id=? AND c.account_fence=? AND c.status='completed' AND c.receipt_verified=1
          AND (c.command_kind='finalizeObject' OR (c.command_kind='prepareObject' AND r.terminal_result='noChanges'))
        """, [.text(workID.description)] + binding.values)
        for row in commands {
            guard let rawID = row[0].text, let commandID = UUID(uuidString: rawID),
                  let source = row[1].blob else { throw SyncV2StoreError.invalidCommand }
            if registeredBytes.contains(source) {
                continue
            }
            try objects.formUnion(acknowledgedRemoteObjectIDs(commandID: commandID, scope: scope))
        }
        return objects
    }

    /// Incremental evidence for one durable acknowledgement. Never scans a
    /// work's history. Upload acknowledgement alone is not object availability.
    func acknowledgedRemoteObjectIDs(
        commandID: UUID, verifiedInboxID: UUID? = nil, scope: V2LocalWorkScope
    ) throws -> Set<ObjectID> {
        guard case let .bound(binding) = scope,
              try commandBindingIsActive(commandID: commandID, binding: binding),
              let row = try query("""
              SELECT c.work_id,c.command_kind,c.source_snapshot_id,r.terminal_result,t.object_id,
                     CASE WHEN t.object_id IS NULL AND c.command_kind IN ('prepareObject','finalizeObject')
                          THEN c.canonical_request ELSE NULL END
              FROM sealed_commands c JOIN remote_receipts r ON r.command_id=c.command_id AND r.account_id=c.account_id
              LEFT JOIN upload_transfers t ON t.command_id=c.command_id
              WHERE c.command_id=? AND c.server_instance_id=? AND c.protocol_epoch=?
                AND c.account_id=? AND c.account_fence=? AND c.status IN ('completed','conflictPending') AND c.receipt_verified=1
              """, [.text(commandID.uuidString.lowercased())] + binding.values).first,
              let work = row[0].text, let kind = row[1].text,
              let source = row[2].blob, let result = row[3].text else {
            throw SyncV2StoreError.invalidCommand
        }
        var objects = Set<ObjectID>()
        if kind == "finalizeObject" || (kind == "prepareObject" && result == "noChanges") {
            if let bytes = row[4].blob {
                try objects.insert(ObjectID(rawValue: bytes.hexString))
            } else {
                // finalize commands do not own the prepare command's transfer
                // row; noChanges prepares normally have no upload row at all.
                guard let bytes = row[5].blob,
                      let command = try CanonicalJSON.parseObject(bytes).objectDictionary,
                      let payload = command["payload"]?.objectDictionary,
                      let raw = payload["objectId"]?.stringContents else { throw SyncV2StoreError.invalidCommand }
                try objects.insert(ObjectID(rawValue: raw))
            }
        } else if kind == "registerSnapshot" {
            for entry in try query("SELECT DISTINCT object_id FROM snapshot_entries WHERE snapshot_id=?", [.blob(source)]) {
                guard let bytes = entry[0].blob else { throw SyncV2StoreError.invalidSnapshot }
                try objects.insert(ObjectID(rawValue: bytes.hexString))
            }
        }
        if let verifiedInboxID {
            for entry in try query("""
            SELECT o.object_id FROM inbox_objects o JOIN inbox_batches b ON b.inbox_id=o.inbox_id
            WHERE b.inbox_id=? AND b.work_id=? AND b.server_instance_id=? AND b.protocol_epoch=?
              AND b.account_id=? AND b.account_fence=? AND b.state IN ('verified','adopted') AND o.verified=1
            """, [.text(verifiedInboxID.uuidString.lowercased()), .text(work)] + binding.values) {
                guard let bytes = entry[0].blob else { throw SyncV2StoreError.invalidSnapshot }
                try objects.insert(ObjectID(rawValue: bytes.hexString))
            }
        }
        return objects
    }

    func pendingWorkIDs(scope: V2LocalWorkScope) throws -> [WorkID] {
        let summaries = try listWorks(scope: scope)
        return try summaries.compactMap { summary in
            let pending = try pendingIntents(scope: scope, workID: summary.workID)
            let commands = try pendingSealedCommands(scope: scope, workID: summary.workID)
            return pending.isEmpty && commands.isEmpty ? nil : summary.workID
        }
    }
}

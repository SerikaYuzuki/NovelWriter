import Foundation
import NovelCore
import NovelSyncV2

extension WorkRepository {
    func scopedWorkRow(
        workID: WorkID,
        scope: V2LocalWorkScope
    ) throws -> WorkRow? {
        let columns = WorkRow.columns
        switch scope {
        case .unbound:
            return try queryRows(
                WorkRow.self,
                """
                SELECT \(columns) FROM works w
                WHERE w.work_id=? AND NOT EXISTS (
                  SELECT 1 FROM account_bindings b
                  WHERE b.work_id=w.work_id AND b.state IN ('bound','parked')
                )
                """,
                [.text(workID.description)]
            ).first
        case .parked:
            return try queryRows(
                WorkRow.self,
                """
                SELECT \(columns) FROM works w
                WHERE w.work_id=? AND EXISTS (
                  SELECT 1 FROM account_bindings b
                  WHERE b.work_id=w.work_id AND b.state='parked'
                ) AND NOT EXISTS (
                  SELECT 1 FROM account_bindings b
                  WHERE b.work_id=w.work_id AND b.state='bound'
                )
                """,
                [.text(workID.description)]
            ).first
        case let .bound(binding):
            return try queryRows(
                WorkRow.self,
                """
                SELECT \(columns) FROM works w
                JOIN account_bindings b ON b.work_id=w.work_id
                WHERE w.work_id=? AND b.server_instance_id=?
                  AND b.protocol_epoch=? AND b.account_id=?
                  AND b.account_fence=? AND b.state='bound'
                """,
                [.text(workID.description)] + binding.values
            ).first
        }
    }

    func workExists(workID: WorkID) throws -> Bool {
        try !query(
            "SELECT 1 FROM works WHERE work_id=?",
            [.text(workID.description)]
        ).isEmpty
    }

    func insertHistory(
        workID: WorkID,
        snapshotID: SnapshotID,
        reason: String,
        pinned: Bool,
        generation: Int64
    ) throws {
        try exec(
            """
            INSERT INTO history_occurrences(
              occurrence_id,work_id,snapshot_id,reason,pinned,
              local_generation,created_at
            ) VALUES(?,?,?,?,?,?,?)
            """,
            [
                .text(UUID().uuidString.lowercased()), .text(workID.description),
                .blob(snapshotID.bytes), .text(reason), .int(pinned ? 1 : 0),
                .int(generation), .text(StoreValueCoding.now())
            ]
        )
    }

    func loadEncoded(workID: WorkID, snapshotID: SnapshotID) throws -> EncodedSnapshot {
        guard let bytes = try query(
            "SELECT manifest_bytes FROM snapshots WHERE work_id=? AND snapshot_id=?",
            [.text(workID.description), .blob(snapshotID.bytes)]
        ).first?.scalar.blob,
            SnapshotID(data: bytes) == snapshotID else { throw SyncV2StoreError.snapshotNotFound }
        let manifest = try SnapshotValidator.validate(manifestBytes: bytes)
        guard manifest.workId == workID else { throw SyncV2StoreError.invalidSnapshot }
        var objects: [ObjectID: Data] = [:]
        for entry in manifest.entries {
            guard let object = try queryRows(
                ObjectContentRow.self,
                "SELECT \(ObjectContentRow.columns) FROM objects WHERE object_id=?",
                [.blob(entry.objectId.bytes)]
            ).first,
                object.byteCount == Int64(entry.byteCount),
                let data = object.bytes,
                ObjectID(data: data) == entry.objectId else { throw SyncV2StoreError.invalidSnapshot }
            objects[entry.objectId] = data
        }
        let encoded = EncodedSnapshot(
            manifest: manifest,
            manifestBytes: bytes,
            objects: objects
        )
        try SnapshotValidator.validateObjects(encoded)
        try attestEncodedRows(encoded, workID: workID)
        return encoded
    }

    func attestEncodedRows(_ encoded: EncodedSnapshot, workID: WorkID) throws {
        let snapshotID = encoded.snapshotId
        let parents = try query(
            """
            SELECT parent_snapshot_id FROM snapshot_parents
            WHERE work_id=? AND snapshot_id=?
            UNION ALL
            SELECT parent_snapshot_id FROM shallow_boundaries
            WHERE work_id=? AND snapshot_id=? ORDER BY parent_snapshot_id
            """,
            [.text(workID.description), .blob(snapshotID.bytes),
             .text(workID.description), .blob(snapshotID.bytes)]
        ).compactMap { try $0.scalar.blob?.hexString }
        guard parents == encoded.manifest.parentSnapshotIds.map(\.rawValue).sorted() else {
            throw SyncV2StoreError.invalidSnapshot
        }
        let entries = try queryRows(
            SnapshotEntryRow.self,
            """
            SELECT \(SnapshotEntryRow.columns)
            FROM snapshot_entries WHERE snapshot_id=? ORDER BY entity_key
            """,
            [.blob(snapshotID.bytes)]
        )
        guard entries.count == encoded.manifest.entries.count else {
            throw SyncV2StoreError.invalidSnapshot
        }
        for (row, entry) in zip(entries, encoded.manifest.entries) {
            guard row.entityKey == entry.entityKey,
                  row.objectID == entry.objectId.bytes,
                  row.byteCount == Int64(entry.byteCount),
                  row.contentType == entry.contentType.rawValue else {
                throw SyncV2StoreError.invalidSnapshot
            }
        }
    }

    func validateAnchor(_ model: SnapshotModel, workRow: WorkRow) throws {
        guard workRow.documentID == DocumentID(model.document.id).description,
              try workRow.documentCreatedAt == StoreValueCoding.iso8601(model.documentCreatedAt) else {
            throw SyncV2StoreError.invalidSnapshot
        }
    }

    func insertWork(
        workID: WorkID,
        documentID: DocumentID,
        documentCreatedAt: String,
        lane: V2SyncLane,
        scope: V2LocalWorkScope
    ) throws {
        try exec(
            """
            INSERT INTO works(
              work_id,document_id,document_created_at,sync_lane
            ) VALUES(?,?,?,?)
            """,
            [
                .text(workID.description), .text(documentID.description),
                .text(documentCreatedAt), .text(lane.rawValue)
            ]
        )
        if case let .bound(binding) = scope {
            try accountRepository.insertBinding(workID: workID, binding: binding)
        }
    }

    func insertEncoded(_ encoded: EncodedSnapshot, workID: WorkID) throws {
        guard encoded.snapshotId == SnapshotID(data: encoded.manifestBytes),
              encoded.manifest.workId == workID else {
            throw SyncV2StoreError.invalidSnapshot
        }
        guard let work = try queryRows(
            WorkAnchorRow.self,
            "SELECT \(WorkAnchorRow.columns) FROM works WHERE work_id=?",
            [.text(workID.description)]
        ).first else { throw SyncV2StoreError.workNotFound }
        let decodeStart = executor.snapshotInsertionObserver == nil ? nil : ContinuousClock.now
        let model = try SnapshotCodec.decode(encoded)
        if let decodeStart {
            executor.snapshotInsertionObserver?("decode", decodeStart.duration(to: .now))
        }
        guard work.documentID == DocumentID(model.document.id).description,
              try work.documentCreatedAt == StoreValueCoding.iso8601(model.documentCreatedAt) else {
            throw SyncV2StoreError.invalidSnapshot
        }
        try insertValidatedEncoded(encoded, workID: workID, attestExistingObjects: false)
    }

    func insertValidatedEncoded(
        _ encoded: EncodedSnapshot,
        workID: WorkID,
        attestExistingObjects: Bool = true,
        verifiedRemote: Bool = false
    ) throws {
        let snapshotID = encoded.snapshotId
        let alreadyExists = try !query("SELECT 1 FROM snapshots WHERE snapshot_id=?", [.blob(snapshotID.bytes)])
            .isEmpty
        if !verifiedRemote || alreadyExists {
            try validateParents(encoded, workID: workID, checkCycles: alreadyExists)
        }

        let objectsStart = executor.snapshotInsertionObserver == nil ? nil : ContinuousClock.now
        for (objectID, bytes) in encoded.objects {
            if executor.transactionObjects?.contains(objectID) == true {
                continue
            }
            if let existing = try query(
                attestExistingObjects
                    ? "SELECT \(ObjectContentRow.columns) FROM objects WHERE object_id=?"
                    : "SELECT byte_count FROM objects WHERE object_id=?",
                [.blob(objectID.bytes)]
            ).first {
                // Incoming bytes have been digest-validated. Existing immutable CAS
                // rows are protected by attested immutability triggers. Bytes are
                // rehashed on read, rather than reread at every checkpoint.
                // Import must attest bytes it will reuse from an earlier transaction,
                // so a corrupt existing CAS row cannot turn valid input into a bad install.
                // This happens once per unique object, not once per snapshot.
                guard try existing.int64("byte_count") == Int64(bytes.count),
                      try !attestExistingObjects || ObjectContentRow(existing).bytes == bytes else {
                    throw SyncV2StoreError.invalidSnapshot
                }
                if attestExistingObjects {
                    executor.transactionObjects?.insert(objectID)
                }
            } else {
                try exec(
                    "INSERT INTO objects(object_id,byte_count,bytes) VALUES(?,?,?)",
                    [.blob(objectID.bytes), .int(Int64(bytes.count)), .blob(bytes)]
                )
                executor.transactionObjects?.insert(objectID)
            }
        }

        if let objectsStart {
            executor.snapshotInsertionObserver?("objectUpsert", objectsStart.duration(to: .now))
        }
        if let existing = try queryRows(
            SnapshotManifestRow.self,
            """
            SELECT \(SnapshotManifestRow.columns)
            FROM snapshots WHERE snapshot_id=?
            """,
            [.blob(snapshotID.bytes)]
        ).first {
            guard existing.workID == workID.description,
                  existing.manifestBytes == encoded.manifestBytes,
                  existing.manifestDigest == snapshotID.bytes else {
                throw SyncV2StoreError.invalidSnapshot
            }
            // Existing rows must already be exact; do not repair missing children
            // with INSERT OR IGNORE before attesting them.
            try attestEncodedRows(encoded, workID: workID)
            return
        } else {
            try exec(
                """
                INSERT INTO snapshots(
                  snapshot_id,work_id,manifest_bytes,manifest_digest,created_at
                ) VALUES(?,?,?,?,?)
                """,
                [
                    .blob(snapshotID.bytes), .text(workID.description),
                    .blob(encoded.manifestBytes), .blob(snapshotID.bytes),
                    .text(StoreValueCoding.now())
                ]
            )
        }
        try inboxRepository.resolveBoundaries(workID: workID, parent: snapshotID)
        for parent in encoded.manifest.parentSnapshotIds {
            let local = try inboxRepository.hasSnapshot(workID: workID, snapshotID: parent)
            guard local || verifiedRemote else { throw SyncV2StoreError.invalidSnapshot }
            let table = local ? "snapshot_parents" : "shallow_boundaries"
            try exec(
                """
                INSERT OR IGNORE INTO \(table)(
                  work_id,snapshot_id,parent_snapshot_id
                ) VALUES(?,?,?)
                """,
                [
                    .text(workID.description), .blob(snapshotID.bytes),
                    .blob(parent.bytes)
                ]
            )
        }
        let entriesStart = executor.snapshotInsertionObserver == nil ? nil : ContinuousClock.now
        for entry in encoded.manifest.entries {
            try exec(
                """
                INSERT OR IGNORE INTO snapshot_entries(
                  snapshot_id,entity_key,object_id,byte_count,content_type
                ) VALUES(?,?,?,?,?)
                """,
                [
                    .blob(snapshotID.bytes), .text(entry.entityKey),
                    .blob(entry.objectId.bytes), .int(Int64(entry.byteCount)),
                    .text(entry.contentType.rawValue)
                ]
            )
        }
        if let entriesStart {
            executor.snapshotInsertionObserver?("entryInsert", entriesStart.duration(to: .now))
        }
    }

    func validateParents(_ encoded: EncodedSnapshot, workID: WorkID, checkCycles: Bool = true) throws {
        let snapshotID = encoded.snapshotId
        for parent in encoded.manifest.parentSnapshotIds {
            guard parent != snapshotID,
                  try inboxRepository.hasSnapshot(workID: workID, snapshotID: parent) || !query(
                      "SELECT 1 FROM shallow_boundaries WHERE work_id=? AND snapshot_id=? AND parent_snapshot_id=?",
                      [.text(workID.description), .blob(snapshotID.bytes), .blob(parent.bytes)]
                  ).isEmpty else { throw SyncV2StoreError.invalidSnapshot }
            // A new content-addressed manifest can only point at existing rows.
            // Immediate foreign keys make closing a cycle impossible on insertion.
            if !checkCycles {
                continue
            }
            let cycle = try query(
                """
                WITH RECURSIVE ancestors(id) AS (
                  SELECT parent_snapshot_id FROM snapshot_parents
                    WHERE work_id=? AND snapshot_id=?
                  UNION
                  SELECT p.parent_snapshot_id FROM snapshot_parents p
                    JOIN ancestors a ON p.snapshot_id=a.id
                    WHERE p.work_id=?
                ) SELECT 1 FROM ancestors WHERE id=? LIMIT 1
                """,
                [
                    .text(workID.description), .blob(parent.bytes),
                    .text(workID.description), .blob(snapshotID.bytes)
                ]
            )
            guard cycle.isEmpty else { throw SyncV2StoreError.invalidSnapshot }
        }
    }
}

extension WorkRepository {
    func verifiedInboxSnapshot(
        workID: WorkID,
        snapshotID: SnapshotID,
        scope: V2LocalWorkScope
    ) throws -> EncodedSnapshot? {
        guard case let .bound(binding) = scope,
              try scopedWorkRow(workID: workID, scope: scope) != nil else { return nil }
        guard let row = try queryRows(
            InboxManifestRow.self,
            """
            SELECT \(InboxManifestRow.qualifiedColumns("s")) FROM inbox_snapshots s
            JOIN inbox_batches i ON i.inbox_id=s.inbox_id
            WHERE s.work_id=? AND s.snapshot_id=? AND s.verified=1
              AND i.work_id=s.work_id AND i.server_instance_id=? AND i.protocol_epoch=?
              AND i.account_id=? AND i.account_fence=? AND i.state IN ('verified','adopted')
            ORDER BY i.rowid DESC LIMIT 1
            """, [.text(workID.description), .blob(snapshotID.bytes)] + binding.values
        ).first else { return nil }
        guard let inboxID = row.inboxID, let bytes = row.manifestBytes,
              SnapshotID(data: bytes) == snapshotID else { throw SyncV2StoreError.invalidSnapshot }
        let manifest = try SnapshotValidator.validate(manifestBytes: bytes)
        guard manifest.workId == workID else { throw SyncV2StoreError.invalidSnapshot }
        var objects: [ObjectID: Data] = [:]
        for entry in manifest.entries {
            guard let object = try query("""
            SELECT bytes FROM inbox_objects
            WHERE inbox_id=? AND object_id=? AND byte_count=? AND verified=1
            """, [.text(inboxID), .blob(entry.objectId.bytes), .int(Int64(entry.byteCount))]).first?.scalar.blob else {
                throw SyncV2StoreError.invalidSnapshot
            }
            objects[entry.objectId] = object
        }
        let snapshot = EncodedSnapshot(manifest: manifest, manifestBytes: bytes, objects: objects)
        try SnapshotValidator.validateObjects(snapshot)
        return snapshot
    }

    func committedSnapshot(
        workID: WorkID,
        snapshotID: SnapshotID,
        scope: V2LocalWorkScope
    ) throws -> EncodedSnapshot? {
        guard try scopedWorkRow(workID: workID, scope: scope) != nil else { return nil }
        guard try !query(
            "SELECT 1 FROM snapshots WHERE work_id=? AND snapshot_id=?",
            [.text(workID.description), .blob(snapshotID.bytes)]
        ).isEmpty else { return nil }
        let encoded = try loadEncoded(workID: workID, snapshotID: snapshotID)
        try validateParents(encoded, workID: workID)
        return encoded
    }
}

/// Uses the caller-owned transaction; never begins or commits one.
extension WorkRepository {
    func installExplicitCloneHeadInTransaction(clone: EncodedSnapshot, newWorkID: WorkID) throws {
        try exec(
            """
            UPDATE works SET current_snapshot_id=?,local_generation=1
            WHERE work_id=? AND local_generation=0
            """,
            [.blob(clone.snapshotIDBytes), .text(newWorkID.description)]
        )
        guard try changes() == 1 else { throw SyncV2StoreError.staleCAS }
    }
}

/// Uses the caller-owned transaction; never begins or commits one.
extension WorkRepository {
    func updateCheckpointHeadInTransaction(encoded: EncodedSnapshot, request: V2CheckpointRequest, next: Int64) throws {
        try exec(
            """
            UPDATE works SET current_snapshot_id=?,local_generation=?
            WHERE work_id=? AND local_generation=?
            """,
            [
                .blob(encoded.snapshotIDBytes), .int(next),
                .text(request.workID.description), .int(request.expectedGeneration)
            ]
        )
        guard try changes() == 1 else {
            throw SyncV2StoreError.generationMismatch
        }
    }
}

/// Uses the caller-owned transaction; never begins or commits one.
extension WorkRepository {
    func installInitialHeadInTransaction(graph: V2RemoteSnapshotGraph) throws {
        try exec(
            "UPDATE works SET current_snapshot_id=?,local_generation=1 WHERE work_id=? AND local_generation=0 AND current_snapshot_id IS NULL",
            [.blob(graph.headSnapshotID.bytes), .text(graph.workID.description)]
        )
        guard try changes() == 1 else { throw SyncV2StoreError.staleCAS }
    }
}

/// Uses the caller-owned transaction; never begins or commits one.
extension WorkRepository {
    func installKeepBothHeadInTransaction(
        prepared: KeepBothPreparedMaterial,
        request: V2KeepBothPreparationRequest
    ) throws {
        try exec(
            """
            UPDATE works SET current_snapshot_id=?,local_generation=1
            WHERE work_id=? AND local_generation=0
            """,
            [
                .blob(prepared.clone.snapshotIDBytes),
                .text(request.newWorkID.description)
            ]
        )
        guard try changes() == 1 else { throw SyncV2StoreError.staleCAS }
    }
}

/// Uses the caller-owned transaction; never begins or commits one.
extension WorkRepository {
    func installDeviceResolutionHeadInTransaction(
        decision: EncodedSnapshot,
        request: V2DeviceResolutionRequest,
        next: Int64
    ) throws {
        try exec(
            """
            UPDATE works SET current_snapshot_id=?,local_generation=?
            WHERE work_id=? AND current_snapshot_id=? AND local_generation=?
            """,
            [
                .blob(decision.snapshotIDBytes), .int(next),
                .text(request.workID.description),
                .blob(request.localSnapshotID.bytes),
                .int(request.sourceGeneration)
            ]
        )
        guard try changes() == 1 else { throw SyncV2StoreError.staleCAS }
    }
}

/// Uses the caller-owned transaction; never begins or commits one.
extension WorkRepository {
    func backfillRootDocumentObject(root: SnapshotID) throws -> Data? {
        try query("SELECT object_id FROM snapshot_entries WHERE snapshot_id=? AND entity_key='work/document'",
                  [.blob(root.bytes)]).first?.scalar.blob
    }
}

extension WorkRepository {
    func checkpointContentMatches(
        workID: WorkID,
        current: SnapshotID,
        candidate: EncodedSnapshot
    ) throws -> Bool {
        guard let bytes = try query(
            "SELECT manifest_bytes FROM snapshots WHERE work_id=? AND snapshot_id=?",
            [.text(workID.description), .blob(current.bytes)]
        ).first?.scalar.blob,
            SnapshotID(data: bytes) == current else { throw SyncV2StoreError.snapshotNotFound }
        let manifest = try SnapshotValidator.validate(manifestBytes: bytes)
        guard manifest.workId == workID else { throw SyncV2StoreError.invalidSnapshot }
        try attestEncodedRows(EncodedSnapshot(manifest: manifest, manifestBytes: bytes, objects: [:]), workID: workID)
        // Both sides use digest-validated immutable CAS objects. Equal entries
        // include object IDs, sizes and types, so loading payload bytes adds no
        // content distinction. Parents may differ for an already-promoted head.
        return manifest.entries == candidate.manifest.entries
    }
}

import Foundation
import NovelCore
import NovelSyncV2

public extension LocalSyncV2Store {
    func stageRemote(
        _ remote: V2RemoteSnapshot,
        scope: V2LocalWorkScope
    ) throws {
        let anchor = try Self.validateGraphContent(remote.graph, full: true)
        try stageValidatedGraph(remote.graph, scope: scope, anchor: anchor)
    }

    func stageRemoteGraph(
        _ graph: V2RemoteSnapshotGraph,
        scope: V2LocalWorkScope
    ) async throws {
        let validation = Task.detached { try Self.validateGraphContent(graph, full: true) }
        let anchor = try await withTaskCancellationHandler {
            try await validation.value
        } onCancel: { validation.cancel() }
        try stageValidatedGraph(graph, scope: scope, anchor: anchor)
    }

    private func stageValidatedGraph(
        _ graph: V2RemoteSnapshotGraph, scope: V2LocalWorkScope, anchor: GraphAnchor
    ) throws {
        try Task.checkCancellation()
        try requireNotDeleting(graph.workID)
        guard case let .bound(binding) = scope else {
            throw SyncV2StoreError.accountMismatch
        }
        try Task.checkCancellation()
        try inTransaction {
            if let work = try scopedWorkRow(workID: graph.workID, scope: scope) {
                guard work.documentID == anchor.documentID.description,
                      work.documentCreatedAt == anchor.createdAt else {
                    throw SyncV2StoreError.invalidSnapshot
                }
            } else if try workExists(workID: graph.workID) {
                throw SyncV2StoreError.workNotFound
            } else {
                try insertWork(
                    workID: graph.workID,
                    documentID: anchor.documentID,
                    documentCreatedAt: anchor.createdAt,
                    lane: .normal,
                    scope: scope
                )
            }
            try validateGraphParents(graph)
            if try inboxExists(inboxID: graph.inboxID) {
                try attestInboxReplay(graph, binding: binding, anchor: anchor)
                return
            }
            let inboxID = graph.inboxID.uuidString.lowercased()
            let head = try graphSnapshot(graph.headSnapshotID, in: graph)
            try exec(
                """
                INSERT INTO inbox_batches(
                  inbox_id,work_id,document_id,document_created_at,
                  server_instance_id,protocol_epoch,account_id,account_fence,
                  snapshot_id,manifest_bytes,expected_current_snapshot_id,
                  expected_local_generation,expected_remote_head_snapshot_id,
                  expected_remote_head_generation,state
                ) VALUES(?,?,?,?,?,?,?,?,?,?,?,?,?,?, 'staged')
                """,
                [
                    .text(inboxID), .text(graph.workID.description),
                    .text(anchor.documentID.description), .text(anchor.createdAt)
                ] + binding.values + [
                    .blob(graph.headSnapshotID.bytes), .blob(head.manifestBytes),
                    graph.expectedCurrentSnapshotID.map { .blob($0.bytes) } ?? .null,
                    .int(graph.expectedLocalGeneration),
                    graph.expectedRemoteHead.map { .blob($0.snapshotID.bytes) } ?? .null,
                    graph.expectedRemoteHead.map { .int($0.generation) } ?? .null
                ]
            )
            for snapshot in graph.snapshots {
                try Task.checkCancellation()
                try exec(
                    """
                    INSERT INTO inbox_snapshots(
                      inbox_id,snapshot_id,work_id,manifest_bytes,is_head,verified
                    ) VALUES(?,?,?,?,?,0)
                    """,
                    [
                        .text(inboxID), .blob(snapshot.snapshotIDBytes),
                        .text(graph.workID.description), .blob(snapshot.manifestBytes),
                        .int(snapshot.snapshotId == graph.headSnapshotID ? 1 : 0)
                    ]
                )
            }
            for (objectID, bytes) in try graphObjectUnion(graph) {
                try exec(
                    """
                    INSERT INTO inbox_objects(
                      inbox_id,object_id,byte_count,bytes,verified
                    ) VALUES(?,?,?,?,0)
                    """,
                    [
                        .text(inboxID), .blob(objectID.bytes),
                        .int(Int64(bytes.count)), .blob(bytes)
                    ]
                )
            }
            for snapshot in graph.snapshots {
                try Task.checkCancellation()
                for entry in snapshot.manifest.entries {
                    try exec(
                        """
                        INSERT INTO inbox_closure(
                          inbox_id,snapshot_id,entity_key,object_id,
                          byte_count,content_type
                        ) VALUES(?,?,?,?,?,?)
                        """,
                        [
                            .text(inboxID), .blob(snapshot.snapshotIDBytes),
                            .text(entry.entityKey), .blob(entry.objectId.bytes),
                            .int(Int64(entry.byteCount)),
                            .text(entry.contentType.rawValue)
                        ]
                    )
                }
            }
            try recordInboxValidation(graph)
        }
    }

    func verifyInbox(
        inboxID: UUID,
        scope: V2LocalWorkScope
    ) throws {
        guard case let .bound(binding) = scope else {
            throw SyncV2StoreError.accountMismatch
        }
        try Task.checkCancellation()
        let state = try inboxState(inboxID: inboxID, binding: binding)
        guard state == "staged" || state == "verified" || state == "adopted" else {
            throw SyncV2StoreError.inboxNotFound
        }
        let graph = try loadInboxGraph(inboxID: inboxID, binding: binding)
        _ = try validateGraph(graph)
        try validateGraphParents(graph)
        if state == "verified" || state == "adopted" {
            return
        }
        try inTransaction {
            let text = inboxID.uuidString.lowercased()
            try exec(
                "UPDATE inbox_objects SET verified=1 WHERE inbox_id=?",
                [.text(text)]
            )
            try exec(
                "UPDATE inbox_snapshots SET verified=1 WHERE inbox_id=?",
                [.text(text)]
            )
            try exec(
                """
                UPDATE inbox_batches SET state='verified'
                WHERE inbox_id=? AND state='staged'
                """,
                [.text(text)]
            )
            guard try changes() == 1 else { throw SyncV2StoreError.inboxNotFound }
        }
    }

    func adoptInbox(
        inboxID: UUID,
        scope: V2LocalWorkScope
    ) throws {
        guard case let .bound(binding) = scope else {
            throw SyncV2StoreError.accountMismatch
        }
        try Task.checkCancellation()
        let state = try inboxState(inboxID: inboxID, binding: binding)
        if state == "adopted" {
            return
        }
        guard state == "verified" else { throw SyncV2StoreError.inboxNotFound }
        let graph = try loadInboxGraph(inboxID: inboxID, binding: binding)
        try inTransaction {
            try adoptGraphTransaction(graph, expectedConflict: nil, binding: binding)
        }
    }
}

extension LocalSyncV2Store {
    func inboxExists(inboxID: UUID) throws -> Bool {
        try !query(
            "SELECT 1 FROM inbox_batches WHERE inbox_id=?",
            [.text(inboxID.uuidString.lowercased())]
        ).isEmpty
    }

    func inboxState(inboxID: UUID, binding: V2AccountBinding) throws -> String {
        guard let state = try query(
            """
            SELECT state FROM inbox_batches
            WHERE inbox_id=? AND server_instance_id=? AND protocol_epoch=?
              AND account_id=? AND account_fence=?
            """,
            [.text(inboxID.uuidString.lowercased())] + binding.values
        ).first?.scalar.text else { throw SyncV2StoreError.inboxNotFound }
        return state
    }

    func attestInboxReplay(
        _ graph: V2RemoteSnapshotGraph,
        binding: V2AccountBinding,
        anchor: GraphAnchor
    ) throws {
        let inboxID = graph.inboxID.uuidString.lowercased()
        guard let batch = try queryRows(
            InboxReplayBatchRow.self,
            """
            SELECT \(InboxReplayBatchRow.columns)
            FROM inbox_batches WHERE inbox_id=?
            """,
            [.text(inboxID)]
        ).first,
            batch.workID == graph.workID.description,
            batch.documentID == anchor.documentID.description,
            batch.documentCreatedAt == anchor.createdAt,
            batch.serverInstanceID == binding.serverInstanceID,
            batch.protocolEpoch == binding.protocolEpoch,
            batch.accountID == binding.accountID,
            batch.accountFence == binding.accountFence,
            batch.snapshotID == graph.headSnapshotID.bytes,
            batch.expectedCurrentSnapshotID == graph.expectedCurrentSnapshotID?.bytes,
            batch.expectedLocalGeneration == graph.expectedLocalGeneration,
            batch.expectedRemoteHeadSnapshotID == graph.expectedRemoteHead?.snapshotID.bytes,
            batch.expectedRemoteHeadGeneration == graph.expectedRemoteHead?.generation,
            ["staged", "verified", "adopted"].contains(batch.state ?? ""),
            try batch.manifestBytes == graphSnapshot(
                graph.headSnapshotID,
                in: graph
            ).manifestBytes else {
            throw SyncV2StoreError.invalidSnapshot
        }
        let storedSnapshots = try queryRows(
            InboxReplaySnapshotRow.self,
            """
            SELECT \(InboxReplaySnapshotRow.columns) FROM inbox_snapshots
            WHERE inbox_id=? ORDER BY snapshot_id
            """,
            [.text(inboxID)]
        )
        let expectedSnapshots = graph.snapshots.sorted {
            $0.snapshotId.rawValue < $1.snapshotId.rawValue
        }
        guard storedSnapshots.count == expectedSnapshots.count else {
            throw SyncV2StoreError.invalidSnapshot
        }
        for (row, snapshot) in zip(storedSnapshots, expectedSnapshots) {
            guard row.snapshotID == snapshot.snapshotIDBytes,
                  row.manifestBytes == snapshot.manifestBytes,
                  row.isHead == (snapshot.snapshotId == graph.headSnapshotID ? 1 : 0) else {
                throw SyncV2StoreError.invalidSnapshot
            }
        }
        let objects = try graphObjectUnion(graph)
        let storedObjects = try queryRows(
            ObjectBytesRow.self,
            """
            SELECT \(ObjectBytesRow.columns) FROM inbox_objects
            WHERE inbox_id=? ORDER BY object_id
            """,
            [.text(inboxID)]
        )
        let expectedObjects = objects.sorted { $0.key.rawValue < $1.key.rawValue }
        guard storedObjects.count == expectedObjects.count else {
            throw SyncV2StoreError.invalidSnapshot
        }
        for (row, object) in zip(storedObjects, expectedObjects) {
            guard row.objectID == object.key.bytes,
                  row.byteCount == Int64(object.value.count),
                  row.bytes == object.value else {
                throw SyncV2StoreError.invalidSnapshot
            }
        }
        try attestInboxClosure(graph)
    }

    func attestInboxClosure(_ graph: V2RemoteSnapshotGraph) throws {
        let rows = try queryRows(
            InboxClosureRow.self,
            """
            SELECT \(InboxClosureRow.columns)
            FROM inbox_closure WHERE inbox_id=?
            ORDER BY snapshot_id,entity_key
            """,
            [.text(graph.inboxID.uuidString.lowercased())]
        )
        let entries = graph.snapshots.flatMap { snapshot in
            snapshot.manifest.entries.map { (snapshot.snapshotId, $0) }
        }.sorted {
            ($0.0.rawValue, $0.1.entityKey) < ($1.0.rawValue, $1.1.entityKey)
        }
        guard rows.count == entries.count else { throw SyncV2StoreError.invalidSnapshot }
        for (row, pair) in zip(rows, entries) {
            guard row.snapshotID == pair.0.bytes,
                  row.entityKey == pair.1.entityKey,
                  row.objectID == pair.1.objectId.bytes,
                  row.byteCount == Int64(pair.1.byteCount),
                  row.contentType == pair.1.contentType.rawValue else {
                throw SyncV2StoreError.invalidSnapshot
            }
        }
    }

    // Atomic graph installation keeps its validation and writes in one routine.
    // swiftlint:disable:next function_body_length
    func adoptGraphTransaction(
        _ graph: V2RemoteSnapshotGraph,
        expectedConflict: V2ServerResolutionRequest?,
        binding: V2AccountBinding
    ) throws {
        try requireNotDeleting(graph.workID)
        let anchor = try validateGraph(graph)
        try validateGraphParents(graph)
        let inboxID = graph.inboxID.uuidString.lowercased()
        guard try inboxState(inboxID: graph.inboxID, binding: binding) == "verified",
              let current = try scopedWorkRow(
                  workID: graph.workID,
                  scope: .bound(binding)
              ),
              current.documentID == anchor.documentID.description,
              current.documentCreatedAt == anchor.createdAt,
              current.currentSnapshotID == graph.expectedCurrentSnapshotID?.bytes,
              current.localGeneration == graph.expectedLocalGeneration else {
            throw SyncV2StoreError.staleCAS
        }
        if let expectedConflict {
            try validateExactConflict(expectedConflict, binding: binding)
        } else {
            try validateOrdinaryAdoption(
                workID: graph.workID,
                current: current,
                binding: binding
            )
        }
        if let previous = current.currentSnapshotID {
            let previousID: SnapshotID
            do { previousID = try SnapshotID(rawValue: previous.hexString) }
            catch { throw SyncV2StoreError.invalidSnapshot }
            try insertHistory(
                workID: graph.workID,
                snapshotID: previousID,
                reason: "preRemoteAdoption",
                pinned: true,
                generation: graph.expectedLocalGeneration
            )
        }
        for snapshot in try topologicalSnapshots(graph) {
            try Task.checkCancellation()
            try insertValidatedEncoded(snapshot, workID: graph.workID, verifiedRemote: true)
        }
        try Task.checkCancellation()
        let next = graph.expectedLocalGeneration + 1
        try exec(
            """
            UPDATE works SET current_snapshot_id=?,local_generation=?
            WHERE work_id=? AND local_generation=?
              AND current_snapshot_id IS ?
            """,
            [
                .blob(graph.headSnapshotID.bytes), .int(next),
                .text(graph.workID.description), .int(graph.expectedLocalGeneration),
                graph.expectedCurrentSnapshotID.map { .blob($0.bytes) } ?? .null
            ]
        )
        guard try changes() == 1 else { throw SyncV2StoreError.staleCAS }
        try insertHistory(
            workID: graph.workID,
            snapshotID: graph.headSnapshotID,
            reason: "remoteAdoption",
            pinned: false,
            generation: next
        )
        if let head = graph.expectedRemoteHead {
            try validateMonotonicHead(workID: graph.workID, newHead: head)
            try applyRemoteHead(head, workID: graph.workID)
        }
        if let expectedConflict {
            try exec(
                """
                UPDATE sync_intents SET status='parked'
                WHERE work_id=? AND source_snapshot_id=?
                  AND source_generation=? AND status='pending'
                  AND server_instance_id=? AND protocol_epoch=?
                  AND account_id=? AND account_fence=?
                """,
                [
                    .text(graph.workID.description),
                    .blob(expectedConflict.localSnapshotID.bytes),
                    .int(expectedConflict.sourceGeneration)
                ] + binding.values
            )
            try exec(
                """
                UPDATE conflicts SET state='resolved'
                WHERE work_id=? AND conflict_id=? AND current_revision=?
                  AND source_generation=? AND state='active'
                  AND server_instance_id=? AND protocol_epoch=?
                  AND account_id=? AND account_fence=?
                """,
                [
                    .text(graph.workID.description),
                    .text(expectedConflict.conflictID.uuidString.lowercased()),
                    .int(expectedConflict.revision),
                    .int(expectedConflict.sourceGeneration)
                ] + binding.values
            )
            guard try changes() == 1 else {
                throw SyncV2StoreError.staleConflictAction
            }
            try parkBlockedPublishIntent(workID: graph.workID, binding: binding)
        }
        try exec(
            "UPDATE inbox_batches SET state='adopted' WHERE inbox_id=? AND state='verified'",
            [.text(inboxID)]
        )
        guard try changes() == 1 else { throw SyncV2StoreError.inboxNotFound }
    }

    private func validateOrdinaryAdoption(
        workID: WorkID,
        current: WorkRow,
        binding: V2AccountBinding
    ) throws {
        guard try activeConflictRow(workID: workID, binding: binding) == nil else {
            throw SyncV2StoreError.staleConflictAction
        }
        if let bytes = current.currentSnapshotID,
           try isUnpromotedLeaf(workID: workID, snapshotID: SnapshotID(rawValue: bytes.hexString)) {
            throw SyncV2StoreError.staleCAS
        }
        guard current.syncLane == V2SyncLane.normal.rawValue,
              try query(
                  """
                  SELECT 1 FROM sync_intents
                  WHERE work_id=? AND status IN ('pending','sealed') LIMIT 1
                  """,
                  [.text(workID.description)]
              ).isEmpty else {
            throw SyncV2StoreError.staleCAS
        }
    }

    func finalizeConflictRemoteGraphTransaction(
        _ graph: V2RemoteSnapshotGraph,
        request: V2ServerResolutionRequest,
        binding: V2AccountBinding
    ) throws {
        _ = try validateGraph(graph)
        try validateGraphParents(graph)
        guard graph.workID == request.workID,
              graph.headSnapshotID == request.remoteSnapshotID,
              graph.expectedCurrentSnapshotID == request.localSnapshotID,
              graph.expectedLocalGeneration == request.sourceGeneration,
              graph.expectedRemoteHead == request.expectedRemoteHead,
              request.expectedRemoteHead.snapshotID == request.remoteSnapshotID,
              try inboxState(inboxID: graph.inboxID, binding: binding) == "verified" else { throw SyncV2StoreError.staleConflictAction }
        let active = try requireConflict(
            workID: request.workID,
            conflictID: request.conflictID,
            revision: request.revision,
            generation: request.sourceGeneration,
            local: request.localSnapshotID,
            remote: request.remoteSnapshotID,
            scope: .bound(binding)
        )
        guard try conflictInbox(active) == graph.inboxID,
              let current = try scopedWorkRow(
                  workID: request.workID,
                  scope: .bound(binding)
              ),
              let currentGeneration = current.localGeneration else {
            throw SyncV2StoreError.staleConflictAction
        }
        let exactSource = currentGeneration == request.sourceGeneration &&
            current.currentSnapshotID == request.localSnapshotID.bytes
        if exactSource {
            try adoptGraphTransaction(
                graph,
                expectedConflict: request,
                binding: binding
            )
            return
        }
        guard currentGeneration > request.sourceGeneration else {
            throw SyncV2StoreError.staleConflictAction
        }

        for snapshot in try topologicalSnapshots(graph) {
            try insertEncoded(snapshot, workID: request.workID)
        }
        try insertHistory(
            workID: request.workID,
            snapshotID: request.localSnapshotID,
            reason: "preRemoteAdoption",
            pinned: true,
            generation: request.sourceGeneration
        )
        try insertHistory(
            workID: request.workID,
            snapshotID: request.remoteSnapshotID,
            reason: "remoteBaseline",
            pinned: false,
            generation: request.sourceGeneration
        )
        try exec(
            """
            UPDATE sync_intents SET status='parked'
            WHERE work_id=? AND source_snapshot_id=? AND source_generation=?
              AND status='pending'
              AND server_instance_id=? AND protocol_epoch=?
              AND account_id=? AND account_fence=?
            """,
            [
                .text(request.workID.description),
                .blob(request.localSnapshotID.bytes),
                .int(request.sourceGeneration)
            ] + binding.values
        )
        try exec(
            """
            UPDATE conflicts SET state='resolved'
            WHERE work_id=? AND conflict_id=? AND current_revision=?
              AND source_generation=? AND state='active'
              AND server_instance_id=? AND protocol_epoch=?
              AND account_id=? AND account_fence=?
            """,
            [
                .text(request.workID.description),
                .text(request.conflictID.uuidString.lowercased()),
                .int(request.revision), .int(request.sourceGeneration)
            ] + binding.values
        )
        guard try changes() == 1 else {
            throw SyncV2StoreError.staleConflictAction
        }
        try parkBlockedPublishIntent(workID: request.workID, binding: binding)
        try exec(
            "UPDATE inbox_batches SET state='adopted' WHERE inbox_id=? AND state='verified'",
            [.text(graph.inboxID.uuidString.lowercased())]
        )
        guard try changes() == 1 else { throw SyncV2StoreError.inboxNotFound }
        try validateMonotonicHead(
            workID: request.workID,
            newHead: request.expectedRemoteHead
        )
        try applyRemoteHead(request.expectedRemoteHead, workID: request.workID)
    }
}

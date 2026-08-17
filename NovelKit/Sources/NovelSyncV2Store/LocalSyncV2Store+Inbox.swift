import Foundation
import NovelCore
import NovelSyncV2

public extension LocalSyncV2Store {
    func stageRemote(
        _ remote: V2RemoteSnapshot,
        scope: V2LocalWorkScope
    ) throws {
        try stageRemoteGraph(remote.graph, scope: scope)
    }

    func stageRemoteGraph(
        _ graph: V2RemoteSnapshotGraph,
        scope: V2LocalWorkScope
    ) throws {
        guard case let .bound(binding) = scope else {
            throw SyncV2StoreError.accountMismatch
        }
        let anchor = try validateGraph(graph)
        try inTransaction {
            if let work = try scopedWorkRow(workID: graph.workID, scope: scope) {
                guard work[1].text == anchor.documentID.description,
                      work[5].text == anchor.createdAt else {
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
        }
    }

    func verifyInbox(
        inboxID: UUID,
        scope: V2LocalWorkScope
    ) throws {
        guard case let .bound(binding) = scope else {
            throw SyncV2StoreError.accountMismatch
        }
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
    struct GraphAnchor {
        let documentID: DocumentID
        let createdAt: String
    }

    func validateGraph(_ graph: V2RemoteSnapshotGraph) throws -> GraphAnchor {
        guard !graph.snapshots.isEmpty,
              graph.snapshots.map(\.snapshotId).contains(graph.headSnapshotID),
              Set(graph.snapshots.map(\.snapshotId)).count == graph.snapshots.count,
              let expectedRemoteHead = graph.expectedRemoteHead,
              expectedRemoteHead.snapshotID == graph.headSnapshotID else {
            throw SyncV2StoreError.invalidSnapshot
        }
        var anchor: GraphAnchor?
        var parents: [SnapshotID: [SnapshotID]] = [:]
        for snapshot in graph.snapshots {
            guard snapshot.snapshotId == SnapshotID(data: snapshot.manifestBytes),
                  snapshot.manifest.workId == graph.workID else {
                throw SyncV2StoreError.invalidSnapshot
            }
            try SnapshotValidator.validateObjects(snapshot)
            let model = try SnapshotCodec.decode(
                manifestBytes: snapshot.manifestBytes,
                objects: snapshot.objects
            )
            let next = try GraphAnchor(
                documentID: DocumentID(model.document.id),
                createdAt: Self.iso8601(model.documentCreatedAt)
            )
            if let anchor {
                guard anchor.documentID == next.documentID,
                      anchor.createdAt == next.createdAt else {
                    throw SyncV2StoreError.invalidSnapshot
                }
            } else {
                anchor = next
            }
            guard !snapshot.manifest.parentSnapshotIds.contains(snapshot.snapshotId) else {
                throw SyncV2StoreError.invalidSnapshot
            }
            parents[snapshot.snapshotId] = snapshot.manifest.parentSnapshotIds
        }
        try validateAcyclic(parents)
        var reachable = Set<SnapshotID>()
        func collect(_ snapshot: SnapshotID) {
            guard reachable.insert(snapshot).inserted else { return }
            for parent in parents[snapshot, default: []] where parents[parent] != nil {
                collect(parent)
            }
        }
        collect(graph.headSnapshotID)
        guard reachable == Set(parents.keys) else {
            throw SyncV2StoreError.invalidSnapshot
        }
        guard let anchor else { throw SyncV2StoreError.invalidSnapshot }
        return anchor
    }

    func validateAcyclic(_ parents: [SnapshotID: [SnapshotID]]) throws {
        var visiting = Set<SnapshotID>()
        var visited = Set<SnapshotID>()
        func visit(_ snapshot: SnapshotID) throws {
            if visited.contains(snapshot) {
                return
            }
            guard visiting.insert(snapshot).inserted else {
                throw SyncV2StoreError.invalidSnapshot
            }
            for parent in parents[snapshot, default: []] where parents[parent] != nil {
                try visit(parent)
            }
            visiting.remove(snapshot)
            visited.insert(snapshot)
        }
        for snapshot in parents.keys {
            try visit(snapshot)
        }
    }

    func validateGraphParents(_ graph: V2RemoteSnapshotGraph) throws {
        let graphIDs = Set(graph.snapshots.map(\.snapshotId))
        for snapshot in graph.snapshots {
            for parent in snapshot.manifest.parentSnapshotIds where !graphIDs.contains(parent) {
                guard try !query(
                    "SELECT 1 FROM snapshots WHERE work_id=? AND snapshot_id=?",
                    [.text(graph.workID.description), .blob(parent.bytes)]
                ).isEmpty else { throw SyncV2StoreError.invalidSnapshot }
            }
        }
    }

    func graphSnapshot(
        _ snapshotID: SnapshotID,
        in graph: V2RemoteSnapshotGraph
    ) throws -> EncodedSnapshot {
        guard let snapshot = graph.snapshots.first(where: { $0.snapshotId == snapshotID }) else {
            throw SyncV2StoreError.invalidSnapshot
        }
        return snapshot
    }

    func graphObjectUnion(_ graph: V2RemoteSnapshotGraph) throws -> [ObjectID: Data] {
        var result: [ObjectID: Data] = [:]
        for snapshot in graph.snapshots {
            for (objectID, bytes) in snapshot.objects {
                if let existing = result[objectID], existing != bytes {
                    throw SyncV2StoreError.invalidSnapshot
                }
                result[objectID] = bytes
            }
        }
        return result
    }

    func topologicalSnapshots(_ graph: V2RemoteSnapshotGraph) throws -> [EncodedSnapshot] {
        let byID = Dictionary(uniqueKeysWithValues: graph.snapshots.map { ($0.snapshotId, $0) })
        var output: [EncodedSnapshot] = []
        var visited = Set<SnapshotID>()
        func visit(_ snapshot: EncodedSnapshot) throws {
            if visited.contains(snapshot.snapshotId) {
                return
            }
            for parent in snapshot.manifest.parentSnapshotIds {
                if let parentSnapshot = byID[parent] {
                    try visit(parentSnapshot)
                }
            }
            visited.insert(snapshot.snapshotId)
            output.append(snapshot)
        }
        for snapshot in graph.snapshots {
            try visit(snapshot)
        }
        return output
    }

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
        ).first?[0].text else { throw SyncV2StoreError.inboxNotFound }
        return state
    }

    func attestInboxReplay(
        _ graph: V2RemoteSnapshotGraph,
        binding: V2AccountBinding,
        anchor: GraphAnchor
    ) throws {
        let inboxID = graph.inboxID.uuidString.lowercased()
        guard let batch = try query(
            """
            SELECT work_id,document_id,document_created_at,server_instance_id,
                   protocol_epoch,account_id,account_fence,snapshot_id,
                   expected_current_snapshot_id,expected_local_generation,
                   expected_remote_head_snapshot_id,expected_remote_head_generation,
                   state,manifest_bytes
            FROM inbox_batches WHERE inbox_id=?
            """,
            [.text(inboxID)]
        ).first,
            batch[0].text == graph.workID.description,
            batch[1].text == anchor.documentID.description,
            batch[2].text == anchor.createdAt,
            batch[3].text == binding.serverInstanceID,
            batch[4].int64 == binding.protocolEpoch,
            batch[5].text == binding.accountID,
            batch[6].text == binding.accountFence,
            batch[7].blob == graph.headSnapshotID.bytes,
            batch[8].blob == graph.expectedCurrentSnapshotID?.bytes,
            batch[9].int64 == graph.expectedLocalGeneration,
            batch[10].blob == graph.expectedRemoteHead?.snapshotID.bytes,
            batch[11].int64 == graph.expectedRemoteHead?.generation,
            ["staged", "verified", "adopted"].contains(batch[12].text ?? ""),
            try batch[13].blob == graphSnapshot(
                graph.headSnapshotID,
                in: graph
            ).manifestBytes else {
            throw SyncV2StoreError.invalidSnapshot
        }
        let storedSnapshots = try query(
            """
            SELECT snapshot_id,manifest_bytes,is_head FROM inbox_snapshots
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
            guard row[0].blob == snapshot.snapshotIDBytes,
                  row[1].blob == snapshot.manifestBytes,
                  row[2].int64 == (snapshot.snapshotId == graph.headSnapshotID ? 1 : 0) else {
                throw SyncV2StoreError.invalidSnapshot
            }
        }
        let objects = try graphObjectUnion(graph)
        let storedObjects = try query(
            """
            SELECT object_id,byte_count,bytes FROM inbox_objects
            WHERE inbox_id=? ORDER BY object_id
            """,
            [.text(inboxID)]
        )
        let expectedObjects = objects.sorted { $0.key.rawValue < $1.key.rawValue }
        guard storedObjects.count == expectedObjects.count else {
            throw SyncV2StoreError.invalidSnapshot
        }
        for (row, object) in zip(storedObjects, expectedObjects) {
            guard row[0].blob == object.key.bytes,
                  row[1].int64 == Int64(object.value.count),
                  row[2].blob == object.value else {
                throw SyncV2StoreError.invalidSnapshot
            }
        }
        try attestInboxClosure(graph)
    }

    func attestInboxClosure(_ graph: V2RemoteSnapshotGraph) throws {
        let rows = try query(
            """
            SELECT snapshot_id,entity_key,object_id,byte_count,content_type
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
            guard row[0].blob == pair.0.bytes,
                  row[1].text == pair.1.entityKey,
                  row[2].blob == pair.1.objectId.bytes,
                  row[3].int64 == Int64(pair.1.byteCount),
                  row[4].text == pair.1.contentType.rawValue else {
                throw SyncV2StoreError.invalidSnapshot
            }
        }
    }

    func loadInboxGraph(
        inboxID: UUID,
        binding: V2AccountBinding
    ) throws -> V2RemoteSnapshotGraph {
        let text = inboxID.uuidString.lowercased()
        guard let batch = try query(
            """
            SELECT work_id,snapshot_id,expected_current_snapshot_id,
                   expected_local_generation,expected_remote_head_snapshot_id,
                   expected_remote_head_generation,manifest_bytes
            FROM inbox_batches
            WHERE inbox_id=? AND server_instance_id=? AND protocol_epoch=?
              AND account_id=? AND account_fence=?
            """,
            [.text(text)] + binding.values
        ).first,
            let work = batch[0].text,
            let head = batch[1].blob,
            let generation = batch[3].int64 else {
            throw SyncV2StoreError.inboxNotFound
        }
        let workID = try WorkID(uuidString: work)
        var snapshots: [EncodedSnapshot] = []
        for row in try query(
            """
            SELECT snapshot_id,manifest_bytes FROM inbox_snapshots
            WHERE inbox_id=? ORDER BY snapshot_id
            """,
            [.text(text)]
        ) {
            guard let snapshotBytes = row[0].blob,
                  let manifestBytes = row[1].blob else {
                throw SyncV2StoreError.invalidSnapshot
            }
            let manifest = try SnapshotValidator.validate(manifestBytes: manifestBytes)
            guard SnapshotID(data: manifestBytes).bytes == snapshotBytes else {
                throw SyncV2StoreError.invalidSnapshot
            }
            var objects: [ObjectID: Data] = [:]
            for entry in manifest.entries {
                guard let object = try query(
                    """
                    SELECT o.byte_count,o.bytes,c.byte_count,c.content_type
                    FROM inbox_objects o JOIN inbox_closure c
                      ON c.inbox_id=o.inbox_id AND c.object_id=o.object_id
                    WHERE c.inbox_id=? AND c.snapshot_id=?
                      AND c.entity_key=? AND o.verified IN (0,1)
                    """,
                    [.text(text), .blob(snapshotBytes), .text(entry.entityKey)]
                ).first,
                    object[0].int64 == Int64(entry.byteCount),
                    object[2].int64 == Int64(entry.byteCount),
                    object[3].text == entry.contentType.rawValue,
                    let bytes = object[1].blob,
                    ObjectID(data: bytes) == entry.objectId else {
                    throw SyncV2StoreError.invalidSnapshot
                }
                objects[entry.objectId] = bytes
            }
            snapshots.append(EncodedSnapshot(
                manifest: manifest,
                manifestBytes: manifestBytes,
                objects: objects
            ))
        }
        let remoteHead = try Self.head(
            snapshot: batch[4].blob,
            generation: batch[5].int64
        )
        guard let batchManifest = batch[6].blob,
              snapshots.first(where: {
                  $0.snapshotId.bytes == head
              })?.manifestBytes == batchManifest else {
            throw SyncV2StoreError.invalidSnapshot
        }
        let graph = try V2RemoteSnapshotGraph(
            inboxID: inboxID,
            workID: workID,
            headSnapshotID: SnapshotID(rawValue: head.hexString),
            snapshots: snapshots,
            expectedCurrentSnapshotID: batch[2].blob.map {
                try SnapshotID(rawValue: $0.hexString)
            },
            expectedLocalGeneration: generation,
            expectedRemoteHead: remoteHead
        )
        let objectCount = try query(
            "SELECT COUNT(*) FROM inbox_objects WHERE inbox_id=?",
            [.text(text)]
        ).first?[0].int64
        guard try objectCount == Int64(graphObjectUnion(graph).count) else {
            throw SyncV2StoreError.invalidSnapshot
        }
        try attestInboxClosure(graph)
        return graph
    }

    func adoptGraphTransaction(
        _ graph: V2RemoteSnapshotGraph,
        expectedConflict: V2ServerResolutionRequest?,
        binding: V2AccountBinding
    ) throws {
        _ = try validateGraph(graph)
        try validateGraphParents(graph)
        let inboxID = graph.inboxID.uuidString.lowercased()
        guard try inboxState(inboxID: graph.inboxID, binding: binding) == "verified",
              let current = try scopedWorkRow(
                  workID: graph.workID,
                  scope: .bound(binding)
              ),
              current[3].blob == graph.expectedCurrentSnapshotID?.bytes,
              current[2].int64 == graph.expectedLocalGeneration else {
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
        if let previous = current[3].blob,
           let previousID = try? SnapshotID(rawValue: previous.hexString) {
            try insertHistory(
                workID: graph.workID,
                snapshotID: previousID,
                reason: "preRemoteAdoption",
                pinned: true,
                generation: graph.expectedLocalGeneration
            )
        }
        for snapshot in try topologicalSnapshots(graph) {
            try insertEncoded(snapshot, workID: graph.workID)
        }
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
        }
        try exec(
            "UPDATE inbox_batches SET state='adopted' WHERE inbox_id=? AND state='verified'",
            [.text(inboxID)]
        )
        guard try changes() == 1 else { throw SyncV2StoreError.inboxNotFound }
    }

    private func validateOrdinaryAdoption(
        workID: WorkID,
        current: [SQLiteValue],
        binding: V2AccountBinding
    ) throws {
        guard try activeConflictRow(workID: workID, binding: binding) == nil else {
            throw SyncV2StoreError.staleConflictAction
        }
        guard current[6].text == V2SyncLane.normal.rawValue,
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
              let currentGeneration = current[2].int64 else {
            throw SyncV2StoreError.staleConflictAction
        }
        let exactSource = currentGeneration == request.sourceGeneration &&
            current[3].blob == request.localSnapshotID.bytes
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

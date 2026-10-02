import Foundation
import NovelCore
import NovelSyncV2

/// Uses the caller-owned transaction; never begins or commits one.
extension InboxRepository {
    func persistStagedGraphInTransaction(
        _ graph: V2RemoteSnapshotGraph,
        binding: V2AccountBinding,
        anchor: InboxRepository.GraphAnchor
    ) throws {
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
    }
}

extension InboxRepository {
    func loadInboxGraph(
        inboxID: UUID,
        binding: V2AccountBinding
    ) throws -> V2RemoteSnapshotGraph {
        let text = inboxID.uuidString.lowercased()
        guard let batch = try queryRows(
            InboxBatchRow.self,
            """
            SELECT \(InboxBatchRow.columns)
            FROM inbox_batches
            WHERE inbox_id=? AND server_instance_id=? AND protocol_epoch=?
              AND account_id=? AND account_fence=?
            """,
            [.text(text)] + binding.values
        ).first,
            let work = batch.workID,
            let head = batch.snapshotID,
            let generation = batch.expectedLocalGeneration else {
            throw SyncV2StoreError.inboxNotFound
        }
        let workID = try WorkID(uuidString: work)
        var snapshots: [EncodedSnapshot] = []
        // Keep one verified allocation per object across the complete history.
        var objectBytes: [ObjectID: Data] = [:]
        for row in try queryRows(
            InboxObjectRow.self,
            "SELECT \(InboxObjectRow.columns) FROM inbox_objects WHERE inbox_id=? ORDER BY object_id", [.text(text)]
        ) {
            guard let id = row.objectID, let bytes = row.bytes,
                  row.byteCount == Int64(bytes.count), [0, 1].contains(row.verified),
                  ObjectID(data: bytes).bytes == id else { throw SyncV2StoreError.invalidSnapshot }
            try objectBytes[ObjectID(rawValue: id.hexString)] = bytes
        }

        for row in try queryRows(
            InboxSnapshotRow.self,
            """
            SELECT \(InboxSnapshotRow.columns) FROM inbox_snapshots
            WHERE inbox_id=? ORDER BY snapshot_id
            """,
            [.text(text)]
        ) {
            guard let snapshotBytes = row.snapshotID,
                  let manifestBytes = row.manifestBytes,
                  row.workID == work,
                  row.isHead == (snapshotBytes == head ? 1 : 0),
                  [0, 1].contains(row.verified) else {
                throw SyncV2StoreError.invalidSnapshot
            }
            let manifest = try SnapshotValidator.validate(manifestBytes: manifestBytes)
            guard SnapshotID(data: manifestBytes).bytes == snapshotBytes else {
                throw SyncV2StoreError.invalidSnapshot
            }
            var objects: [ObjectID: Data] = [:]
            for entry in manifest.entries {
                guard let bytes = objectBytes[entry.objectId], bytes.count == entry.byteCount else {
                    throw SyncV2StoreError.invalidSnapshot
                }
                objects[entry.objectId] = objectBytes[entry.objectId]
            }
            snapshots.append(EncodedSnapshot(
                manifest: manifest,
                manifestBytes: manifestBytes,
                objects: objects
            ))
        }
        let remoteHead = try StoreValueCoding.head(
            snapshot: batch.expectedRemoteHeadSnapshotID,
            generation: batch.expectedRemoteHeadGeneration
        )
        guard let batchManifest = batch.manifestBytes,
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
            expectedCurrentSnapshotID: batch.expectedCurrentSnapshotID.map {
                try SnapshotID(rawValue: $0.hexString)
            },
            expectedLocalGeneration: generation,
            expectedRemoteHead: remoteHead
        )
        let objectCount = try query(
            "SELECT COUNT(*) FROM inbox_objects WHERE inbox_id=?",
            [.text(text)]
        ).first?.scalar.int64
        guard try objectCount == Int64(graphObjectUnion(graph).count) else {
            throw SyncV2StoreError.invalidSnapshot
        }
        try attestInboxClosure(graph)
        return graph
    }
}

extension InboxRepository {
    func recordInboxValidation(_ graph: V2RemoteSnapshotGraph) throws {
        try exec("INSERT OR REPLACE INTO schema_meta(key,value,checksum) VALUES(?,?,?)",
                 [.text("inbox-validator/" + graph.inboxID.uuidString.lowercased()),
                  .text(InboxRepository.inboxValidatorVersion), .blob(graph.headSnapshotID.bytes)])
    }

    func validateGraph(_ graph: V2RemoteSnapshotGraph, forceFull: Bool = false) throws -> InboxRepository.GraphAnchor {
        let marker = try queryRows(
            SchemaMarkerRow.self,
            "SELECT \(SchemaMarkerRow.columns) FROM schema_meta WHERE key=?",
            [.text("inbox-validator/" + graph.inboxID.uuidString.lowercased())]
        ).first
        let full = forceFull || marker?.value != InboxRepository.inboxValidatorVersion ||
            marker?.checksum != graph.headSnapshotID.bytes
        return try InboxRepository.validateGraphContent(graph, full: full)
    }

    func validateAcyclic(_ parents: [SnapshotID: [SnapshotID]]) throws {
        try InboxRepository.validateAcyclicContent(parents)
    }

    func validateGraphParents(_ graph: V2RemoteSnapshotGraph) throws {
        let graphIDs = Set(graph.snapshots.map(\.snapshotId))
        for snapshot in graph.snapshots {
            for parent in snapshot.manifest.parentSnapshotIds where !graphIDs.contains(parent) {
                if try hasSnapshot(workID: graph.workID, snapshotID: parent) {
                    continue
                }
                if try isBoundary(workID: graph.workID, snapshotID: parent) {
                    continue
                }
                if try hasBoundaries(workID: graph.workID) {
                    throw SyncV2StoreError.historyIncomplete
                }
                throw SyncV2StoreError.invalidSnapshot
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
        var byID: [SnapshotID: EncodedSnapshot] = [:]
        for snapshot in graph.snapshots {
            guard byID.updateValue(snapshot, forKey: snapshot.snapshotId) == nil else {
                throw SyncV2StoreError.invalidSnapshot
            }
        }
        var output: [EncodedSnapshot] = []
        var visited = Set<SnapshotID>()
        var active = Set<SnapshotID>()
        for snapshot in graph.snapshots {
            var stack: [(SnapshotID, Bool)] = [(snapshot.snapshotId, false)]
            while let (id, exiting) = stack.popLast() {
                guard !visited.contains(id), let current = byID[id] else { continue }
                if exiting {
                    active.remove(id)
                    visited.insert(id)
                    output.append(current)
                } else {
                    guard active.insert(id).inserted else { throw SyncV2StoreError.invalidSnapshot }
                    stack.append((id, true))
                    for parent in current.manifest.parentSnapshotIds.reversed() {
                        stack.append((parent, false))
                    }
                }
            }
        }
        return output
    }
}

extension InboxRepository {
    static let inboxValidatorVersion = "1"

    struct GraphAnchor: Sendable {
        let documentID: DocumentID
        let createdAt: String
    }

    static func validateGraphContent(_ graph: V2RemoteSnapshotGraph, full: Bool) throws -> GraphAnchor {
        guard !graph.snapshots.isEmpty,
              graph.snapshots.map(\.snapshotId).contains(graph.headSnapshotID),
              Set(graph.snapshots.map(\.snapshotId)).count == graph.snapshots.count,
              let expectedRemoteHead = graph.expectedRemoteHead,
              expectedRemoteHead.snapshotID == graph.headSnapshotID else {
            throw SyncV2StoreError.invalidSnapshot
        }
        if full {
            try SnapshotValidator.validateGraphObjects(graph.snapshots)
        }
        var anchor: GraphAnchor?
        var anchorID: ObjectID?
        var parents: [SnapshotID: [SnapshotID]] = [:]
        for snapshot in graph.snapshots {
            try Task.checkCancellation()
            guard snapshot.snapshotId == SnapshotID(data: snapshot.manifestBytes),
                  snapshot.manifest.workId == graph.workID,
                  Set(snapshot.objects.keys) == Set(snapshot.manifest.entries.map(\.objectId)) else {
                throw SyncV2StoreError.invalidSnapshot
            }
            guard let documentEntry = snapshot.manifest.entries.first(where: { $0.entityKey == "work/document" }) else {
                throw SyncV2StoreError.invalidSnapshot
            }
            if let anchorID, anchorID != documentEntry.objectId {
                throw SyncV2StoreError.invalidSnapshot
            }
            anchorID = documentEntry.objectId
            if anchor == nil {
                let model = try SnapshotCodec.decode(snapshot)
                anchor = try GraphAnchor(documentID: DocumentID(model.document.id),
                                         createdAt: StoreValueCoding.iso8601(model.documentCreatedAt))
            }
            guard !snapshot.manifest.parentSnapshotIds.contains(snapshot.snapshotId) else {
                throw SyncV2StoreError.invalidSnapshot
            }
            parents[snapshot.snapshotId] = snapshot.manifest.parentSnapshotIds
        }
        try InboxRepository.validateAcyclicContent(parents)
        var reachable = Set<SnapshotID>()
        var pending = [graph.headSnapshotID]
        while let snapshot = pending.popLast() {
            guard reachable.insert(snapshot).inserted else { continue }
            pending.append(contentsOf: parents[snapshot, default: []].filter { parents[$0] != nil })
        }
        guard reachable == Set(parents.keys) else {
            throw SyncV2StoreError.invalidSnapshot
        }
        guard let anchor else { throw SyncV2StoreError.invalidSnapshot }
        return anchor
    }

    static func validateAcyclicContent(_ parents: [SnapshotID: [SnapshotID]]) throws {
        var visiting = Set<SnapshotID>()
        var visited = Set<SnapshotID>()
        for root in parents.keys where !visited.contains(root) {
            var pending: [(id: SnapshotID, finishing: Bool)] = [(root, false)]
            while let next = pending.popLast() {
                if visited.contains(next.id) {
                    continue
                }
                if next.finishing {
                    visiting.remove(next.id)
                    visited.insert(next.id)
                    continue
                }
                guard visiting.insert(next.id).inserted else {
                    throw SyncV2StoreError.invalidSnapshot
                }
                pending.append((next.id, true))
                for parent in parents[next.id, default: []] where parents[parent] != nil {
                    pending.append((parent, false))
                }
            }
        }
    }
}

extension InboxRepository {
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
}

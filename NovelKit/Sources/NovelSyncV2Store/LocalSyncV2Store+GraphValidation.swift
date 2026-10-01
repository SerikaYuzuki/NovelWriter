import Foundation
import NovelCore
import NovelSyncV2

extension LocalSyncV2Store {
    private static let inboxValidatorVersion = "1"

    func recordInboxValidation(_ graph: V2RemoteSnapshotGraph) throws {
        try exec("INSERT OR REPLACE INTO schema_meta(key,value,checksum) VALUES(?,?,?)",
                 [.text("inbox-validator/" + graph.inboxID.uuidString.lowercased()),
                  .text(Self.inboxValidatorVersion), .blob(graph.headSnapshotID.bytes)])
    }

    struct GraphAnchor: Sendable {
        let documentID: DocumentID
        let createdAt: String
    }

    func validateGraph(_ graph: V2RemoteSnapshotGraph, forceFull: Bool = false) throws -> GraphAnchor {
        let marker = try query("SELECT value,checksum FROM schema_meta WHERE key=?",
                               [.text("inbox-validator/" + graph.inboxID.uuidString.lowercased())]).first
        let full = forceFull || marker?[0].text != Self.inboxValidatorVersion || marker?[1].blob != graph.headSnapshotID.bytes
        return try Self.validateGraphContent(graph, full: full)
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
                  snapshot.manifest.workId == graph.workID else {
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
                                         createdAt: Self.iso8601(model.documentCreatedAt))
            }
            guard !snapshot.manifest.parentSnapshotIds.contains(snapshot.snapshotId) else {
                throw SyncV2StoreError.invalidSnapshot
            }
            parents[snapshot.snapshotId] = snapshot.manifest.parentSnapshotIds
        }
        try Self.validateAcyclicContent(parents)
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

    func validateAcyclic(_ parents: [SnapshotID: [SnapshotID]]) throws {
        try Self.validateAcyclicContent(parents)
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

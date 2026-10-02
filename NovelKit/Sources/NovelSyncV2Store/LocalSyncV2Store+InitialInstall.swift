import Foundation
import NovelSyncV2

/// Created only by full graph validation; callers cannot forge an unchecked token.
public struct V2ValidatedInitialGraph: Sendable {
    let graph: V2RemoteSnapshotGraph
    let anchor: LocalSyncV2Store.GraphAnchor
}

public extension LocalSyncV2Store {
    /// Called only by remote-only open, before any document/editor session exists.
    /// CPU validation is detached; all mutable scope/CAS checks repeat after it.
    func installInitialGraph(_ graph: V2RemoteSnapshotGraph, scope: V2LocalWorkScope) async throws {
        let prepared = try await Self.prepareInitialGraph(graph)
        try installInitialGraph(prepared, scope: scope)
    }

    /// Runtime checks the live account again after this await and before install.
    static func prepareInitialGraph(_ graph: V2RemoteSnapshotGraph) async throws -> V2ValidatedInitialGraph {
        let validation = Task.detached { try Self.validateGraphContent(graph, full: true) }
        let anchor = try await withTaskCancellationHandler {
            try await validation.value
        } onCancel: { validation.cancel() }
        try Task.checkCancellation()
        return V2ValidatedInitialGraph(graph: graph, anchor: anchor)
    }

    func installInitialGraph(_ prepared: V2ValidatedInitialGraph, scope: V2LocalWorkScope) throws {
        try installPreparedGraph(prepared, scope: scope, shallow: false)
    }

    func installShallowHead(_ prepared: V2ValidatedInitialGraph, scope: V2LocalWorkScope) throws {
        guard prepared.graph.snapshots.count == 1 else { throw SyncV2StoreError.invalidSnapshot }
        try installPreparedGraph(prepared, scope: scope, shallow: true)
    }

    func installShallowHead(_ graph: V2RemoteSnapshotGraph, scope: V2LocalWorkScope) async throws {
        let prepared = try await Self.prepareInitialGraph(graph)
        try installShallowHead(prepared, scope: scope)
    }

    private func installPreparedGraph(_ prepared: V2ValidatedInitialGraph, scope: V2LocalWorkScope, shallow: Bool) throws {
        let graph = prepared.graph
        let anchor = prepared.anchor
        guard case let .bound(binding) = scope,
              graph.expectedCurrentSnapshotID == nil, graph.expectedLocalGeneration == 0 else {
            throw SyncV2StoreError.staleCAS
        }
        try Task.checkCancellation()
        try inTransaction {
            try requireNotDeleting(graph.workID)
            if let work = try scopedWorkRow(workID: graph.workID, scope: scope) {
                guard work.localGeneration == 0, work.currentSnapshotID == nil,
                      work.documentID == anchor.documentID.description,
                      work.documentCreatedAt == anchor.createdAt,
                      work.syncLane == V2SyncLane.normal.rawValue else { throw SyncV2StoreError.staleCAS }
            } else {
                guard try !workExists(workID: graph.workID) else { throw SyncV2StoreError.accountMismatch }
                try insertWork(workID: graph.workID, documentID: anchor.documentID,
                               documentCreatedAt: anchor.createdAt, lane: .normal, scope: scope)
            }
            guard try activeConflictRow(workID: graph.workID, binding: binding) == nil,
                  try query("SELECT 1 FROM sync_intents WHERE work_id=? AND status IN ('pending','sealed') LIMIT 1",
                            [.text(graph.workID.description)]).isEmpty else { throw SyncV2StoreError.staleCAS }
            if !shallow {
                try validateGraphParents(graph)
            }
            for snapshot in try topologicalSnapshots(graph) {
                try Task.checkCancellation()
                try insertValidatedEncoded(snapshot, workID: graph.workID, verifiedRemote: shallow)
            }
            try Task.checkCancellation()
            try exec("UPDATE works SET current_snapshot_id=?,local_generation=1 WHERE work_id=? AND local_generation=0 AND current_snapshot_id IS NULL",
                     [.blob(graph.headSnapshotID.bytes), .text(graph.workID.description)])
            guard try changes() == 1 else { throw SyncV2StoreError.staleCAS }
            try insertHistory(workID: graph.workID, snapshotID: graph.headSnapshotID,
                              reason: "remoteAdoption", pinned: false, generation: 1)
            if let head = graph.expectedRemoteHead {
                try validateMonotonicHead(workID: graph.workID, newHead: head)
                try applyRemoteHead(head, workID: graph.workID)
            }
            if shallow {
                try exec("""
                INSERT INTO history_backfills(work_id,root_snapshot_id,server_instance_id,protocol_epoch,
                  account_id,account_fence,state,updated_at) VALUES(?,?,?,?,?,?,'running',?)
                """, [.text(graph.workID.description), .blob(graph.headSnapshotID.bytes)] + binding.values + [.text(Self.now())])
            }
            guard try bindingIsActive(workID: graph.workID, binding: binding) else { throw SyncV2StoreError.accountMismatch }
            // Cancellation during the final metadata writes must still roll back.
            try Task.checkCancellation()
        }
    }
}

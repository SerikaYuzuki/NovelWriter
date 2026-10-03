import Foundation
import NovelCore
import NovelSyncV2

public extension LocalSyncV2Store {
    func stageRemote(
        _ remote: V2RemoteSnapshot,
        scope: V2LocalWorkScope
    ) throws {
        let anchor = try InboxRepository.validateGraphContent(remote.graph, full: true)
        try stageValidatedGraph(remote.graph, scope: scope, anchor: anchor)
    }

    func stageRemoteGraph(
        _ graph: V2RemoteSnapshotGraph,
        scope: V2LocalWorkScope
    ) async throws {
        let validation = Task.detached { try InboxRepository.validateGraphContent(graph, full: true) }
        let anchor = try await withTaskCancellationHandler {
            try await validation.value
        } onCancel: { validation.cancel() }
        try stageValidatedGraph(graph, scope: scope, anchor: anchor)
    }

    private func stageValidatedGraph(
        _ graph: V2RemoteSnapshotGraph, scope: V2LocalWorkScope, anchor: InboxRepository.GraphAnchor
    ) throws {
        try Task.checkCancellation()
        try deletionRepository.requireNotDeleting(graph.workID)
        guard case let .bound(binding) = scope else {
            throw SyncV2StoreError.accountMismatch
        }
        try Task.checkCancellation()
        try inTransaction {
            if let work = try workRepository.scopedWorkRow(workID: graph.workID, scope: scope) {
                guard work.documentID == anchor.documentID.description,
                      work.documentCreatedAt == anchor.createdAt else {
                    throw SyncV2StoreError.invalidSnapshot
                }
            } else if try workRepository.workExists(workID: graph.workID) {
                throw SyncV2StoreError.workNotFound
            } else {
                try workRepository.insertWork(
                    workID: graph.workID,
                    documentID: anchor.documentID,
                    documentCreatedAt: anchor.createdAt,
                    lane: .normal,
                    scope: scope
                )
            }
            try inboxRepository.validateGraphParents(graph)
            if try inboxRepository.inboxExists(inboxID: graph.inboxID) {
                try inboxRepository.attestInboxReplay(graph, binding: binding, anchor: anchor)
                return
            }
            try inboxRepository.persistStagedGraphInTransaction(graph, binding: binding, anchor: anchor)
            try inboxRepository.recordInboxValidation(graph)
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
        let state = try inboxRepository.inboxState(inboxID: inboxID, binding: binding)
        guard state == "staged" || state == "verified" || state == "adopted" else {
            throw SyncV2StoreError.inboxNotFound
        }
        let graph = try inboxRepository.loadInboxGraph(inboxID: inboxID, binding: binding)
        _ = try inboxRepository.validateGraph(graph)
        try inboxRepository.validateGraphParents(graph)
        if state == "verified" || state == "adopted" {
            return
        }
        try inTransaction {
            try inboxRepository.markVerifiedInTransaction(inboxID: inboxID)
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
        let state = try inboxRepository.inboxState(inboxID: inboxID, binding: binding)
        if state == "adopted" {
            return
        }
        guard state == "verified" else { throw SyncV2StoreError.inboxNotFound }
        let graph = try inboxRepository.loadInboxGraph(inboxID: inboxID, binding: binding)
        try inTransaction {
            try inboxRepository.adoptGraphTransaction(graph, expectedConflict: nil, binding: binding)
        }
    }
}

/// Created only by full graph validation; callers cannot forge an unchecked token.
public struct V2ValidatedInitialGraph: Sendable {
    let graph: V2RemoteSnapshotGraph
    let anchor: InboxRepository.GraphAnchor
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
        let validation = Task.detached { try InboxRepository.validateGraphContent(graph, full: true) }
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

    private func installPreparedGraph(
        _ prepared: V2ValidatedInitialGraph,
        scope: V2LocalWorkScope,
        shallow: Bool
    ) throws {
        let graph = prepared.graph
        let anchor = prepared.anchor
        guard case let .bound(binding) = scope,
              graph.expectedCurrentSnapshotID == nil, graph.expectedLocalGeneration == 0 else {
            throw SyncV2StoreError.staleCAS
        }
        try Task.checkCancellation()
        try inTransaction {
            try deletionRepository.requireNotDeleting(graph.workID)
            if let work = try workRepository.scopedWorkRow(workID: graph.workID, scope: scope) {
                guard work.localGeneration == 0, work.currentSnapshotID == nil,
                      work.documentID == anchor.documentID.description,
                      work.documentCreatedAt == anchor.createdAt,
                      work.syncLane == V2SyncLane.normal.rawValue else { throw SyncV2StoreError.staleCAS }
            } else {
                guard try !workRepository.workExists(workID: graph.workID) else {
                    throw SyncV2StoreError.accountMismatch
                }
                try workRepository.insertWork(workID: graph.workID, documentID: anchor.documentID,
                                              documentCreatedAt: anchor.createdAt, lane: .normal, scope: scope)
            }
            guard try conflictRepository.activeConflictRow(workID: graph.workID, binding: binding) == nil,
                  try outboxRepository.hasNoPendingOrSealedIntents(workID: graph.workID) else {
                throw SyncV2StoreError.staleCAS
            }
            if !shallow {
                try inboxRepository.validateGraphParents(graph)
            }
            for snapshot in try inboxRepository.topologicalSnapshots(graph) {
                try Task.checkCancellation()
                try workRepository.insertValidatedEncoded(snapshot, workID: graph.workID, verifiedRemote: shallow)
            }
            try Task.checkCancellation()
            try workRepository.installInitialHeadInTransaction(graph: graph)
            try workRepository.insertHistory(workID: graph.workID, snapshotID: graph.headSnapshotID,
                                             reason: "remoteAdoption", pinned: false, generation: 1)
            if let head = graph.expectedRemoteHead {
                try outboxRepository.validateMonotonicHead(workID: graph.workID, newHead: head)
                try outboxRepository.applyRemoteHead(head, workID: graph.workID)
            }
            if shallow {
                try inboxRepository.beginBackfillInTransaction(graph: graph, binding: binding)
            }
            guard try accountRepository.bindingIsActive(workID: graph.workID, binding: binding) else {
                throw SyncV2StoreError.accountMismatch
            }
            // Cancellation during the final metadata writes must still roll back.
            try Task.checkCancellation()
        }
    }
}

public extension LocalSyncV2Store {
    func remoteHeadForConflict(
        _ conflict: V2ConflictCandidate,
        scope: V2LocalWorkScope
    ) throws -> V2RemoteHead {
        try inboxRepository.remoteHeadForConflict(conflict, scope: scope)
    }

    func conflictInboxID(_ conflict: V2ConflictCandidate) throws -> UUID {
        try inboxRepository.conflictInboxID(conflict)
    }

    func pendingServerAdoption(
        workID: WorkID,
        scope: V2LocalWorkScope
    ) throws -> V2PendingServerAdoption? {
        try inboxRepository.pendingServerAdoption(workID: workID, scope: scope)
    }

    func adoptPendingServerResolution(
        workID: WorkID,
        inboxID: UUID,
        scope: V2LocalWorkScope
    ) throws -> V2OpenResult {
        guard case let .bound(binding) = scope,
              let pending = try inboxRepository.pendingServerAdoption(workID: workID, scope: scope),
              pending.inboxID == inboxID else {
            throw SyncV2StoreError.staleCAS
        }
        let graph = try inboxRepository.loadInboxGraph(inboxID: inboxID, binding: binding)
        guard let remoteHead = graph.expectedRemoteHead else {
            throw SyncV2StoreError.invalidRemoteHead
        }
        if pending.requiresExplicitConfirmation {
            try inTransaction {
                guard let recovery = try conflictRepository.recoveredMultipleResolution(workID: workID, scope: scope),
                      recovery == pending else { throw SyncV2StoreError.staleCAS }
                // Rebase only the mutable CAS expectation, never the graph's
                // immutable manifest/object bytes. The platform gate proved
                // this exact saved generation before entering the Store.
                let rebased = V2RemoteSnapshotGraph(
                    inboxID: graph.inboxID, workID: graph.workID,
                    headSnapshotID: graph.headSnapshotID, snapshots: graph.snapshots,
                    expectedCurrentSnapshotID: pending.expectedCurrentSnapshotID,
                    expectedLocalGeneration: pending.expectedLocalGeneration,
                    expectedRemoteHead: graph.expectedRemoteHead
                )
                try inboxRepository.adoptGraphTransaction(rebased, expectedConflict: nil, binding: binding)
                try exec("""
                UPDATE inbox_batches SET state='rejected',rejection_code='recoveredConflictDuplicate'
                WHERE work_id=? AND snapshot_id=? AND state='verified'
                  AND server_instance_id=? AND protocol_epoch=? AND account_id=? AND account_fence=?
                """, [.text(workID.description), .blob(graph.headSnapshotID.bytes)] + binding.values)
            }
            return try workRepository.open(workID: workID, scope: scope)
        }
        guard let active = try conflictRepository.activeConflict(
            workID: workID,
            scope: scope
        ) else {
            throw SyncV2StoreError.staleConflictAction
        }
        let request = V2ServerResolutionRequest(
            workID: workID,
            conflictID: pending.conflictID,
            revision: pending.conflictRevision,
            sourceGeneration: active.sourceGeneration,
            localSnapshotID: active.localSnapshotID,
            remoteSnapshotID: graph.headSnapshotID,
            inboxID: inboxID,
            expectedRemoteHead: remoteHead
        )
        try inTransaction {
            let exactSource = pending.expectedLocalGeneration == active.sourceGeneration &&
                pending.expectedCurrentSnapshotID == active.localSnapshotID
            if exactSource {
                try inboxRepository.adoptGraphTransaction(graph, expectedConflict: request, binding: binding)
            } else {
                try inboxRepository.finalizeConflictRemoteGraphTransaction(
                    graph,
                    request: request,
                    binding: binding
                )
            }
        }
        return try workRepository.open(workID: workID, scope: scope)
    }
}

public extension LocalSyncV2Store {
    /// Adopts a verified remote descendant after proving that it already
    /// contains the exact still-pending local checkpoint.
    func adoptInboxSubsumingPendingIntent(
        inboxID: UUID,
        intentID: UUID,
        scope: V2LocalWorkScope
    ) throws {
        guard case let .bound(binding) = scope else {
            throw SyncV2StoreError.accountMismatch
        }
        try inTransaction {
            if try inboxRepository.subsumptionWasApplied(
                inboxID: inboxID,
                intentID: intentID,
                binding: binding
            ) {
                return
            }
            let graph = try inboxRepository.loadInboxGraph(inboxID: inboxID, binding: binding)
            guard try inboxRepository.inboxState(inboxID: inboxID, binding: binding) == "verified" else {
                throw SyncV2StoreError.inboxNotFound
            }
            _ = try inboxRepository.validateGraph(graph)
            try inboxRepository.validateGraphParents(graph)
            let intent = try inboxRepository.pendingSubsumptionIntent(
                intentID: intentID,
                graph: graph,
                binding: binding
            )
            guard intent.snapshotID != graph.headSnapshotID,
                  try conflictRepository.graphHead(graph, containsAncestor: intent.snapshotID) else {
                throw SyncV2StoreError.staleCAS
            }
            try inboxRepository.acknowledgeSubsumedIntent(intent, binding: binding)
            try inboxRepository.adoptGraphTransaction(graph, expectedConflict: nil, binding: binding)
            try inboxRepository.recordSubsumption(
                intent,
                inboxID: inboxID,
                remoteHead: inboxRepository.requiredRemoteHead(graph),
                binding: binding
            )
        }
    }
}

public struct V2PendingFastForward: Hashable, Sendable {
    public let inboxID: UUID
    public let snapshotID: SnapshotID
    public let generation: Int64
}

public extension LocalSyncV2Store {
    /// A verified ancestor receipt, or a verified descendant of already
    /// received current content, can authorize this Inbox across restart.
    /// No editor mutation happens here.
    func pendingFastForward(workID: WorkID, scope: V2LocalWorkScope) throws -> V2PendingFastForward? {
        try inboxRepository.pendingFastForward(workID: workID, scope: scope)
    }

    /// Called only through the application's consumed document gate. The DB
    /// transaction repeats the generation/pending-intent checks before install.
    func adoptPendingFastForward(workID: WorkID, inboxID: UUID, scope: V2LocalWorkScope) throws -> V2OpenResult {
        try inTransaction {
            guard let pending = try inboxRepository.pendingFastForward(workID: workID, scope: scope),
                  pending.inboxID == inboxID,
                  case let .bound(binding) = scope else { throw SyncV2StoreError.staleCAS }
            let graph = try inboxRepository.loadInboxGraph(inboxID: inboxID, binding: binding)
            try inboxRepository.adoptGraphTransaction(graph, expectedConflict: nil, binding: binding)
        }
        return try workRepository.open(workID: workID, scope: scope)
    }
}

public extension LocalSyncV2Store {
    func backfillState(workID: WorkID) throws -> V2BackfillState? {
        try inboxRepository.backfillState(workID: workID)
    }

    func backfillWorkIDs() throws -> [WorkID] {
        try inboxRepository.backfillWorkIDs()
    }

    func snapshotAvailability(workID: WorkID, snapshotID: SnapshotID,
                              scope: V2LocalWorkScope) throws -> V2SnapshotAvailability {
        try inboxRepository.snapshotAvailability(workID: workID, snapshotID: snapshotID, scope: scope)
    }

    /// Same account/fence restart is idempotent. Foreign accounts remain parked
    /// through the existing account binding; they cannot mutate this journal.
    func resumeBackfill(workID: WorkID, binding: V2AccountBinding, manual: Bool = false) throws -> V2BackfillState? {
        try inTransaction {
            try deletionRepository.requireNotDeleting(workID)
            guard let state = try inboxRepository.backfillState(workID: workID) else { return nil }
            guard state.binding.accountID == binding.accountID,
                  state.binding.serverInstanceID == binding.serverInstanceID,
                  state.binding.protocolEpoch == binding.protocolEpoch,
                  try accountRepository.bindingIsActive(workID: workID, binding: binding) else {
                throw SyncV2StoreError.accountMismatch
            }
            guard state.status == .running || state.status == .paused || (manual && state.status == .failed) else {
                return nil
            }
            if state.binding != binding {
                try inboxRepository.resetBackfillFenceInTransaction(workID: workID, binding: binding)
            }
            try inboxRepository.setBackfillStatus(workID: workID, binding: binding, status: .running)
            return try inboxRepository.backfillState(workID: workID)
        }
    }

    func setBackfillStatus(
        workID: WorkID,
        binding: V2AccountBinding,
        status: V2BackfillStatus,
        failureCode: String? = nil
    ) throws {
        try inboxRepository.setBackfillStatus(
            workID: workID,
            binding: binding,
            status: status,
            failureCode: failureCode
        )
    }

    func applyBackfillPage(_ page: V2BackfillPage, workID: WorkID, binding: V2AccountBinding,
                           root: SnapshotID, expectedCursor: String?) async throws {
        try Task.checkCancellation()
        let validation = Task.detached { try SnapshotValidator.validateGraphObjects(page.snapshots) }
        try await withTaskCancellationHandler {
            try await validation.value
        } onCancel: { validation.cancel() }
        try Task.checkCancellation()
        let began = ContinuousClock.now
        try inTransaction {
            try deletionRepository.requireNotDeleting(workID)
            guard try accountRepository.bindingIsActive(workID: workID, binding: binding),
                  let state = try inboxRepository.backfillState(workID: workID), state.binding == binding,
                  state.rootSnapshotID == root, state.resumeCursor == expectedCursor,
                  state.status == .running else { throw SyncV2StoreError.staleCAS }
            let anchor = try workRepository.backfillRootDocumentObject(root: root)
            try inboxRepository.validateBackfillBudget(page.snapshots, workID: workID)
            var received: Int64 = 0
            var seen = Set<SnapshotID>()
            for snapshot in page.snapshots {
                try Task.checkCancellation()
                guard seen.insert(snapshot.snapshotId).inserted,
                      snapshot.snapshotId == SnapshotID(data: snapshot.manifestBytes),
                      snapshot.manifest.workId == workID,
                      !snapshot.manifest.parentSnapshotIds.contains(snapshot.snapshotId),
                      Set(snapshot.objects.keys) == Set(snapshot.manifest.entries.map(\.objectId)),
                      snapshot.manifest.entries.first(where: { $0.entityKey == "work/document" })?.objectId
                      .bytes == anchor else {
                    throw SyncV2StoreError.invalidSnapshot
                }
                let existing = try inboxRepository.hasSnapshot(workID: workID, snapshotID: snapshot.snapshotId)
                // Children precede parents. Existing ancestors can replay after a
                // fence change, but unrelated existing local snapshots cannot.
                guard try inboxRepository.isBoundary(workID: workID, snapshotID: snapshot.snapshotId) ||
                    (existing && inboxRepository.isAncestorOfBackfillRoot(
                        snapshot.snapshotId,
                        workID: workID,
                        root: root
                    )) else {
                    throw SyncV2StoreError.invalidSnapshot
                }
                try workRepository.insertValidatedEncoded(snapshot, workID: workID, verifiedRemote: true)
                if !existing {
                    received += 1
                }
            }
            guard try !page.terminal || !inboxRepository.hasBoundaries(workID: workID) else {
                throw SyncV2StoreError.invalidSnapshot
            }
            try inboxRepository.recordBackfillPageInTransaction(page, workID: workID, received: received)
            try Task.checkCancellation()
        }
        lastBackfillWriteDuration = began.duration(to: .now)
        executor.registeredAncestorCache = nil
    }
}

public extension LocalSyncV2Store {
    func backfillObject(_ entry: SnapshotEntry, workID: WorkID, binding: V2AccountBinding) throws -> Data? {
        try inboxRepository.backfillObject(entry, workID: workID, binding: binding)
    }
}

public extension LocalSyncV2Store {
    func backfillProgressNote(workID: WorkID) throws -> String? {
        try inboxRepository.backfillProgressNote(workID: workID)
    }
}

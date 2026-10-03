import Foundation
import NovelCore
import NovelSyncV2

public extension LocalSyncV2Store {
    func appendConflict(
        workID: WorkID,
        baseSnapshotID: SnapshotID?,
        localSnapshotID: SnapshotID,
        remote: V2RemoteSnapshot,
        sourceGeneration: Int64,
        scope: V2LocalWorkScope
    ) throws -> V2ConflictCandidate {
        guard case let .bound(binding) = scope,
              remote.workID == workID,
              let remoteHead = remote.expectedRemoteHead,
              remoteHead.snapshotID == remote.encoded.snapshotId,
              let work = try workRepository.scopedWorkRow(workID: workID, scope: scope),
              work.localGeneration == sourceGeneration,
              work.currentSnapshotID == localSnapshotID.bytes else {
            throw SyncV2StoreError.staleConflictAction
        }
        try stageRemote(remote, scope: scope)
        try verifyInbox(inboxID: remote.inboxID, scope: scope)
        let material = ConflictAppendMaterial(
            workID: workID,
            baseSnapshotID: baseSnapshotID,
            localSnapshotID: localSnapshotID,
            remote: remote,
            sourceGeneration: sourceGeneration,
            binding: binding
        )
        return try inTransaction {
            try conflictRepository.commitConflictDelivery(material, scope: scope)
        }
    }

    func conflictResolutionPrepared(_ conflict: V2ConflictCandidate, scope: V2LocalWorkScope) throws -> Bool {
        do {
            try conflictRepository.requireUnpreparedConflict(workID: conflict.workID, conflictID: conflict.conflictID,
                                                             revision: conflict.revision, generation: conflict.sourceGeneration,
                                                             local: conflict.localSnapshotID, remote: conflict.remoteSnapshotID, scope: scope)
            return false
        } catch SyncV2StoreError.staleConflictAction {
            return true
        }
    }

    func activeConflict(
        workID: WorkID,
        scope: V2LocalWorkScope
    ) throws -> V2ConflictCandidate? {
        try conflictRepository.activeConflict(workID: workID, scope: scope)
    }

    func prepareUseDevice(
        _ request: V2DeviceResolutionRequest,
        scope: V2LocalWorkScope
    ) throws -> V2CheckpointResult {
        guard case let .bound(binding) = scope else {
            throw SyncV2StoreError.accountMismatch
        }
        _ = try conflictRepository.requireConflict(
            workID: request.workID,
            conflictID: request.conflictID,
            revision: request.revision,
            generation: request.sourceGeneration,
            local: request.localSnapshotID,
            remote: request.remoteSnapshotID,
            scope: scope
        )
        let graph = try inboxRepository.loadInboxGraph(inboxID: request.inboxID, binding: binding)
        guard graph.headSnapshotID == request.remoteSnapshotID,
              graph.expectedRemoteHead == request.remoteHead,
              request.remoteHead.snapshotID == request.remoteSnapshotID,
              try inboxRepository.inboxState(inboxID: request.inboxID, binding: binding) == "verified" else {
            throw SyncV2StoreError.staleConflictAction
        }
        try conflictRepository.validateDeviceRequest(request, binding: binding)
        let local = try workRepository.loadEncoded(
            workID: request.workID,
            snapshotID: request.localSnapshotID
        )
        let model = try SnapshotCodec.decode(
            manifestBytes: local.manifestBytes,
            objects: local.objects
        )
        let parents = [request.localSnapshotID, request.remoteSnapshotID]
            .sorted { $0.rawValue < $1.rawValue }
        let decision = try SnapshotCodec.encode(model, parents: parents)
        let next = request.sourceGeneration + 1
        let intentID = UUID()
        return try inTransaction {
            try conflictRepository.validateDeviceRequest(request, binding: binding)
            try conflictRepository.requireUnpreparedConflict(
                workID: request.workID, conflictID: request.conflictID, revision: request.revision,
                generation: request.sourceGeneration, local: request.localSnapshotID,
                remote: request.remoteSnapshotID, scope: scope
            )
            try conflictRepository.preserveConflictBranches(local: request.localSnapshotID,
                                                            generation: request.sourceGeneration, graph: graph)
            try workRepository.insertEncoded(decision, workID: request.workID)
            let current = try workRepository.scopedWorkRow(workID: request.workID, scope: scope)
            guard let currentGeneration = current?.localGeneration,
                  currentGeneration >= request.sourceGeneration else {
                throw SyncV2StoreError.staleCAS
            }
            if currentGeneration == request.sourceGeneration {
                guard current?.currentSnapshotID == request.localSnapshotID.bytes else {
                    throw SyncV2StoreError.staleCAS
                }
                try workRepository.installDeviceResolutionHeadInTransaction(
                    decision: decision,
                    request: request,
                    next: next
                )
            }
            try workRepository.insertHistory(
                workID: request.workID,
                snapshotID: decision.snapshotId,
                reason: V2CheckpointReason.conflictResolution.rawValue,
                pinned: false,
                generation: next
            )
            try outboxRepository.insertIntent(.init(
                intentID: intentID,
                workID: request.workID,
                snapshotID: decision.snapshotId,
                generation: next,
                kind: "conflictResolution",
                scope: scope
            ))
            return V2CheckpointResult(
                snapshotID: decision.snapshotId,
                generation: next,
                intentID: intentID,
                noChanges: false
            )
        }
    }

    /// Records the server-choice decision without changing the active editor
    /// snapshot.  The worker turns this durable intent into one sealed
    /// resolveServer command; adoption remains behind the platform gate.
    func prepareUseServer(
        _ request: V2ServerResolutionRequest,
        scope: V2LocalWorkScope
    ) throws -> V2CheckpointResult {
        try inTransaction {
            try conflictRepository.prepareUseServer(request, scope: scope)
        }
    }

    func prepareKeepBoth(_ request: V2KeepBothPreparationRequest, scope: V2LocalWorkScope) throws -> V2KeepBothReservation {
        try prepareKeepBothWithIntent(request, scope: scope, intentID: nil)
    }

    func keepBothReservation(
        sourceWorkID: WorkID,
        newWorkID: WorkID,
        scope: V2LocalWorkScope
    ) throws -> V2KeepBothReservation? {
        try conflictRepository.keepBothReservation(sourceWorkID: sourceWorkID, newWorkID: newWorkID, scope: scope)
    }

    func latestKeepBothReservation(
        sourceWorkID: WorkID,
        conflictID: UUID,
        scope: V2LocalWorkScope
    ) throws -> V2KeepBothReservation? {
        try conflictRepository.latestKeepBothReservation(
            sourceWorkID: sourceWorkID,
            conflictID: conflictID,
            scope: scope
        )
    }

    func prepareKeepBothResolution(
        _ request: V2KeepBothPreparationRequest,
        scope: V2LocalWorkScope
    ) throws -> (reservation: V2KeepBothReservation, intentID: UUID) {
        let intentID = UUID()
        let reservation = try prepareKeepBothWithIntent(request, scope: scope, intentID: intentID)
        return (reservation, intentID)
    }

    func prepareRestore(
        _ request: V2RestorePreparationRequest,
        scope: V2LocalWorkScope
    ) throws -> V2RestorePreparationResult {
        let localOnly = switch scope {
        case .parked, .unbound: true
        case .bound: false
        }
        if localOnly {
            // Older clients could leave an unbound restore intent behind for
            // a local Work. It is not an online lane; close it before the
            // local-only transaction below, retaining the audit rows.
            try accountRepository.parkPendingUnboundIntents(workID: request.workID)
        } else if let prepared = try conflictRepository.preparedRestore(request, scope: scope) {
            return prepared
        }
        guard let current = try workRepository.scopedWorkRow(workID: request.workID, scope: scope),
              current.localGeneration == request.expectedLocalGeneration,
              let currentBytes = current.currentSnapshotID else {
            throw SyncV2StoreError.staleCAS
        }
        let currentID = try SnapshotID(rawValue: currentBytes.hexString)
        if currentID == request.selectedSnapshotID {
            return try V2RestorePreparationResult(
                restoreID: nil,
                checkpoint: V2CheckpointResult(
                    snapshotID: currentID,
                    generation: request.expectedLocalGeneration,
                    intentID: outboxRepository.latestPendingIntentID(
                        workID: request.workID,
                        scope: scope
                    ),
                    noChanges: true
                ),
                expectedRemoteHead: conflictRepository.acknowledgedHead(workID: request.workID)
            )
        }
        let selected = try workRepository.loadEncoded(
            workID: request.workID,
            snapshotID: request.selectedSnapshotID
        )
        let model = try SnapshotCodec.decode(
            manifestBytes: selected.manifestBytes,
            objects: selected.objects
        )
        try workRepository.validateAnchor(model, workRow: current)
        let parents = [currentID, request.selectedSnapshotID]
            .sorted { $0.rawValue < $1.rawValue }
        let result = try SnapshotCodec.encode(model, parents: parents)
        let prepared = try RestorePreparedMaterial(
            currentBytes: currentBytes,
            currentID: currentID,
            result: result,
            intentID: UUID(),
            restoreID: UUID(),
            nextGeneration: request.expectedLocalGeneration + 1,
            expectedRemoteHead: conflictRepository.acknowledgedHead(workID: request.workID)
        )
        if localOnly {
            return try persistLocalRestore(
                request: request,
                scope: scope,
                prepared: prepared
            )
        }
        return try persistRestore(request: request, scope: scope, prepared: prepared)
    }
}

extension LocalSyncV2Store {
    /// A local Work may restore historical bytes without creating an unbound
    /// remote intent or restore record. The resulting head and history are
    /// still one durable SQLite transaction. A later same-namespace
    /// reauthentication or explicit account clone is the only path that may
    /// create a new remote checkpoint lane.
    func persistLocalRestore(
        request: V2RestorePreparationRequest,
        scope: V2LocalWorkScope,
        prepared: RestorePreparedMaterial
    ) throws -> V2RestorePreparationResult {
        try inTransaction {
            guard let latest = try workRepository.scopedWorkRow(
                workID: request.workID,
                scope: scope
            ),
                latest.localGeneration == request.expectedLocalGeneration,
                latest.currentSnapshotID == prepared.currentBytes else {
                throw SyncV2StoreError.staleCAS
            }
            guard try conflictRepository.acknowledgedHead(workID: request.workID) ==
                prepared.expectedRemoteHead else {
                throw SyncV2StoreError.staleCAS
            }
            try workRepository.insertEncoded(prepared.result, workID: request.workID)
            try workRepository.insertHistory(
                workID: request.workID,
                snapshotID: prepared.currentID,
                reason: "preRestore",
                pinned: true,
                generation: request.expectedLocalGeneration
            )
            try conflictRepository.installRestoreHead(request: request, prepared: prepared)
            try workRepository.insertHistory(
                workID: request.workID,
                snapshotID: prepared.result.snapshotId,
                reason: V2CheckpointReason.restore.rawValue,
                pinned: false,
                generation: prepared.nextGeneration
            )
            return V2RestorePreparationResult(
                restoreID: nil,
                checkpoint: V2CheckpointResult(
                    snapshotID: prepared.result.snapshotId,
                    generation: prepared.nextGeneration,
                    intentID: nil,
                    noChanges: false
                ),
                expectedRemoteHead: prepared.expectedRemoteHead
            )
        }
    }
}

public extension LocalSyncV2Store {
    func appendConflictFromVerifiedInbox(
        _ candidate: V2ConflictCandidate,
        inboxID: UUID,
        scope: V2LocalWorkScope
    ) throws -> V2ConflictCandidate {
        let workID = candidate.workID
        let conflictID = candidate.conflictID
        let revision = candidate.revision
        let baseSnapshotID = candidate.baseSnapshotID
        let localSnapshotID = candidate.localSnapshotID
        let remoteSnapshotID = candidate.remoteSnapshotID
        let sourceGeneration = candidate.sourceGeneration
        guard case let .bound(binding) = scope else { throw SyncV2StoreError.accountMismatch }
        let graph = try inboxRepository.loadInboxGraph(inboxID: inboxID, binding: binding)
        guard graph.headSnapshotID == remoteSnapshotID,
              let expectedHead = graph.expectedRemoteHead,
              expectedHead.snapshotID == remoteSnapshotID,
              let encoded = graph.snapshots.first(where: { $0.snapshotId == remoteSnapshotID }) else {
            throw SyncV2StoreError.invalidRemoteHead
        }
        guard graph.workID == workID,
              graph.expectedCurrentSnapshotID == localSnapshotID,
              graph.expectedLocalGeneration == sourceGeneration,
              try inboxRepository.inboxState(inboxID: inboxID, binding: binding) == "verified",
              revision > 0 else { throw SyncV2StoreError.invalidSnapshot }
        let material = ConflictAppendMaterial(
            workID: workID,
            baseSnapshotID: baseSnapshotID,
            localSnapshotID: localSnapshotID,
            remote: V2RemoteSnapshot(
                inboxID: inboxID, workID: workID, encoded: encoded,
                expectedCurrentSnapshotID: localSnapshotID,
                expectedLocalGeneration: sourceGeneration,
                expectedRemoteHead: expectedHead
            ),
            sourceGeneration: sourceGeneration, binding: binding
        )
        return try inTransaction {
            try conflictRepository.commitConflictDelivery(material, scope: scope,
                                                          remoteIdentity: (conflictID, revision))
        }
    }
}

extension LocalSyncV2Store {
    func prepareKeepBothWithIntent(
        _ request: V2KeepBothPreparationRequest,
        scope: V2LocalWorkScope,
        intentID: UUID?
    ) throws -> V2KeepBothReservation {
        guard case let .bound(binding) = scope,
              request.newWorkID != request.workID else {
            throw SyncV2StoreError.accountMismatch
        }
        let active = try conflictRepository.requireConflict(
            workID: request.workID,
            conflictID: request.conflictID,
            revision: request.revision,
            generation: request.sourceGeneration,
            local: request.localSnapshotID,
            remote: request.remoteSnapshotID,
            scope: scope
        )
        guard try !workRepository.workExists(workID: request.newWorkID),
              let work = try workRepository.scopedWorkRow(workID: request.workID, scope: scope),
              (work.localGeneration.map { $0 >= request.sourceGeneration } == true) else {
            throw SyncV2StoreError.staleConflictAction
        }
        let inbox = try conflictRepository.conflictInbox(active)
        let graph = try inboxRepository.loadInboxGraph(inboxID: inbox, binding: binding)
        guard graph.headSnapshotID == request.remoteSnapshotID,
              let originalHead = graph.expectedRemoteHead,
              originalHead.snapshotID == request.remoteSnapshotID,
              try inboxRepository.inboxState(inboxID: inbox, binding: binding) == "verified" else {
            throw SyncV2StoreError.staleConflictAction
        }
        let candidate = try workRepository.loadEncoded(
            workID: request.workID,
            snapshotID: request.localSnapshotID
        )
        let candidateModel = try SnapshotCodec.decode(
            manifestBytes: candidate.manifestBytes,
            objects: candidate.objects
        )
        var cloneDocument = candidateModel.document
        cloneDocument.id = request.newDocumentID.rawValue
        let clone = try SnapshotCodec.encode(
            SnapshotModel(
                workId: request.newWorkID,
                document: cloneDocument,
                documentCreatedAt: candidateModel.documentCreatedAt,
                attachments: candidateModel.attachments
            ),
            parents: []
        )
        return try persistKeepBothReservation(
            request: request,
            scope: scope,
            resolutionIntentID: intentID,
            prepared: KeepBothPreparedMaterial(
                candidateModel: candidateModel,
                clone: clone,
                originalHead: originalHead,
                reservationID: UUID()
            )
        )
    }

    func persistKeepBothReservation(
        request: V2KeepBothPreparationRequest,
        scope: V2LocalWorkScope,
        resolutionIntentID: UUID?,
        prepared: KeepBothPreparedMaterial
    ) throws -> V2KeepBothReservation {
        try inTransaction {
            _ = try conflictRepository.requireConflict(
                workID: request.workID,
                conflictID: request.conflictID,
                revision: request.revision,
                generation: request.sourceGeneration,
                local: request.localSnapshotID,
                remote: request.remoteSnapshotID,
                scope: scope
            )
            try conflictRepository.requireUnpreparedConflict(
                workID: request.workID, conflictID: request.conflictID, revision: request.revision,
                generation: request.sourceGeneration, local: request.localSnapshotID,
                remote: request.remoteSnapshotID, scope: scope
            )
            try workRepository.insertWork(
                workID: request.newWorkID,
                documentID: request.newDocumentID,
                documentCreatedAt: StoreValueCoding.iso8601(
                    prepared.candidateModel.documentCreatedAt
                ),
                lane: .keepBothReserved,
                scope: scope
            )
            try workRepository.insertEncoded(prepared.clone, workID: request.newWorkID)
            let resources = try workRepository.loadPortableResources(workID: request.workID)
            try workRepository.replacePortableResources(
                workID: request.newWorkID,
                resources: resources
            )
            try workRepository.installKeepBothHeadInTransaction(prepared: prepared, request: request)
            try workRepository.insertHistory(
                workID: request.newWorkID,
                snapshotID: prepared.clone.snapshotId,
                reason: V2CheckpointReason.keepBoth.rawValue,
                pinned: false,
                generation: 1
            )
            try conflictRepository.insertKeepBothReservation(request: request, prepared: prepared)
            if let resolutionIntentID {
                // The reservation and its selected candidate intent commit
                // together. Later editing keeps its own checkpoint intent.
                try outboxRepository.insertIntent(.init(
                    intentID: resolutionIntentID, workID: request.workID,
                    snapshotID: request.localSnapshotID, generation: request.sourceGeneration,
                    kind: "conflictResolution", scope: scope
                ))
            }
            return V2KeepBothReservation(
                reservationID: prepared.reservationID,
                sourceWorkID: request.workID,
                newWorkID: request.newWorkID,
                newDocumentID: request.newDocumentID,
                newRootSnapshotID: prepared.clone.snapshotId,
                sourceGeneration: request.sourceGeneration,
                expectedOriginalHead: prepared.originalHead,
                state: "prepared"
            )
        }
    }

    func persistRestore(
        request: V2RestorePreparationRequest,
        scope: V2LocalWorkScope,
        prepared: RestorePreparedMaterial
    ) throws -> V2RestorePreparationResult {
        try inTransaction {
            guard let latest = try workRepository.scopedWorkRow(workID: request.workID, scope: scope),
                  latest.localGeneration == request.expectedLocalGeneration,
                  latest.currentSnapshotID == prepared.currentBytes else {
                throw SyncV2StoreError.staleCAS
            }
            guard try conflictRepository.acknowledgedHead(workID: request.workID) ==
                prepared.expectedRemoteHead else {
                throw SyncV2StoreError.staleCAS
            }
            try workRepository.insertEncoded(prepared.result, workID: request.workID)
            try workRepository.insertHistory(
                workID: request.workID,
                snapshotID: prepared.currentID,
                reason: "preRestore",
                pinned: true,
                generation: request.expectedLocalGeneration
            )
            try conflictRepository.installRestoreHead(request: request, prepared: prepared)
            try workRepository.insertHistory(
                workID: request.workID,
                snapshotID: prepared.result.snapshotId,
                reason: V2CheckpointReason.restore.rawValue,
                pinned: false,
                generation: prepared.nextGeneration
            )
            try outboxRepository.insertIntent(.init(
                intentID: prepared.intentID,
                workID: request.workID,
                snapshotID: prepared.result.snapshotId,
                generation: prepared.nextGeneration,
                kind: "restore",
                scope: scope
            ))
            try conflictRepository.insertRestoreRecord(request: request, scope: scope, prepared: prepared)
            try conflictRepository.finishMultipleResolutionByRestore(workID: request.workID, scope: scope)
            return V2RestorePreparationResult(
                restoreID: prepared.restoreID,
                checkpoint: V2CheckpointResult(
                    snapshotID: prepared.result.snapshotId,
                    generation: prepared.nextGeneration,
                    intentID: prepared.intentID,
                    noChanges: false
                ),
                expectedRemoteHead: prepared.expectedRemoteHead
            )
        }
    }
}

public struct V2RestoreCommandSource: Sendable {
    public let previousSnapshotID: SnapshotID
    public let selectedSnapshotID: SnapshotID
    public let restoredSnapshotID: SnapshotID
    public let previousGeneration: Int64
    public let expectedRemoteHead: V2RemoteHead?
}

public extension LocalSyncV2Store {
    /// Replay source comes from the prepared restore, never the newer editor head.
    func restoreCommandSource(workID: WorkID, intentID: UUID,
                              scope: V2LocalWorkScope) throws -> V2RestoreCommandSource {
        try conflictRepository.restoreCommandSource(workID: workID, intentID: intentID, scope: scope)
    }
}

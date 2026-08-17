import Foundation
import NovelCore
import NovelSyncV2

struct ConflictAppendMaterial {
    let workID: WorkID
    let baseSnapshotID: SnapshotID?
    let localSnapshotID: SnapshotID
    let remote: V2RemoteSnapshot
    let sourceGeneration: Int64
    let binding: V2AccountBinding
}

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
              let work = try scopedWorkRow(workID: workID, scope: scope),
              work[2].int64 == sourceGeneration,
              work[3].blob == localSnapshotID.bytes else {
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
            try commitConflictDelivery(material, scope: scope)
        }
    }

    func activeConflict(
        workID: WorkID,
        scope: V2LocalWorkScope
    ) throws -> V2ConflictCandidate? {
        guard case let .bound(binding) = scope,
              try scopedWorkRow(workID: workID, scope: scope) != nil else {
            throw SyncV2StoreError.workNotFound
        }
        guard let row = try activeConflictRow(workID: workID, binding: binding),
              let conflict = row[0].text.flatMap(UUID.init(uuidString:)),
              let revision = row[1].int64,
              let local = row[3].blob,
              let remote = row[4].blob,
              let generation = row[5].int64 else { return nil }
        return try V2ConflictCandidate(
            conflictID: conflict,
            revision: revision,
            workID: workID,
            baseSnapshotID: row[2].blob.map {
                try SnapshotID(rawValue: $0.hexString)
            },
            localSnapshotID: SnapshotID(rawValue: local.hexString),
            remoteSnapshotID: SnapshotID(rawValue: remote.hexString),
            sourceGeneration: generation
        )
    }

    func prepareUseDevice(
        _ request: V2DeviceResolutionRequest,
        scope: V2LocalWorkScope
    ) throws -> V2CheckpointResult {
        guard case let .bound(binding) = scope else {
            throw SyncV2StoreError.accountMismatch
        }
        _ = try requireConflict(
            workID: request.workID,
            conflictID: request.conflictID,
            revision: request.revision,
            generation: request.sourceGeneration,
            local: request.localSnapshotID,
            remote: request.remoteSnapshotID,
            scope: scope
        )
        let graph = try loadInboxGraph(inboxID: request.inboxID, binding: binding)
        guard graph.headSnapshotID == request.remoteSnapshotID,
              graph.expectedRemoteHead == request.remoteHead,
              request.remoteHead.snapshotID == request.remoteSnapshotID,
              try inboxState(inboxID: request.inboxID, binding: binding) == "verified" else { throw SyncV2StoreError.staleConflictAction }
        if let prepared = try preparedDeviceResolution(request, scope: scope) {
            return prepared
        }
        try validateDeviceRequest(request, binding: binding)
        let local = try loadEncoded(
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
            try validateDeviceRequest(request, binding: binding)
            for snapshot in try topologicalSnapshots(graph) {
                try insertEncoded(snapshot, workID: request.workID)
            }
            try insertEncoded(decision, workID: request.workID)
            let current = try scopedWorkRow(workID: request.workID, scope: scope)
            guard let currentGeneration = current?[2].int64,
                  currentGeneration >= request.sourceGeneration else {
                throw SyncV2StoreError.staleCAS
            }
            if currentGeneration == request.sourceGeneration {
                guard current?[3].blob == request.localSnapshotID.bytes else {
                    throw SyncV2StoreError.staleCAS
                }
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
            try insertHistory(
                workID: request.workID,
                snapshotID: decision.snapshotId,
                reason: V2CheckpointReason.conflictResolution.rawValue,
                pinned: false,
                generation: next
            )
            try insertIntent(
                intentID: intentID,
                workID: request.workID,
                snapshotID: decision.snapshotId,
                generation: next,
                kind: "conflictResolution",
                scope: scope
            )
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
        guard case let .bound(binding) = scope else { throw SyncV2StoreError.accountMismatch }
        try validateExactConflict(request, binding: binding)
        guard try inboxState(inboxID: request.inboxID, binding: binding) == "verified",
              let current = try scopedWorkRow(workID: request.workID, scope: scope),
              (current[2].int64.map { $0 >= request.sourceGeneration } == true) else {
            throw SyncV2StoreError.staleConflictAction
        }
        let existing = try pendingIntents(scope: scope, workID: request.workID)
            .first { $0.kind == "conflictResolution" && $0.sourceSnapshotID == request.localSnapshotID && $0.sourceGeneration == request.sourceGeneration }
        if let existing {
            return V2CheckpointResult(snapshotID: existing.sourceSnapshotID, generation: existing.sourceGeneration, intentID: existing.intentID, noChanges: false)
        }
        let intentID = UUID()
        try insertIntent(
            intentID: intentID,
            workID: request.workID,
            snapshotID: request.localSnapshotID,
            generation: request.sourceGeneration,
            kind: "conflictResolution",
            scope: scope
        )
        return V2CheckpointResult(snapshotID: request.localSnapshotID, generation: request.sourceGeneration, intentID: intentID, noChanges: false)
    }

    func prepareKeepBoth(
        _ request: V2KeepBothPreparationRequest,
        scope: V2LocalWorkScope
    ) throws -> V2KeepBothReservation {
        guard case let .bound(binding) = scope,
              request.newWorkID != request.workID else {
            throw SyncV2StoreError.accountMismatch
        }
        let active = try requireConflict(
            workID: request.workID,
            conflictID: request.conflictID,
            revision: request.revision,
            generation: request.sourceGeneration,
            local: request.localSnapshotID,
            remote: request.remoteSnapshotID,
            scope: scope
        )
        if let existing = try loadKeepBothReservation(
            sourceWorkID: request.workID,
            conflictID: request.conflictID
        ) {
            guard existing.sourceGeneration == request.sourceGeneration else {
                throw SyncV2StoreError.staleConflictAction
            }
            return existing
        }
        if let existing = try loadKeepBothReservation(
            sourceWorkID: request.workID,
            newWorkID: request.newWorkID
        ) {
            guard existing.sourceGeneration == request.sourceGeneration,
                  existing.newDocumentID == request.newDocumentID else {
                throw SyncV2StoreError.staleConflictAction
            }
            return existing
        }
        guard try !workExists(workID: request.newWorkID),
              let work = try scopedWorkRow(workID: request.workID, scope: scope),
              (work[2].int64.map { $0 >= request.sourceGeneration } == true) else {
            throw SyncV2StoreError.staleConflictAction
        }
        let inbox = try conflictInbox(active)
        let graph = try loadInboxGraph(inboxID: inbox, binding: binding)
        guard graph.headSnapshotID == request.remoteSnapshotID,
              let originalHead = graph.expectedRemoteHead,
              originalHead.snapshotID == request.remoteSnapshotID,
              try inboxState(inboxID: inbox, binding: binding) == "verified" else {
            throw SyncV2StoreError.staleConflictAction
        }
        let candidate = try loadEncoded(
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
            prepared: KeepBothPreparedMaterial(
                candidateModel: candidateModel,
                clone: clone,
                originalHead: originalHead,
                reservationID: UUID()
            )
        )
    }

    func keepBothReservation(
        sourceWorkID: WorkID,
        newWorkID: WorkID,
        scope: V2LocalWorkScope
    ) throws -> V2KeepBothReservation? {
        guard try scopedWorkRow(workID: sourceWorkID, scope: scope) != nil else {
            throw SyncV2StoreError.workNotFound
        }
        return try loadKeepBothReservation(
            sourceWorkID: sourceWorkID,
            newWorkID: newWorkID
        )
    }

    func latestKeepBothReservation(
        sourceWorkID: WorkID,
        conflictID: UUID,
        scope: V2LocalWorkScope
    ) throws -> V2KeepBothReservation? {
        guard case .bound = scope else { throw SyncV2StoreError.accountMismatch }
        return try loadKeepBothReservation(sourceWorkID: sourceWorkID, conflictID: conflictID)
    }

    func prepareKeepBothResolution(
        _ request: V2KeepBothPreparationRequest,
        scope: V2LocalWorkScope
    ) throws -> (reservation: V2KeepBothReservation, intentID: UUID) {
        let reservation = try prepareKeepBoth(request, scope: scope)
        guard case .bound = scope,
              let current = try scopedWorkRow(workID: request.workID, scope: scope),
              let snapshot = current[3].blob,
              let generation = current[2].int64 else { throw SyncV2StoreError.staleCAS }
        let snapshotID = try SnapshotID(rawValue: snapshot.hexString)
        if let existing = try pendingIntents(scope: scope, workID: request.workID)
            .first(where: { $0.kind == "conflictResolution" && $0.sourceSnapshotID == snapshotID && $0.sourceGeneration == generation }) {
            return (reservation, existing.intentID)
        }
        let intentID = UUID()
        try insertIntent(intentID: intentID, workID: request.workID, snapshotID: snapshotID, generation: generation, kind: "conflictResolution", scope: scope)
        return (reservation, intentID)
    }

    internal func loadKeepBothReservation(
        sourceWorkID: WorkID,
        newWorkID: WorkID
    ) throws -> V2KeepBothReservation? {
        guard let row = try query(
            """
            SELECT reservation_id,new_document_id,new_root_snapshot_id,
                   source_generation,expected_original_head_snapshot_id,
                   expected_original_head_generation,state
            FROM pending_keep_both
            WHERE source_work_id=? AND new_work_id=?
            """,
            [.text(sourceWorkID.description), .text(newWorkID.description)]
        ).first,
            let reservation = row[0].text.flatMap(UUID.init(uuidString:)),
            let document = row[1].text,
            let root = row[2].blob,
            let generation = row[3].int64,
            let expected = try Self.head(snapshot: row[4].blob, generation: row[5].int64),
            let state = row[6].text else { return nil }
        return try V2KeepBothReservation(
            reservationID: reservation,
            sourceWorkID: sourceWorkID,
            newWorkID: newWorkID,
            newDocumentID: DocumentID(uuidString: document),
            newRootSnapshotID: SnapshotID(rawValue: root.hexString),
            sourceGeneration: generation,
            expectedOriginalHead: expected,
            state: state
        )
    }

    internal func loadKeepBothReservation(
        sourceWorkID: WorkID,
        conflictID: UUID
    ) throws -> V2KeepBothReservation? {
        guard let newWork = try query(
            """
            SELECT new_work_id FROM pending_keep_both
            WHERE source_work_id=? AND conflict_id=?
            """,
            [
                .text(sourceWorkID.description),
                .text(conflictID.uuidString.lowercased())
            ]
        ).first?[0].text else { return nil }
        return try loadKeepBothReservation(
            sourceWorkID: sourceWorkID,
            newWorkID: WorkID(uuidString: newWork)
        )
    }

    func prepareRestore(
        _ request: V2RestorePreparationRequest,
        scope: V2LocalWorkScope
    ) throws -> V2RestorePreparationResult {
        if let prepared = try preparedRestore(request, scope: scope) {
            return prepared
        }
        guard let current = try scopedWorkRow(workID: request.workID, scope: scope),
              current[2].int64 == request.expectedLocalGeneration,
              let currentBytes = current[3].blob else {
            throw SyncV2StoreError.staleCAS
        }
        let currentID = try SnapshotID(rawValue: currentBytes.hexString)
        if currentID == request.selectedSnapshotID {
            return try V2RestorePreparationResult(
                restoreID: nil,
                checkpoint: V2CheckpointResult(
                    snapshotID: currentID,
                    generation: request.expectedLocalGeneration,
                    intentID: latestPendingIntentID(
                        workID: request.workID,
                        scope: scope
                    ),
                    noChanges: true
                ),
                expectedRemoteHead: acknowledgedHead(workID: request.workID)
            )
        }
        let selected = try loadEncoded(
            workID: request.workID,
            snapshotID: request.selectedSnapshotID
        )
        let model = try SnapshotCodec.decode(
            manifestBytes: selected.manifestBytes,
            objects: selected.objects
        )
        try validateAnchor(model, workRow: current)
        let parents = [currentID, request.selectedSnapshotID]
            .sorted { $0.rawValue < $1.rawValue }
        let result = try SnapshotCodec.encode(model, parents: parents)
        return try persistRestore(
            request: request,
            scope: scope,
            prepared: RestorePreparedMaterial(
                currentBytes: currentBytes,
                currentID: currentID,
                result: result,
                intentID: UUID(),
                restoreID: UUID(),
                nextGeneration: request.expectedLocalGeneration + 1,
                expectedRemoteHead: acknowledgedHead(workID: request.workID)
            )
        )
    }
}

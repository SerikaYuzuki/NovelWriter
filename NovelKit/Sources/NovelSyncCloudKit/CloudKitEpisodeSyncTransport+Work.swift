import CloudKit
import NovelSync

public extension CloudKitEpisodeSyncTransport {
    func fetchSnapshot(for workID: SyncWorkID) async throws -> WorkRemoteSnapshot {
        try await ensureZone()
        try await requireWorkExists(workID)
        return try await materializeWorkSnapshot(fetchWorkControl(for: workID))
    }

    func fetchRevision(
        _ id: SyncRevisionID,
        for workID: SyncWorkID
    ) async throws -> WorkRevision {
        try await ensureZone()
        try await requireWorkExists(workID)
        guard let record = try await fetchRecordIfPresent(.workRevision(id, workID: workID)) else {
            throw WorkSyncTransportError.missingRevision
        }
        return try codec.decodeWorkRevisionRecord(
            record,
            expectedWorkID: workID,
            expectedRevisionID: id
        )
    }

    func publish(_ request: WorkPublishRequest) async throws -> WorkPublishResult {
        try await ensureZone()
        try await requireWorkExists(request.workID)
        let commandDigest = workPlanner.commandDigest(for: request)
        if let receipt = try await fetchWorkMutationReceipt(
            request.mutationID,
            workID: request.workID
        ) {
            guard receipt.commandDigest == commandDigest else {
                throw WorkSyncTransportError.mutationReuse
            }
            return try await workAcknowledgement(from: receipt)
        }

        let control = try await fetchWorkControl(for: request.workID)
        guard control.headRevisionID == request.expectedHeadRevisionID,
              control.headSnapshotDigest == request.expectedHeadSnapshotDigest else {
            return try await .diverged(materializeWorkSnapshot(control))
        }

        let batchIDs = Set(request.revisions.map(\.revisionID))
        let parentIDs = Set(request.revisions.flatMap(\.parentRevisionIDs))
        let externalParentIDs = parentIDs.subtracting(batchIDs)
        let inspection = try await inspectWorkRevisionRecords(
            workID: request.workID,
            externalParentIDs: externalParentIDs,
            candidateRevisionIDs: batchIDs
        )
        if !inspection.collidingRevisionIDs.isEmpty {
            return try await reconcileWorkPublishAfterConflict(
                request,
                commandDigest: commandDigest
            )
        }
        let plan = try makeWorkPublishPlan(
            request: request,
            control: control,
            inspection: inspection
        )
        defer { codec.removeStagedAssets(plan.stagedAssets) }

        do {
            _ = try await modifyAtomically(plan.recordsToSave)
            guard let committedHead = request.revisions.last else {
                throw WorkSyncTransportError.invalidPublishRequest
            }
            let current = try await fetchSnapshot(for: request.workID)
            return try CloudKitWorkReceiptResolver.resolve(
                expectedCommittedRevisionID: committedHead.revisionID,
                expectedCommittedSnapshotDigest: committedHead.snapshotDigest,
                workID: request.workID,
                committedHead: committedHead,
                current: current
            )
        } catch {
            if CloudKitErrorMapper.containsServerRecordChanged(error) {
                return try await reconcileWorkPublishAfterConflict(
                    request,
                    commandDigest: plan.commandDigest
                )
            }
            throw mappedWorkOperationError(error)
        }
    }
}

extension CloudKitEpisodeSyncTransport {
    func fetchWorkControl(for workID: SyncWorkID) async throws -> CloudKitWorkControl {
        guard let record = try await fetchRecordIfPresent(.workControl(workID)) else {
            return CloudKitWorkControl(
                record: nil,
                workID: workID,
                headRevisionID: nil,
                headSnapshotDigest: nil
            )
        }
        return try codec.decodeWorkControlRecord(record, expectedWorkID: workID)
    }

    func materializeWorkSnapshot(
        _ control: CloudKitWorkControl
    ) async throws -> WorkRemoteSnapshot {
        let head: WorkRevision? = if let headID = control.headRevisionID {
            try await fetchRevision(headID, for: control.workID)
        } else {
            nil
        }
        guard head?.snapshotDigest == control.headSnapshotDigest
            || head == nil && control.headSnapshotDigest == nil else {
            throw CloudKitSyncAdapterError.invalidRemoteRecord
        }
        return WorkRemoteSnapshot(head: head)
    }

    func fetchWorkMutationReceipt(
        _ mutationID: SyncMutationID,
        workID: SyncWorkID
    ) async throws -> CloudKitWorkMutationReceipt? {
        let recordID = CKRecord.ID.workMutationReceipt(mutationID, workID: workID)
        guard let record = try await fetchRecordIfPresent(recordID) else { return nil }
        return try codec.decodeWorkMutationReceipt(
            record,
            expectedWorkID: workID,
            expectedMutationID: mutationID
        )
    }

    func workAcknowledgement(
        from receipt: CloudKitWorkMutationReceipt
    ) async throws -> WorkPublishResult {
        let committedHead = try await fetchRevision(
            receipt.resultHeadRevisionID,
            for: receipt.workID
        )
        let current = try await fetchSnapshot(for: receipt.workID)
        return try CloudKitWorkReceiptResolver.resolve(
            receipt: receipt,
            committedHead: committedHead,
            current: current
        )
    }

    func reconcileWorkPublishAfterConflict(
        _ request: WorkPublishRequest,
        commandDigest: SyncContentDigest
    ) async throws -> WorkPublishResult {
        if let receipt = try await fetchWorkMutationReceipt(
            request.mutationID,
            workID: request.workID
        ) {
            guard receipt.commandDigest == commandDigest else {
                throw WorkSyncTransportError.mutationReuse
            }
            return try await workAcknowledgement(from: receipt)
        }
        let current = try await fetchSnapshot(for: request.workID)
        if current.head?.revisionID != request.expectedHeadRevisionID
            || current.head?.snapshotDigest != request.expectedHeadSnapshotDigest {
            return .diverged(current)
        }
        throw WorkSyncTransportError.revisionCollision
    }

    func inspectWorkRevisionRecords(
        workID: SyncWorkID,
        externalParentIDs: Set<SyncRevisionID>,
        candidateRevisionIDs: Set<SyncRevisionID>
    ) async throws -> (
        existingExternalParentIDs: Set<SyncRevisionID>,
        collidingRevisionIDs: Set<SyncRevisionID>
    ) {
        let allIDs = externalParentIDs.union(candidateRevisionIDs)
        guard !allIDs.isEmpty else { return ([], []) }
        let recordIDByRevision = Dictionary(uniqueKeysWithValues: allIDs.map {
            ($0, CKRecord.ID.workRevision($0, workID: workID))
        })
        let results: [CKRecord.ID: Result<CKRecord, any Error>]
        do {
            results = try await database.records(
                for: Array(recordIDByRevision.values),
                desiredKeys: [
                    CloudKitSyncSchema.Field.protocolVersion,
                    CloudKitSyncSchema.Field.workID,
                    CloudKitSyncSchema.Field.revisionID,
                    CloudKitSyncSchema.Field.parentRevisionIDs,
                    CloudKitSyncSchema.Field.branchID,
                    CloudKitSyncSchema.Field.authorReplicaID,
                    CloudKitSyncSchema.Field.authorSessionID,
                    CloudKitSyncSchema.Field.clientCreatedAt,
                    CloudKitSyncSchema.Field.snapshotDigest,
                    CloudKitSyncSchema.Field.snapshotByteCount,
                    CloudKitSyncSchema.Field.revisionDigest,
                    CloudKitSyncSchema.Field.revisionByteCount,
                    CloudKitSyncSchema.Field.mutationID,
                    CloudKitSyncSchema.Field.attachmentManifestDigest,
                    CloudKitSyncSchema.Field.attachmentCount
                ]
            )
        } catch {
            throw mappedWorkOperationError(error)
        }

        var existingParents = Set<SyncRevisionID>()
        var collisions = Set<SyncRevisionID>()
        for (revisionID, recordID) in recordIDByRevision {
            guard let result = results[recordID] else {
                throw CloudKitSyncAdapterError.operationFailed
            }
            switch result {
            case let .success(record):
                try codec.validateWorkRevisionMetadataRecord(
                    record,
                    expectedWorkID: workID,
                    expectedRevisionID: revisionID
                )
                if externalParentIDs.contains(revisionID) {
                    existingParents.insert(revisionID)
                }
                if candidateRevisionIDs.contains(revisionID) {
                    collisions.insert(revisionID)
                }
            case let .failure(error):
                if CloudKitErrorMapper.isUnknownItem(error) {
                    continue
                }
                throw mappedWorkOperationError(error)
            }
        }
        guard existingParents == externalParentIDs else {
            throw WorkSyncTransportError.missingRevision
        }
        return (existingParents, collisions)
    }

    func makeWorkPublishPlan(
        request: WorkPublishRequest,
        control: CloudKitWorkControl,
        inspection: (
            existingExternalParentIDs: Set<SyncRevisionID>,
            collidingRevisionIDs: Set<SyncRevisionID>
        )
    ) throws -> CloudKitWorkPublishPlan {
        do {
            return try workPlanner.makePlan(
                request: request,
                control: control,
                existingExternalParentIDs: inspection.existingExternalParentIDs,
                collidingRevisionIDs: inspection.collidingRevisionIDs
            )
        } catch let error as CloudKitWorkPublishPlanError {
            switch error {
            case .invalidRequest:
                throw WorkSyncTransportError.invalidPublishRequest
            case .revisionCollision:
                throw WorkSyncTransportError.revisionCollision
            case .missingParent:
                throw WorkSyncTransportError.missingRevision
            }
        }
    }

    func mappedWorkOperationError(_ error: any Error) -> any Error {
        if error is WorkSyncTransportError {
            return error
        }
        let mapped = mappedOperationError(error)
        if let episodeError = mapped as? EpisodeSyncTransportError,
           episodeError == .unavailable {
            return WorkSyncTransportError.unavailable
        }
        return mapped
    }
}

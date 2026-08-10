import NovelSync

extension CloudKitEpisodeSyncTransport {
    public func publish(_ request: EpisodePublishRequest) async throws -> EpisodePublishResult {
        try await ensureZone()
        try await requireWorkExists(request.key.workID)
        let commandDigest = planner.commandDigest(for: request)
        if let receipt = try await fetchMutationReceipt(
            request.mutationID,
            key: request.key
        ) {
            guard receipt.commandDigest == commandDigest else {
                throw EpisodeSyncTransportError.mutationReuse
            }
            return try await acknowledgement(from: receipt)
        }

        let control = try await fetchControl(for: request.key)
        if control.lease?.authority != request.expectedLeaseAuthority {
            return try await .staleLease(materializeSnapshot(control))
        }
        if control.headRevisionID != request.expectedHeadRevisionID {
            return try await .diverged(materializeSnapshot(control))
        }

        let batchIDs = Set(request.revisions.map(\.revisionID))
        let parentIDs = Set(request.revisions.flatMap(\.parentRevisionIDs))
        let externalParentIDs = parentIDs.subtracting(batchIDs)
        let inspection = try await inspectRevisionRecords(
            key: request.key,
            externalParentIDs: externalParentIDs,
            candidateRevisionIDs: batchIDs
        )
        // receipt確認直後に同じmutationの別試行がcommitしたraceも、collisionで
        // 終わらせずreceiptを再確認してexactly-once相当に収束させる。
        if !inspection.collidingRevisionIDs.isEmpty {
            return try await reconcilePublishAfterConflict(
                request,
                commandDigest: commandDigest
            )
        }
        let plan = try makePublishPlan(request: request, control: control, inspection: inspection)
        defer { codec.removeStagedAssets(plan.stagedAssets) }

        do {
            _ = try await modifyAtomically(plan.recordsToSave)
            guard let head = request.revisions.last else {
                throw EpisodeSyncTransportError.invalidPublishRequest
            }
            // atomic commit直後にforceが成立し得る。saved controlをcurrentとして合成せず、
            // 最新control/headをread-backする。read-back失敗はreceipt retryへ委ねる。
            let current = try await fetchSnapshot(for: request.key)
            return try CloudKitReceiptResolver.resolve(
                expectedCommittedRevisionID: request.candidateHeadRevisionID,
                key: request.key,
                committedHead: head,
                current: current
            )
        } catch {
            if CloudKitErrorMapper.containsServerRecordChanged(error) {
                return try await reconcilePublishAfterConflict(
                    request,
                    commandDigest: plan.commandDigest
                )
            }
            throw mappedOperationError(error)
        }
    }

    private func makePublishPlan(
        request: EpisodePublishRequest,
        control: CloudKitEpisodeControl,
        inspection: (existingExternalParentIDs: Set<SyncRevisionID>, collidingRevisionIDs: Set<SyncRevisionID>)
    ) throws -> CloudKitPublishPlan {
        do {
            return try planner.makePlan(
                request: request,
                control: control,
                existingExternalParentIDs: inspection.existingExternalParentIDs,
                collidingRevisionIDs: inspection.collidingRevisionIDs
            )
        } catch let error as CloudKitPublishPlanError {
            switch error {
            case .revisionCollision:
                throw EpisodeSyncTransportError.revisionCollision
            case .missingParent:
                throw EpisodeSyncTransportError.missingRevision
            case .invalidRequest:
                throw EpisodeSyncTransportError.invalidPublishRequest
            }
        }
    }
}

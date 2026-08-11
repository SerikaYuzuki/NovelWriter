import CloudKit
import NovelSync

enum CloudKitWorkPublishPlanError: Error, Equatable, Sendable {
    case invalidRequest
    case revisionCollision
    case missingParent
}

struct CloudKitWorkPublishPlan: Sendable {
    let recordsToSave: [CKRecord]
    let stagedAssets: [CloudKitStagedAsset]
    let commandDigest: SyncContentDigest

    let savePolicy = CKModifyRecordsOperation.RecordSavePolicy.ifServerRecordUnchanged
    let atomically = true
}

struct CloudKitWorkPublishPlanner: Sendable {
    private let codec: CloudKitRecordCodec

    init(codec: CloudKitRecordCodec) {
        self.codec = codec
    }

    func commandDigest(for request: WorkPublishRequest) -> SyncContentDigest {
        var canonical = "FUMINIWA-WORK-PUBLISH-V1\n"
        append(request.mutationID.rawValue.uuidString, to: &canonical)
        append(request.workID.rawValue.uuidString, to: &canonical)
        appendOptional(request.expectedHeadRevisionID?.rawValue.uuidString, to: &canonical)
        appendOptional(request.expectedHeadSnapshotDigest?.rawValue, to: &canonical)
        append(request.candidateHeadRevisionID.rawValue.uuidString, to: &canonical)
        append(String(request.revisions.count), to: &canonical)
        for revision in request.revisions {
            append(revision.revisionID.rawValue.uuidString, to: &canonical)
            append(String(revision.parentRevisionIDs.count), to: &canonical)
            for parent in revision.parentRevisionIDs {
                append(parent.rawValue.uuidString, to: &canonical)
            }
            append(revision.branchID.rawValue.uuidString, to: &canonical)
            append(revision.authorReplicaID.rawValue.uuidString, to: &canonical)
            append(revision.authorSessionID.rawValue.uuidString, to: &canonical)
            append(String(revision.snapshotByteCount), to: &canonical)
            append(revision.snapshotDigest.rawValue, to: &canonical)
        }
        return SyncContentDigest(content: canonical)
    }

    func validate(
        _ request: WorkPublishRequest,
        existingExternalParentIDs: Set<SyncRevisionID>,
        collidingRevisionIDs: Set<SyncRevisionID> = []
    ) throws {
        do {
            try request.validate()
        } catch {
            throw CloudKitWorkPublishPlanError.invalidRequest
        }
        let revisionIDs = request.revisions.map(\.revisionID)
        guard collidingRevisionIDs.isDisjoint(with: revisionIDs) else {
            throw CloudKitWorkPublishPlanError.revisionCollision
        }

        var priorRevisionIDs = Set<SyncRevisionID>()
        var parentsByRevision: [SyncRevisionID: [SyncRevisionID]] = [:]
        for revision in request.revisions {
            guard revision.parentRevisionIDs.allSatisfy({
                priorRevisionIDs.contains($0) || existingExternalParentIDs.contains($0)
            }) else {
                throw CloudKitWorkPublishPlanError.missingParent
            }
            priorRevisionIDs.insert(revision.revisionID)
            parentsByRevision[revision.revisionID] = revision.parentRevisionIDs
        }

        if let expectedHead = request.expectedHeadRevisionID {
            guard reaches(
                expectedHead,
                from: request.candidateHeadRevisionID,
                parentsByRevision: parentsByRevision
            ) else {
                throw CloudKitWorkPublishPlanError.invalidRequest
            }
        } else {
            let roots = request.revisions.filter(\.parentRevisionIDs.isEmpty)
            guard roots.count == 1,
                  reaches(
                      roots[0].revisionID,
                      from: request.candidateHeadRevisionID,
                      parentsByRevision: parentsByRevision
                  ) else {
                throw CloudKitWorkPublishPlanError.invalidRequest
            }
        }
    }

    func makePlan(
        request: WorkPublishRequest,
        control: CloudKitWorkControl,
        existingExternalParentIDs: Set<SyncRevisionID>,
        collidingRevisionIDs: Set<SyncRevisionID> = []
    ) throws -> CloudKitWorkPublishPlan {
        try validate(
            request,
            existingExternalParentIDs: existingExternalParentIDs,
            collidingRevisionIDs: collidingRevisionIDs
        )
        guard control.workID == request.workID,
              control.headRevisionID == request.expectedHeadRevisionID,
              control.headSnapshotDigest == request.expectedHeadSnapshotDigest,
              let candidate = request.revisions.last else {
            throw CloudKitWorkPublishPlanError.invalidRequest
        }

        var stagedAssets: [CloudKitStagedAsset] = []
        do {
            let revisionRecords = try request.revisions.map { revision in
                let encoded = try codec.makeWorkRevisionRecord(
                    revision,
                    mutationID: request.mutationID
                )
                stagedAssets.append(encoded.stagedAsset)
                return encoded.record
            }
            let digest = commandDigest(for: request)
            let receipt = CloudKitWorkMutationReceipt(
                workID: request.workID,
                mutationID: request.mutationID,
                commandDigest: digest,
                resultHeadRevisionID: candidate.revisionID,
                resultHeadSnapshotDigest: candidate.snapshotDigest
            )
            let controlRecord = try codec.updateWorkControlRecord(
                control.record,
                workID: request.workID,
                headRevisionID: candidate.revisionID,
                headSnapshotDigest: candidate.snapshotDigest
            )
            return CloudKitWorkPublishPlan(
                recordsToSave: revisionRecords
                    + [codec.makeWorkMutationReceiptRecord(receipt), controlRecord],
                stagedAssets: stagedAssets,
                commandDigest: digest
            )
        } catch {
            codec.removeStagedAssets(stagedAssets)
            throw error
        }
    }

    private func reaches(
        _ target: SyncRevisionID,
        from start: SyncRevisionID,
        parentsByRevision: [SyncRevisionID: [SyncRevisionID]]
    ) -> Bool {
        var pending = [start]
        var visited = Set<SyncRevisionID>()
        while let current = pending.popLast() {
            guard visited.insert(current).inserted else { continue }
            if current == target {
                return true
            }
            pending.append(contentsOf: parentsByRevision[current] ?? [])
        }
        return false
    }

    private func append(_ value: String, to output: inout String) {
        output += "\(value.utf8.count):\(value)\n"
    }

    private func appendOptional(_ value: String?, to output: inout String) {
        guard let value else {
            output += "-\n"
            return
        }
        append(value, to: &output)
    }
}

enum CloudKitWorkReceiptResolver {
    static func resolve(
        receipt: CloudKitWorkMutationReceipt,
        committedHead: WorkRevision,
        current: WorkRemoteSnapshot
    ) throws -> WorkPublishResult {
        try resolve(
            expectedCommittedRevisionID: receipt.resultHeadRevisionID,
            expectedCommittedSnapshotDigest: receipt.resultHeadSnapshotDigest,
            workID: receipt.workID,
            committedHead: committedHead,
            current: current
        )
    }

    static func resolve(
        expectedCommittedRevisionID: SyncRevisionID,
        expectedCommittedSnapshotDigest: SyncContentDigest,
        workID: SyncWorkID,
        committedHead: WorkRevision,
        current: WorkRemoteSnapshot
    ) throws -> WorkPublishResult {
        guard committedHead.workID == workID,
              committedHead.revisionID == expectedCommittedRevisionID,
              committedHead.snapshotDigest == expectedCommittedSnapshotDigest,
              current.head?.workID == workID || current.head == nil else {
            throw CloudKitSyncAdapterError.invalidRemoteRecord
        }
        return .acknowledged(committedHead: committedHead, current: current)
    }
}

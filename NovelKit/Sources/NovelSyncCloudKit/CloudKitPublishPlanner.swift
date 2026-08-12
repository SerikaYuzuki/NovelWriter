import CloudKit
import Foundation
import NovelSync

enum CloudKitPublishPlanError: Error, Equatable, Sendable {
    case invalidRequest
    case revisionCollision
    case missingParent
}

struct CloudKitPublishPlan: Sendable {
    let recordsToSave: [CKRecord]
    let stagedAssets: [CloudKitStagedAsset]
    let commandDigest: SyncContentDigest

    let savePolicy = CKModifyRecordsOperation.RecordSavePolicy.ifServerRecordUnchanged
    let atomically = true
}

struct CloudKitPublishPlanner: Sendable {
    private let codec: CloudKitRecordCodec

    init(codec: CloudKitRecordCodec) {
        self.codec = codec
    }

    func commandDigest(for request: EpisodePublishRequest) -> SyncContentDigest {
        var canonical = "FUMINIWA-EPISODE-PUBLISH-V1\n"
        append(request.mutationID.rawValue.uuidString, to: &canonical)
        append(request.key.workID.rawValue.uuidString, to: &canonical)
        append(request.key.episodeID.rawValue.uuidString, to: &canonical)
        appendOptional(request.expectedHeadRevisionID?.rawValue.uuidString, to: &canonical)
        append(request.candidateHeadRevisionID.rawValue.uuidString, to: &canonical)
        append(request.expectedLeaseAuthority.holderReplicaID.rawValue.uuidString, to: &canonical)
        append(request.expectedLeaseAuthority.holderSessionID.rawValue.uuidString, to: &canonical)
        append(String(request.expectedLeaseAuthority.epoch), to: &canonical)
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
            // clientCreatedAtは表示用であり、journalのDate表現差をmutation authorityへ混ぜない。
            // 本文そのものを巨大なcommand文字列へ複製せず、検証済みSHA-256とbyte数を使う。
            append(String(revision.content.utf8.count), to: &canonical)
            append(revision.contentDigest.rawValue, to: &canonical)
        }
        return SyncContentDigest(content: canonical)
    }

    func validate(
        _ request: EpisodePublishRequest,
        existingExternalParentIDs: Set<SyncRevisionID>,
        collidingRevisionIDs: Set<SyncRevisionID> = []
    ) throws {
        guard !request.revisions.isEmpty,
              request.revisions.count <= EpisodePublishRequest.maximumRevisionCount,
              request.revisions.last?.revisionID == request.candidateHeadRevisionID else {
            throw CloudKitPublishPlanError.invalidRequest
        }
        let revisionIDs = request.revisions.map(\.revisionID)
        guard Set(revisionIDs).count == revisionIDs.count else {
            throw CloudKitPublishPlanError.invalidRequest
        }
        guard collidingRevisionIDs.isDisjoint(with: revisionIDs) else {
            throw CloudKitPublishPlanError.revisionCollision
        }
        guard let candidate = request.revisions.last,
              candidate.authorReplicaID == request.expectedLeaseAuthority.holderReplicaID,
              candidate.authorSessionID == request.expectedLeaseAuthority.holderSessionID else {
            throw CloudKitPublishPlanError.invalidRequest
        }

        var priorRevisionIDs = Set<SyncRevisionID>()
        var parentsByRevision: [SyncRevisionID: [SyncRevisionID]] = [:]
        for revision in request.revisions {
            do {
                try revision.validate()
            } catch {
                throw CloudKitPublishPlanError.invalidRequest
            }
            guard revision.key == request.key,
                  !revision.parentRevisionIDs.contains(revision.revisionID),
                  revision.parentRevisionIDs.allSatisfy({
                      priorRevisionIDs.contains($0) || existingExternalParentIDs.contains($0)
                  }) else {
                throw CloudKitPublishPlanError.missingParent
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
                throw CloudKitPublishPlanError.invalidRequest
            }
        } else {
            let roots = request.revisions.filter(\.parentRevisionIDs.isEmpty)
            guard roots.count == 1,
                  reaches(
                      roots[0].revisionID,
                      from: request.candidateHeadRevisionID,
                      parentsByRevision: parentsByRevision
                  ) else {
                throw CloudKitPublishPlanError.invalidRequest
            }
        }
    }

    func makePlan(
        request: EpisodePublishRequest,
        control: CloudKitEpisodeControl,
        existingExternalParentIDs: Set<SyncRevisionID>,
        collidingRevisionIDs: Set<SyncRevisionID> = []
    ) throws -> CloudKitPublishPlan {
        try validate(
            request,
            existingExternalParentIDs: existingExternalParentIDs,
            collidingRevisionIDs: collidingRevisionIDs
        )
        guard control.key == request.key,
              control.headRevisionID == request.expectedHeadRevisionID,
              control.lease?.authority == request.expectedLeaseAuthority,
              let lease = control.lease else {
            throw CloudKitPublishPlanError.invalidRequest
        }

        var stagedAssets: [CloudKitStagedAsset] = []
        do {
            let revisionRecords = try request.revisions.map { revision in
                let result = try codec.makeRevisionRecord(revision, mutationID: request.mutationID)
                stagedAssets.append(result.stagedAsset)
                return result.record
            }
            let commandDigest = commandDigest(for: request)
            let receipt = CloudKitMutationReceipt(
                key: request.key,
                mutationID: request.mutationID,
                commandDigest: commandDigest,
                resultHeadRevisionID: request.candidateHeadRevisionID,
                resultLease: lease
            )
            let receiptRecord = codec.makeMutationReceiptRecord(receipt)
            let updatedControl = try codec.updateControlRecord(
                control.record,
                key: request.key,
                headRevisionID: request.candidateHeadRevisionID,
                leaseEpoch: control.leaseEpoch,
                lease: lease
            )
            return CloudKitPublishPlan(
                recordsToSave: revisionRecords + [receiptRecord, updatedControl],
                stagedAssets: stagedAssets,
                commandDigest: commandDigest
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

import CloudKit
import Foundation
import NovelSync
@testable import NovelSyncCloudKit
import Testing

@Suite("CloudKit publish planner")
struct CloudKitPublishPlannerTests {
    @Test("publish plan uses one-zone atomic conditional save for revision, receipt, and control")
    func atomicConditionalPlan() throws {
        let root = try makeCloudTestDirectory()
        defer { removeCloudTestDirectory(root) }
        let codec = try CloudKitRecordCodec(assetStore: CloudKitAssetStore(rootURL: root))
        let planner = CloudKitPublishPlanner(codec: codec)
        let lease = try makeCloudTestLease()
        let revision = try makeCloudTestRevision(
            id: #require(UUID(uuidString: "11111111-AAAA-4111-8111-111111111111")),
            parents: [],
            content: "　本文\n「続き」"
        )
        let request = try EpisodePublishRequest(
            mutationID: SyncMutationID(
                rawValue: #require(UUID(uuidString: "22222222-AAAA-4222-8222-222222222222"))
            ),
            key: cloudTestKey,
            revisions: [revision],
            candidateHeadRevisionID: revision.revisionID,
            expectedHeadRevisionID: nil,
            expectedLeaseAuthority: lease.authority
        )
        let control = CloudKitEpisodeControl(
            record: nil,
            key: cloudTestKey,
            headRevisionID: nil,
            leaseEpoch: lease.authority.epoch,
            lease: lease
        )

        let plan = try planner.makePlan(
            request: request,
            control: control,
            existingExternalParentIDs: []
        )
        defer { codec.removeStagedAssets(plan.stagedAssets) }
        #expect(plan.recordsToSave.count == 3)
        #expect(plan.recordsToSave.allSatisfy { $0.recordID.zoneID == CloudKitSyncSchema.zoneID })
        #expect(plan.savePolicy == .ifServerRecordUnchanged)
        #expect(plan.atomically)
        #expect(plan.stagedAssets.count == 1)
    }

    @Test("command digest survives display-time truncation but changes with exact body")
    func commandDigestIsRestartStable() throws {
        let root = try makeCloudTestDirectory()
        defer { removeCloudTestDirectory(root) }
        let codec = try CloudKitRecordCodec(assetStore: CloudKitAssetStore(rootURL: root))
        let planner = CloudKitPublishPlanner(codec: codec)
        let lease = try makeCloudTestLease()
        let revisionID = try #require(UUID(uuidString: "33333333-AAAA-4333-8333-333333333333"))
        let first = try makeCloudTestRevision(
            id: revisionID,
            parents: [],
            content: "本文",
            createdAt: Date(timeIntervalSince1970: 1_787_000_000.987_654)
        )
        let afterJournalRoundTrip = try makeCloudTestRevision(
            id: revisionID,
            parents: [],
            content: "本文",
            createdAt: Date(timeIntervalSince1970: 1_787_000_000)
        )
        let changedBody = try makeCloudTestRevision(
            id: revisionID,
            parents: [],
            content: "本文を変更",
            createdAt: Date(timeIntervalSince1970: 1_787_000_000)
        )
        let mutationID = try SyncMutationID(
            rawValue: #require(UUID(uuidString: "44444444-AAAA-4444-8444-444444444444"))
        )
        let firstRequest = try EpisodePublishRequest(
            mutationID: mutationID,
            key: cloudTestKey,
            revisions: [first],
            candidateHeadRevisionID: first.revisionID,
            expectedHeadRevisionID: nil,
            expectedLeaseAuthority: lease.authority
        )
        let restartedRequest = try EpisodePublishRequest(
            mutationID: mutationID,
            key: cloudTestKey,
            revisions: [afterJournalRoundTrip],
            candidateHeadRevisionID: afterJournalRoundTrip.revisionID,
            expectedHeadRevisionID: nil,
            expectedLeaseAuthority: lease.authority
        )
        let changedRequest = try EpisodePublishRequest(
            mutationID: mutationID,
            key: cloudTestKey,
            revisions: [changedBody],
            candidateHeadRevisionID: changedBody.revisionID,
            expectedHeadRevisionID: nil,
            expectedLeaseAuthority: lease.authority
        )

        #expect(planner.commandDigest(for: firstRequest) == planner.commandDigest(for: restartedRequest))
        #expect(planner.commandDigest(for: firstRequest) != planner.commandDigest(for: changedRequest))
    }

    @Test("two-parent merge may publish a preserved fork after the remote head")
    func twoParentMergePlan() throws {
        let root = try makeCloudTestDirectory()
        defer { removeCloudTestDirectory(root) }
        let codec = try CloudKitRecordCodec(assetStore: CloudKitAssetStore(rootURL: root))
        let planner = CloudKitPublishPlanner(codec: codec)
        let lease = try makeCloudTestLease()
        let baseID = try SyncRevisionID(
            rawValue: #require(UUID(uuidString: "55555555-AAAA-4555-8555-555555555555"))
        )
        let remoteID = try SyncRevisionID(
            rawValue: #require(UUID(uuidString: "66666666-AAAA-4666-8666-666666666666"))
        )
        let fork = try makeCloudTestRevision(
            id: #require(UUID(uuidString: "77777777-AAAA-4777-8777-777777777777")),
            parents: [baseID],
            content: "Mac側の本文"
        )
        let merge = try makeCloudTestRevision(
            id: #require(UUID(uuidString: "88888888-AAAA-4888-8888-888888888888")),
            parents: [remoteID, fork.revisionID],
            content: "統合済み本文"
        )
        let request = try EpisodePublishRequest(
            key: cloudTestKey,
            revisions: [fork, merge],
            candidateHeadRevisionID: merge.revisionID,
            expectedHeadRevisionID: remoteID,
            expectedLeaseAuthority: lease.authority
        )
        let control = CloudKitEpisodeControl(
            record: nil,
            key: cloudTestKey,
            headRevisionID: remoteID,
            leaseEpoch: lease.authority.epoch,
            lease: lease
        )
        let plan = try planner.makePlan(
            request: request,
            control: control,
            existingExternalParentIDs: [baseID, remoteID]
        )
        defer { codec.removeStagedAssets(plan.stagedAssets) }
        #expect(plan.recordsToSave.count == 4)
        #expect(plan.stagedAssets.count == 2)
    }

    @Test("planner rejects missing parents, collisions, wrong candidate, and wrong candidate author")
    func unsafePlansAreRejected() throws {
        let root = try makeCloudTestDirectory()
        defer { removeCloudTestDirectory(root) }
        let planner = try CloudKitPublishPlanner(
            codec: CloudKitRecordCodec(assetStore: CloudKitAssetStore(rootURL: root))
        )
        let lease = try makeCloudTestLease()
        let parentID = try SyncRevisionID(
            rawValue: #require(UUID(uuidString: "99999999-AAAA-4999-8999-999999999999"))
        )
        let revision = try makeCloudTestRevision(
            id: #require(UUID(uuidString: "AAAAAAAA-BBBB-4AAA-8AAA-AAAAAAAAAAAA")),
            parents: [parentID],
            content: "本文"
        )
        let request = try EpisodePublishRequest(
            key: cloudTestKey,
            revisions: [revision],
            candidateHeadRevisionID: revision.revisionID,
            expectedHeadRevisionID: parentID,
            expectedLeaseAuthority: lease.authority
        )
        #expect(throws: CloudKitPublishPlanError.missingParent) {
            try planner.validate(request, existingExternalParentIDs: [])
        }
        #expect(throws: CloudKitPublishPlanError.revisionCollision) {
            try planner.validate(
                request,
                existingExternalParentIDs: [parentID],
                collidingRevisionIDs: [revision.revisionID]
            )
        }

        #expect(throws: EpisodeSyncTransportError.invalidPublishRequest) {
            try EpisodePublishRequest(
                key: cloudTestKey,
                revisions: [revision],
                candidateHeadRevisionID: SyncRevisionID(),
                expectedHeadRevisionID: parentID,
                expectedLeaseAuthority: lease.authority
            )
        }

        let otherReplica = try SyncReplicaID(
            rawValue: #require(UUID(uuidString: "BBBBBBBB-BBBB-4BBB-8BBB-BBBBBBBBBBBB"))
        )
        let wrongAuthor = try makeCloudTestRevision(
            id: #require(UUID(uuidString: "CCCCCCCC-CCCC-4CCC-8CCC-CCCCCCCCCCCC")),
            parents: [parentID],
            content: "本文",
            authorReplicaID: otherReplica
        )
        #expect(throws: EpisodeSyncTransportError.invalidPublishRequest) {
            try EpisodePublishRequest(
                key: cloudTestKey,
                revisions: [wrongAuthor],
                candidateHeadRevisionID: wrongAuthor.revisionID,
                expectedHeadRevisionID: parentID,
                expectedLeaseAuthority: lease.authority
            )
        }
    }

    @Test("receipt retry and direct acknowledgement keep a later forced lease and head as current")
    func acknowledgementDoesNotRestoreOldAuthority() throws {
        let committed = try makeCloudTestRevision(
            id: #require(UUID(uuidString: "DDDDDDDD-DDDD-4DDD-8DDD-DDDDDDDDDDDD")),
            parents: [],
            content: "Macでcommit済み"
        )
        let mutationID = try SyncMutationID(
            rawValue: #require(UUID(uuidString: "EEEEEEEE-EEEE-4EEE-8EEE-EEEEEEEEEEEE"))
        )
        let oldLease = try makeCloudTestLease(epoch: 12)
        let receipt = CloudKitMutationReceipt(
            key: cloudTestKey,
            mutationID: mutationID,
            commandDigest: SyncContentDigest(content: "command"),
            resultHeadRevisionID: committed.revisionID,
            resultLease: oldLease
        )
        let forcedReplica = try SyncReplicaID(
            rawValue: #require(UUID(uuidString: "FFFFFFFF-FFFF-4FFF-8FFF-FFFFFFFFFFFF"))
        )
        let forcedSession = try SyncEditSessionID(
            rawValue: #require(UUID(uuidString: "12121212-1212-4212-8212-121212121212"))
        )
        let forcedAuthority = try EpisodeLeaseAuthority(
            holderReplicaID: forcedReplica,
            holderSessionID: forcedSession,
            epoch: 13
        )
        let forcedLease = EpisodeLease(
            authority: forcedAuthority,
            expiresAt: cloudTestDate.addingTimeInterval(600)
        )
        let laterHead = try makeCloudTestRevision(
            id: #require(UUID(uuidString: "13131313-1313-4313-8313-131313131313")),
            parents: [committed.revisionID],
            content: "iPhoneで続けた本文",
            authorReplicaID: forcedReplica,
            authorSessionID: forcedSession
        )
        let current = try EpisodeRemoteSnapshot(
            head: laterHead,
            leaseEpoch: 13,
            lease: forcedLease
        )

        let result = try CloudKitReceiptResolver.resolve(
            receipt: receipt,
            committedHead: committed,
            current: current
        )
        guard case let .acknowledged(committedResult, currentResult) = result else {
            Issue.record("expected acknowledged result")
            return
        }
        #expect(committedResult.revisionID == committed.revisionID)
        #expect(currentResult.head?.revisionID == laterHead.revisionID)
        #expect(currentResult.lease?.authority == forcedAuthority)
        #expect(currentResult.lease?.authority != oldLease.authority)

        let directResult = try CloudKitReceiptResolver.resolve(
            expectedCommittedRevisionID: committed.revisionID,
            key: cloudTestKey,
            committedHead: committed,
            current: current
        )
        guard case let .acknowledged(_, directCurrent) = directResult else {
            Issue.record("expected direct acknowledged result")
            return
        }
        #expect(directCurrent.head?.revisionID == laterHead.revisionID)
        #expect(directCurrent.lease?.authority == forcedAuthority)
    }
}

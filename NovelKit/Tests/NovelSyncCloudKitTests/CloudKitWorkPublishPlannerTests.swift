import CloudKit
import Foundation
import NovelSync
@testable import NovelSyncCloudKit
import Testing

@Suite("CloudKit whole-work publish planner")
struct CloudKitWorkPublishPlannerTests {
    @Test("one atomic plan advances the single work head with asset and receipt")
    func atomicPlanContainsRevisionReceiptAndControl() throws {
        let root = try makeCloudTestDirectory()
        defer { removeCloudTestDirectory(root) }
        let codec = try CloudKitRecordCodec(assetStore: CloudKitAssetStore(rootURL: root))
        let planner = CloudKitWorkPublishPlanner(codec: codec)
        let revision = try makeWorkRevision()
        let request = try makeRequest(revision: revision)
        let control = CloudKitWorkControl(
            record: nil,
            workID: cloudTestWorkID,
            headRevisionID: nil,
            headSnapshotDigest: nil
        )
        let plan = try planner.makePlan(
            request: request,
            control: control,
            existingExternalParentIDs: []
        )
        defer { codec.removeStagedAssets(plan.stagedAssets) }

        #expect(plan.atomically)
        #expect(plan.savePolicy == .ifServerRecordUnchanged)
        #expect(plan.stagedAssets.count == 1)
        #expect(plan.recordsToSave.count == 3)
        #expect(Set(plan.recordsToSave.map(\.recordType)) == [
            CloudKitSyncSchema.RecordType.workRevision,
            CloudKitSyncSchema.RecordType.workMutationReceipt,
            CloudKitSyncSchema.RecordType.workControl
        ])
        let updatedControl = try #require(
            plan.recordsToSave.first {
                $0.recordType == CloudKitSyncSchema.RecordType.workControl
            }
        )
        let decoded = try codec.decodeWorkControlRecord(
            updatedControl,
            expectedWorkID: cloudTestWorkID
        )
        #expect(decoded.headRevisionID == revision.revisionID)
        #expect(decoded.headSnapshotDigest == revision.snapshotDigest)
    }

    @Test("fake server accepts one nil-head CAS and rejects a stale competing plan atomically")
    func fakeServerEnforcesSingleHeadCAS() throws {
        let root = try makeCloudTestDirectory()
        defer { removeCloudTestDirectory(root) }
        let codec = try CloudKitRecordCodec(assetStore: CloudKitAssetStore(rootURL: root))
        let planner = CloudKitWorkPublishPlanner(codec: codec)
        let first = try makeWorkRevision(
            id: #require(UUID(uuidString: "44444444-4444-4444-8444-444444444444"))
        )
        let competing = try makeWorkRevision(
            id: #require(UUID(uuidString: "55555555-5555-4555-8555-555555555555"))
        )
        let empty = CloudKitWorkControl(
            record: nil,
            workID: cloudTestWorkID,
            headRevisionID: nil,
            headSnapshotDigest: nil
        )
        let firstPlan = try planner.makePlan(
            request: makeRequest(revision: first),
            control: empty,
            existingExternalParentIDs: []
        )
        let competingPlan = try planner.makePlan(
            request: makeRequest(revision: competing),
            control: empty,
            existingExternalParentIDs: []
        )
        defer {
            codec.removeStagedAssets(firstPlan.stagedAssets)
            codec.removeStagedAssets(competingPlan.stagedAssets)
        }

        var server = FakeWorkRecordServer()
        try server.commit(firstPlan, expectedControl: nil)
        let countAfterFirstCommit = server.records.count
        #expect(throws: FakeWorkRecordServer.Error.serverRecordChanged) {
            try server.commit(competingPlan, expectedControl: nil)
        }
        #expect(server.records.count == countAfterFirstCommit)
        #expect(
            server.records[.workRevision(competing.revisionID, workID: cloudTestWorkID)] == nil
        )
    }

    @Test("planner rejects absent external parents and immutable revision collisions")
    func invalidGraphAndCollisionAreRejected() throws {
        let root = try makeCloudTestDirectory()
        defer { removeCloudTestDirectory(root) }
        let codec = try CloudKitRecordCodec(assetStore: CloudKitAssetStore(rootURL: root))
        let planner = CloudKitWorkPublishPlanner(codec: codec)
        let parentID = try SyncRevisionID(
            rawValue: #require(UUID(uuidString: "66666666-6666-4666-8666-666666666666"))
        )
        let child = try makeWorkRevision(
            id: #require(UUID(uuidString: "88888888-8888-4888-8888-888888888888")),
            parents: [parentID]
        )
        let request = try WorkPublishRequest(
            workID: cloudTestWorkID,
            revisions: [child],
            candidateHeadRevisionID: child.revisionID,
            expectedHeadRevisionID: parentID,
            expectedHeadSnapshotDigest: SyncContentDigest(content: "parent")
        )

        #expect(throws: CloudKitWorkPublishPlanError.missingParent) {
            try planner.validate(request, existingExternalParentIDs: [])
        }
        #expect(throws: CloudKitWorkPublishPlanError.revisionCollision) {
            try planner.validate(
                request,
                existingExternalParentIDs: [parentID],
                collidingRevisionIDs: [child.revisionID]
            )
        }
    }

    private func makeRequest(revision: WorkRevision) throws -> WorkPublishRequest {
        try WorkPublishRequest(
            workID: cloudTestWorkID,
            revisions: [revision],
            candidateHeadRevisionID: revision.revisionID,
            expectedHeadRevisionID: nil,
            expectedHeadSnapshotDigest: nil
        )
    }
}

private struct FakeWorkRecordServer {
    enum Error: Swift.Error, Equatable {
        case malformedPlan
        case serverRecordChanged
        case immutableRecordCollision
    }

    private(set) var records: [CKRecord.ID: CKRecord] = [:]

    mutating func commit(
        _ plan: CloudKitWorkPublishPlan,
        expectedControl: CKRecord?
    ) throws {
        guard plan.atomically,
              plan.savePolicy == .ifServerRecordUnchanged,
              let proposedControl = plan.recordsToSave.first(where: {
                  $0.recordType == CloudKitSyncSchema.RecordType.workControl
              }) else {
            throw Error.malformedPlan
        }
        let currentControl = records[proposedControl.recordID]
        guard sameControlVersion(currentControl, expectedControl) else {
            throw Error.serverRecordChanged
        }
        let immutable = plan.recordsToSave.filter {
            $0.recordType == CloudKitSyncSchema.RecordType.workRevision
                || $0.recordType == CloudKitSyncSchema.RecordType.workMutationReceipt
        }
        guard immutable.allSatisfy({ records[$0.recordID] == nil }) else {
            throw Error.immutableRecordCollision
        }

        var committed = records
        for record in plan.recordsToSave {
            committed[record.recordID] = record
        }
        records = committed
    }

    private func sameControlVersion(_ lhs: CKRecord?, _ rhs: CKRecord?) -> Bool {
        switch (lhs, rhs) {
        case (nil, nil):
            true
        case let (lhs?, rhs?):
            lhs.recordID == rhs.recordID
                && (lhs[CloudKitSyncSchema.Field.headRevisionID] as? String)
                == (rhs[CloudKitSyncSchema.Field.headRevisionID] as? String)
                && (lhs[CloudKitSyncSchema.Field.snapshotDigest] as? String)
                == (rhs[CloudKitSyncSchema.Field.snapshotDigest] as? String)
        default:
            false
        }
    }
}

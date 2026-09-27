import Foundation
import NovelCore
import NovelSyncV2
import NovelSyncV2Store
import Testing

@Test
func concurrentFirstConflictDeliveryCreatesOneRevision() async throws {
    let root = temporaryStoreRoot("conflict-first-race")
    defer { try? FileManager.default.removeItem(at: root) }
    let workID = WorkID(UUID())
    let firstStore = try LocalSyncV2Store(root: root, policy: .createNew)
    var localDocument = makeDocument(title: "base")
    let base = try await firstStore.checkpoint(
        V2CheckpointRequest(
            workID: workID,
            document: localDocument,
            documentCreatedAt: testDate,
            expectedGeneration: 0
        ),
        scope: scopeA
    )
    localDocument.title = "local"
    let local = try await firstStore.checkpoint(
        V2CheckpointRequest(
            workID: workID,
            document: localDocument,
            documentCreatedAt: testDate,
            expectedGeneration: base.generation
        ),
        scope: scopeA
    )
    let secondStore = try LocalSyncV2Store(root: root, policy: .openExisting)
    let encoded = try remoteChild(
        workID: workID,
        localDocument: localDocument,
        parent: base.snapshotID
    )
    let remoteHead = try V2RemoteHead(snapshotID: encoded.snapshotId, generation: 2)
    let firstDelivery = remoteDelivery(
        workID: workID,
        encoded: encoded,
        local: local,
        remoteHead: remoteHead
    )
    let secondDelivery = remoteDelivery(
        workID: workID,
        encoded: encoded,
        local: local,
        remoteHead: remoteHead
    )
    async let firstConflict = firstStore.appendConflict(
        workID: workID,
        baseSnapshotID: base.snapshotID,
        localSnapshotID: local.snapshotID,
        remote: firstDelivery,
        sourceGeneration: local.generation,
        scope: scopeA
    )
    async let secondConflict = secondStore.appendConflict(
        workID: workID,
        baseSnapshotID: base.snapshotID,
        localSnapshotID: local.snapshotID,
        remote: secondDelivery,
        sourceGeneration: local.generation,
        scope: scopeA
    )
    let (first, second) = try await (firstConflict, secondConflict)
    #expect(first.conflictID == second.conflictID)
    #expect(first.revision == 1)
    #expect(second.revision == 1)
    #expect(try await firstStore.activeConflict(workID: workID, scope: scopeA) == first)
}

@Test
func unrelatedConflictBaseCannotChangeAuthoritativeState() async throws {
    let root = temporaryStoreRoot("conflict-unrelated-base")
    defer { try? FileManager.default.removeItem(at: root) }
    let workID = WorkID(UUID())
    let store = try LocalSyncV2Store(root: root, policy: .createNew)
    let localDocument = makeDocument(title: "local")
    let local = try await store.checkpoint(
        V2CheckpointRequest(
            workID: workID,
            document: localDocument,
            documentCreatedAt: testDate,
            expectedGeneration: 0
        ),
        scope: scopeA
    )
    var remoteDocument = localDocument
    remoteDocument.title = "unrelated remote root"
    let unrelated = try encodeSnapshot(workID: workID, document: remoteDocument)
    let remoteHead = try V2RemoteHead(snapshotID: unrelated.snapshotId, generation: 2)
    let delivery = remoteDelivery(
        workID: workID,
        encoded: unrelated,
        local: local,
        remoteHead: remoteHead
    )
    do {
        _ = try await store.appendConflict(
            workID: workID,
            baseSnapshotID: local.snapshotID,
            localSnapshotID: local.snapshotID,
            remote: delivery,
            sourceGeneration: local.generation,
            scope: scopeA
        )
        Issue.record("unrelated conflict base was accepted")
    } catch SyncV2StoreError.invalidSnapshot {}
    let opened = try await store.open(workID: workID, scope: scopeA)
    #expect(opened.summary.currentSnapshotID == local.snapshotID)
    #expect(opened.summary.localGeneration == local.generation)
    #expect(opened.document == localDocument)
    #expect(try await store.activeConflict(workID: workID, scope: scopeA) == nil)
    #expect(try await store.historyCount(workID: workID, scope: scopeA) == 1)
}

@Test
func fastForwardLineageCannotBeRecordedAsConflict() async throws {
    let root = temporaryStoreRoot("conflict-fast-forward-rejected")
    defer { try? FileManager.default.removeItem(at: root) }
    let workID = WorkID(UUID())
    let store = try LocalSyncV2Store(root: root, policy: .createNew)
    var document = makeDocument(title: "base")
    let baseEncoded = try encodeSnapshot(workID: workID, document: document)
    let base = try await store.checkpoint(
        V2CheckpointRequest(
            workID: workID,
            document: document,
            documentCreatedAt: testDate,
            expectedGeneration: 0
        ),
        scope: scopeA
    )
    #expect(base.snapshotID == baseEncoded.snapshotId)
    document.title = "remote child"
    let remote = try encodeSnapshot(
        workID: workID,
        document: document,
        parents: [base.snapshotID]
    )
    let delivery = try remoteDelivery(
        workID: workID,
        encoded: remote,
        local: base,
        remoteHead: V2RemoteHead(snapshotID: remote.snapshotId, generation: 2)
    )
    do {
        _ = try await store.appendConflict(
            workID: workID,
            baseSnapshotID: base.snapshotID,
            localSnapshotID: base.snapshotID,
            remote: delivery,
            sourceGeneration: base.generation,
            scope: scopeA
        )
        Issue.record("L == B was recorded as a conflict")
    } catch SyncV2StoreError.invalidSnapshot {}

    document.title = "local child"
    let local = try await store.checkpoint(
        V2CheckpointRequest(
            workID: workID,
            document: document,
            documentCreatedAt: testDate,
            expectedGeneration: base.generation
        ),
        scope: scopeA
    )
    let reverseDelivery = try remoteDelivery(
        workID: workID,
        encoded: baseEncoded,
        local: local,
        remoteHead: V2RemoteHead(snapshotID: base.snapshotID, generation: 1)
    )
    do {
        _ = try await store.appendConflict(
            workID: workID,
            baseSnapshotID: base.snapshotID,
            localSnapshotID: local.snapshotID,
            remote: reverseDelivery,
            sourceGeneration: local.generation,
            scope: scopeA
        )
        Issue.record("R == B was recorded as a conflict")
    } catch SyncV2StoreError.invalidSnapshot {}

    let opened = try await store.open(workID: workID, scope: scopeA)
    #expect(opened.summary.currentSnapshotID == local.snapshotID)
    #expect(opened.document?.title == "local child")
    #expect(try await store.activeConflict(workID: workID, scope: scopeA) == nil)
}

@Test
func fenceRotationQuarantinesOldConflictAndAllowsNewDelivery() async throws {
    let root = temporaryStoreRoot("conflict-fence-rotation")
    defer { try? FileManager.default.removeItem(at: root) }
    let workID = WorkID(UUID())
    let store = try LocalSyncV2Store(root: root, policy: .createNew)
    let fixture = try await createConflict(store: store, workID: workID)
    let nextBinding = V2AccountBinding(
        accountID: bindingA.accountID,
        accountFence: "fence-b",
        serverInstanceID: bindingA.serverInstanceID,
        protocolEpoch: bindingA.protocolEpoch
    )
    let nextScope = V2LocalWorkScope.bound(nextBinding)
    try await store.rebindWork(workID: workID, from: bindingA, to: nextBinding)
    do {
        _ = try await store.activeConflict(workID: workID, scope: scopeA)
        Issue.record("old fence could still read its conflict")
    } catch SyncV2StoreError.workNotFound {}
    #expect(try await store.activeConflict(workID: workID, scope: nextScope) == nil)

    let redelivery = V2RemoteSnapshot(
        workID: workID,
        encoded: fixture.remote.encoded,
        expectedCurrentSnapshotID: fixture.localCheckpoint.snapshotID,
        expectedLocalGeneration: fixture.localCheckpoint.generation,
        expectedRemoteHead: fixture.remoteHead
    )
    let next = try await store.appendConflict(
        workID: workID,
        baseSnapshotID: fixture.baseCheckpoint.snapshotID,
        localSnapshotID: fixture.localCheckpoint.snapshotID,
        remote: redelivery,
        sourceGeneration: fixture.localCheckpoint.generation,
        scope: nextScope
    )
    #expect(next.conflictID != fixture.conflict.conflictID)
    #expect(next.revision == 1)
    #expect(try await store.activeConflict(workID: workID, scope: nextScope) == next)
}

private func remoteChild(
    workID: WorkID,
    localDocument: NovelDocument,
    parent: SnapshotID
) throws -> EncodedSnapshot {
    var remoteDocument = localDocument
    remoteDocument.title = "remote"
    return try encodeSnapshot(
        workID: workID,
        document: remoteDocument,
        parents: [parent]
    )
}

private func remoteDelivery(
    workID: WorkID,
    encoded: EncodedSnapshot,
    local: V2CheckpointResult,
    remoteHead: V2RemoteHead
) -> V2RemoteSnapshot {
    V2RemoteSnapshot(
        workID: workID,
        encoded: encoded,
        expectedCurrentSnapshotID: local.snapshotID,
        expectedLocalGeneration: local.generation,
        expectedRemoteHead: remoteHead
    )
}

import Foundation
import NovelSyncV2
@testable import NovelSyncV2Store
import Testing

@Test
func planningQueriesPreserveExactScopeOccurrenceAndQuarantineGuards() async throws {
    let root = temporaryStoreRoot("planning-history")
    defer { try? FileManager.default.removeItem(at: root) }
    let store = try LocalSyncV2Store(root: root, policy: .createNew)
    let workID = WorkID(UUID())
    var document = makeDocument(title: "initial")
    var checkpoint = try await store.checkpoint(
        V2CheckpointRequest(workID: workID, document: document, documentCreatedAt: testDate, expectedGeneration: 0, reason: .explicit),
        scope: scopeA
    )
    let create = try createWorkCommand(workID: workID, documentID: document.id, checkpoint: checkpoint)
    try await store.seal(create, scope: scopeA)
    try await store.acknowledge(commandAcknowledgement(create, status: 201), scope: scopeA)
    for index in 0 ..< 24 {
        let publish = try await publishCommand(workID: workID, checkpoint: checkpoint,
                                               expectedHead: store.acknowledgedHead(workID: workID))
        try await store.seal(publish, intentID: checkpoint.intentID, scope: scopeA)
        try await store.acknowledge(commandAcknowledgement(
            publish, head: V2RemoteHead(snapshotID: checkpoint.snapshotID, generation: checkpoint.generation)
        ), scope: scopeA)
        document.title = "revision \(index)"
        checkpoint = try await store.checkpoint(V2CheckpointRequest(
            workID: workID, document: document, documentCreatedAt: testDate,
            expectedGeneration: checkpoint.generation, reason: .explicit
        ), scope: scopeA)
    }
    let quarantined = try await publishCommand(workID: workID, checkpoint: checkpoint,
                                               expectedHead: store.acknowledgedHead(workID: workID))
    try await store.seal(quarantined, intentID: checkpoint.intentID, scope: scopeA)
    try await store.quarantine(commandID: quarantined.commandId, scope: scopeA)
    let all = try await store.allSealedCommands(scope: scopeA, workID: workID)
    let guards = try await store.planningGuardCommands(scope: scopeA, workID: workID)
    #expect(guards.map(\.commandID) == [create.commandId, quarantined.commandId])
    try await expectExactTransferSelection(store: store, workID: workID, records: all)
    let otherFence = V2LocalWorkScope.bound(V2AccountBinding(
        accountID: bindingA.accountID, accountFence: "other-fence", serverInstanceID: bindingA.serverInstanceID
    ))
    #expect(try await store.planningGuardCommands(scope: otherFence, workID: workID).isEmpty)
    #expect(try await store.completedTransferCommands(
        scope: otherFence, workID: workID, snapshotID: checkpoint.snapshotID, generation: checkpoint.generation
    ).isEmpty)
    #expect(try await store.planningGuardCommands(scope: scopeA, workID: WorkID(UUID())).isEmpty)
    await #expect(throws: SyncV2StoreError.accountMismatch) {
        try await store.planningGuardCommands(scope: .unbound, workID: workID)
    }
    await store.close()
}

@Test
func hexadecimalEncodingPreservesEveryByteAndSlices() {
    let bytes = Data(0 ... 255)
    let expected = (0 ... 255).map { String(format: "%02x", $0) }.joined()
    #expect(bytes.hexString == expected)
    #expect(Data().hexString == "")
    #expect(bytes.dropFirst(16).hexString == String(expected.dropFirst(32)))
}

private func expectExactTransferSelection(
    store: LocalSyncV2Store, workID: WorkID, records all: [V2SealedCommandRecord]
) async throws {
    for record in all {
        let selected = try await store.completedTransferCommands(
            scope: scopeA, workID: workID, snapshotID: record.sourceSnapshotID, generation: record.sourceGeneration
        )
        let expected = all.filter {
            $0.lifecycle == .completed && $0.sourceSnapshotID == record.sourceSnapshotID &&
                $0.sourceGeneration == record.sourceGeneration
        }
        #expect(selected.map(\.canonicalRequest) == expected.map(\.canonicalRequest))
        #expect(selected.map(\.requestDigest) == expected.map(\.requestDigest))
    }
}

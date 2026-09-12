import Foundation
import NovelSyncV2
import NovelSyncV2Store
import Testing

@Test func explicitSyncQueuesAnUnchangedSnapshotAndSurvivesRestart() async throws {
    let root = temporaryStoreRoot("explicit-sync")
    defer { try? FileManager.default.removeItem(at: root) }
    let store = try LocalSyncV2Store(root: root, policy: .createNew)
    let workID = WorkID(UUID())
    let document = makeDocument(title: "unchanged")
    let saved = try await store.checkpoint(V2CheckpointRequest(
        workID: workID, document: document, documentCreatedAt: testDate, expectedGeneration: 0
    ), scope: scopeA)
    // Model a previously acknowledged checkpoint without leaving a pending lane.
    #expect(try sqliteExecutionSucceeded(databaseURL: root.appendingPathComponent("snapshot-sync-v2.sqlite"), sql: "UPDATE sync_intents SET status='acknowledged'"))
    try await store.requestSynchronization(workID: workID, scope: scopeA)
    let first = try await store.pendingIntents(scope: scopeA, workID: workID)
    #expect(first.count == 1)
    #expect(first.first?.sourceSnapshotID == saved.snapshotID)
    #expect(first.first?.sourceGeneration == saved.generation)
    try await store.requestSynchronization(workID: workID, scope: scopeA)
    #expect(try await store.pendingIntents(scope: scopeA, workID: workID).first?.intentID == first.first?.intentID)
    #expect(try await store.open(workID: workID, scope: scopeA).document == document)
    await store.close()
    let reopened = try LocalSyncV2Store(root: root, policy: .openExisting)
    #expect(try await reopened.pendingIntents(scope: scopeA, workID: workID).first?.intentID == first.first?.intentID)
    await reopened.close()
}

@Test func explicitSyncRejectsAnUnboundWork() async throws {
    let root = temporaryStoreRoot("explicit-sync-unbound")
    defer { try? FileManager.default.removeItem(at: root) }
    let store = try LocalSyncV2Store(root: root, policy: .createNew)
    let workID = WorkID(UUID())
    _ = try await store.checkpoint(V2CheckpointRequest(
        workID: workID, document: makeDocument(title: "local"), documentCreatedAt: testDate, expectedGeneration: 0
    ), scope: .unbound)
    await #expect(throws: SyncV2StoreError.accountMismatch) {
        try await store.requestSynchronization(workID: workID, scope: .unbound)
    }
    await store.close()
}

@Test func explicitSyncRetriesTheOriginalCreationWithoutChangingItsBytes() async throws {
    let root = temporaryStoreRoot("explicit-create-recovery")
    defer { try? FileManager.default.removeItem(at: root) }
    let store = try LocalSyncV2Store(root: root, policy: .createNew)
    let workID = WorkID(UUID())
    let document = makeDocument(title: "recovery")
    let saved = try await store.checkpoint(V2CheckpointRequest(
        workID: workID, document: document, documentCreatedAt: testDate, expectedGeneration: 0
    ), scope: scopeA)
    let first = try createWorkCommand(workID: workID, documentID: document.id, checkpoint: saved)
    let duplicate = try createWorkCommand(workID: workID, documentID: document.id, checkpoint: saved)
    for command in [first, duplicate] {
        try await store.seal(command, scope: scopeA)
        try await store.quarantine(commandID: command.commandId, scope: scopeA)
    }
    await store.close()
    let reopened = try LocalSyncV2Store(root: root, policy: .openExisting)
    await #expect(throws: SyncV2StoreError.accountMismatch) {
        try await reopened.requestSynchronization(workID: workID, scope: .bound(V2AccountBinding(accountID: "other", accountFence: "other", serverInstanceID: bindingA.serverInstanceID)))
    }
    try await reopened.requestSynchronization(workID: workID, scope: scopeA)
    try await reopened.requestSynchronization(workID: workID, scope: scopeA)
    let pending = try await reopened.pendingSealedCommands(scope: scopeA, workID: workID)
    #expect(pending.count == 1)
    #expect(pending.first?.commandID == first.commandId)
    #expect(pending.first?.canonicalRequest == first.canonicalBytes)
    #expect(try await reopened.allSealedCommands(scope: scopeA, workID: workID).last?.lifecycle == .quarantined)
    #expect(try await reopened.open(workID: workID, scope: scopeA).document == document)
    await reopened.close()
}

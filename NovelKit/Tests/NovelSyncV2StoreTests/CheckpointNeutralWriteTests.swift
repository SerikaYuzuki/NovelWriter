import Foundation
import NovelSyncV2
@testable import NovelSyncV2Store
import Testing

@Test
func checkpointCacheSurvivesReviewedOutboxStateChanges() async throws {
    let root = temporaryStoreRoot("checkpoint-neutral-outbox")
    defer { try? FileManager.default.removeItem(at: root) }
    let store = try LocalSyncV2Store(root: root, policy: .createNew)
    let work = WorkID(UUID())
    let first = try await store.checkpoint(V2CheckpointRequest(workID: work, document: makeDocument(title: "test"),
                                                               documentCreatedAt: testDate, expectedGeneration: 0),
                                           scope: scopeA)
    let count = await store.checkpointFullValidationCount
    try await store.requestSynchronization(workID: work, scope: scopeA)
    let intent = try #require(try await store.pendingIntents(scope: scopeA, workID: work).first)
    let command = try publishCommand(workID: work, checkpoint: first)
    try await store.seal(command, intentID: intent.intentID, scope: scopeA)
    _ = try await store.markSending(commandID: command.commandId, scope: scopeA)
    try await store.requeue(commandID: command.commandId, scope: scopeA)
    try await store.retryUnacknowledgedCommands(scope: scopeA)
    try await store.retryUnacknowledgedCommands(workID: work, scope: scopeA)
    try await store.quarantine(commandID: command.commandId, scope: scopeA, reason: "test")
    try await store.requestSynchronization(workID: work, scope: scopeA)
    try await store.park(commandID: command.commandId, scope: scopeA)
    try await store.validateCheckpointBase(workID: work, scope: scopeA)
    #expect(await store.checkpointFullValidationCount == count)
    #expect(try await store.workSummary(workID: work, scope: scopeA).currentSnapshotID == first.snapshotID)
    await store.close()
}

@Test
func fullyValidatedOpenSeedsFirstAutosaveButEveryOpenValidates() async throws {
    let root = temporaryStoreRoot("checkpoint-open-seed")
    defer { try? FileManager.default.removeItem(at: root) }
    let store = try LocalSyncV2Store(root: root, policy: .createNew)
    let work = WorkID(UUID()), document = makeDocument(title: "test")
    let first = try await store.checkpoint(V2CheckpointRequest(workID: work, document: document,
                                                               documentCreatedAt: testDate, expectedGeneration: 0),
                                           scope: scopeA)
    let before = await store.checkpointFullValidationCount
    _ = try await store.open(workID: work, scope: scopeA)
    #expect(await store.checkpointFullValidationCount == before + 1)
    _ = try await store.checkpoint(V2CheckpointRequest(workID: work, document: document,
                                                       documentCreatedAt: testDate,
                                                       expectedGeneration: first.generation),
                                   scope: scopeA)
    #expect(await store.checkpointFullValidationCount == before + 1)
    _ = try await store.open(workID: work, scope: scopeA)
    #expect(await store.checkpointFullValidationCount == before + 2)
    await store.close()
}

@Test(arguments: ["external", "sameConnection", "rollback", "generation"])
func neutralWritesNeverRefreshStaleOrRolledBackValidation(kind: String) async throws {
    let root = temporaryStoreRoot("checkpoint-neutral-stale")
    defer { try? FileManager.default.removeItem(at: root) }
    let store = try LocalSyncV2Store(root: root, policy: .createNew)
    let work = WorkID(UUID())
    _ = try await store.checkpoint(V2CheckpointRequest(workID: work, document: makeDocument(title: "test"),
                                                       documentCreatedAt: testDate, expectedGeneration: 0),
                                   scope: scopeA)
    let before = await store.checkpointFullValidationCount
    if kind == "external" {
        let databaseURL = await store.databaseURL
        #expect(try sqliteExecutionSucceeded(
            databaseURL: databaseURL,
            sql: "UPDATE works SET acknowledged_head_snapshot_id=current_snapshot_id, acknowledged_head_generation=1"
        ))
        _ = try await store.promoteCurrentLeaf(workID: work, scope: scopeA)
    } else {
        try await store.simulateUnreviewedWrite(kind: kind)
    }
    #expect(await store.checkpointValidation == nil)
    try await store.validateCheckpointBase(workID: work, scope: scopeA)
    #expect(await store.checkpointFullValidationCount == before + 1)
    await store.close()
}

@Test
func externalCorruptionIsRejectedAfterNeutralPromotion() async throws {
    let root = temporaryStoreRoot("checkpoint-neutral-corrupt")
    defer { try? FileManager.default.removeItem(at: root) }
    let store = try LocalSyncV2Store(root: root, policy: .createNew)
    let work = WorkID(UUID())
    _ = try await store.checkpoint(V2CheckpointRequest(workID: work, document: makeDocument(title: "test"),
                                                       documentCreatedAt: testDate, expectedGeneration: 0),
                                   scope: scopeA)
    let databaseURL = await store.databaseURL
    #expect(try sqliteExecutionSucceeded(databaseURL: databaseURL,
                                         sql: "DROP TRIGGER objects_immutable_update; " +
                                             "UPDATE objects SET bytes=x'00',byte_count=1"))
    _ = try await store.promoteCurrentLeaf(workID: work, scope: scopeA)
    #expect(await store.checkpointValidation == nil)
    await #expect(throws: (any Error).self) { try await store.validateCheckpointBase(workID: work, scope: scopeA) }
    await store.close()
}

@Test
func externalWriteAfterFullReadDiscardsStampWithoutFailingOpenResult() async throws {
    let root = temporaryStoreRoot("checkpoint-read-bookkeeping")
    defer { try? FileManager.default.removeItem(at: root) }
    let store = try LocalSyncV2Store(root: root, policy: .createNew)
    let work = WorkID(UUID())
    _ = try await store.checkpoint(V2CheckpointRequest(workID: work, document: makeDocument(title: "safe"),
                                                       documentCreatedAt: testDate, expectedGeneration: 0),
                                   scope: scopeA)
    try await store.simulateExternalWriteAfterFullRead(work: work)
    #expect(await store.checkpointValidation == nil)
    let before = await store.checkpointFullValidationCount
    try await store.validateCheckpointBase(workID: work, scope: scopeA)
    #expect(await store.checkpointFullValidationCount == before + 1)
    await store.close()
}

private extension LocalSyncV2Store {
    func simulateExternalWriteAfterFullRead(work: WorkID) throws {
        let row = try #require(try workRepository.scopedWorkRow(workID: work, scope: scopeA))
        let before = try checkpointStamp(workID: work, scope: scopeA, row: row)
        let opened = try workRepository.open(workID: work, scope: scopeA)
        #expect(try sqliteExecutionSucceeded(databaseURL: databaseURL,
                                             sql: "UPDATE works SET " +
                                                 "acknowledged_head_snapshot_id=current_snapshot_id, " +
                                                 "acknowledged_head_generation=1"))
        rememberStableRead(before)
        #expect(opened.document?.title == "safe")
    }

    func simulateUnreviewedWrite(kind: String) throws {
        switch kind {
        case "sameConnection":
            try exec("UPDATE works SET local_generation=local_generation")
            guard let cached = checkpointValidation else { throw SyncV2StoreError.invalidSnapshot }
            _ = try promoteCurrentLeaf(workID: cached.workID, scope: scopeA)
        case "generation":
            try inCheckpointNeutralTransaction { try exec("UPDATE works SET local_generation=local_generation+1") }
        default:
            do {
                try inCheckpointNeutralTransaction {
                    try exec("UPDATE works SET local_generation=local_generation")
                    throw SyncV2StoreError.invalidCommand
                }
            } catch SyncV2StoreError.invalidCommand { /* Deliberate rollback must discard the token. */ }
        }
    }
}

import Foundation
import NovelCore
import NovelSyncV2
import NovelSyncV2Store
import Testing

@Test func workDeletionPersistsAndPurgesOnlyItsGraph() async throws {
    let root = temporaryStoreRoot("deletion")
    defer { try? FileManager.default.removeItem(at: root) }
    let store = try LocalSyncV2Store(root: root, policy: .createNew)
    let target = WorkID(UUID()), retained = WorkID(UUID())
    let shared = SyncAttachment(attachmentId: UUID(), fileName: "shared.txt", bytes: Data("shared".utf8))
    for work in [target, retained] {
        _ = try await store.checkpoint(
            V2CheckpointRequest(
                workID: work,
                document: makeDocument(title: work.description),
                documentCreatedAt: testDate,
                expectedGeneration: 0, reason: .explicit,
                attachments: [shared]
            ),
            scope: .unbound
        )
    }
    let deletion = try await store.prepareWorkDeletion(workID: target, activeBinding: nil)
    #expect(!deletion.completed)
    #expect(try await store.open(workID: target, scope: .unbound).attachments == [shared])
    await #expect(throws: SyncV2StoreError.workDeletionPending) {
        try await store.checkpoint(
            V2CheckpointRequest(
                workID: target,
                document: makeDocument(title: "late"),
                documentCreatedAt: testDate,
                expectedGeneration: 1, reason: .explicit
            ),
            scope: .unbound
        )
    }
    await store.close()
    let reopened = try LocalSyncV2Store(root: root, policy: .openExisting)
    #expect(try await reopened.prepareWorkDeletion(workID: target, activeBinding: nil) == deletion)
    try await reopened.completeWorkDeletion(deletion)
    let complete = try #require(await reopened.workDeletion(workID: target))
    #expect(complete.completed)
    try await reopened.completeWorkDeletion(complete)
    await #expect(throws: SyncV2StoreError.workNotFound) { try await reopened.open(workID: target, scope: .unbound) }
    #expect(try await reopened.open(workID: retained, scope: .unbound).attachments == [shared])
    let second = try await reopened.prepareWorkDeletion(workID: retained, activeBinding: nil)
    try await reopened.completeWorkDeletion(second)
    let url = await reopened.databaseURL
    #expect(try sqliteScalarInt(databaseURL: url, sql: "SELECT COUNT(*) FROM objects") == 0)
    #expect(try sqliteScalarInt(databaseURL: url, sql: "SELECT COUNT(*) FROM snapshots") == 0)
    #expect(try sqliteScalarInt(databaseURL: url, sql: "SELECT COUNT(*) FROM work_deletions") == 2)
}

@Test func previousSchemaGainsDeletionJournalWithoutChangingWork() async throws {
    let root = temporaryStoreRoot("deletion-upgrade")
    defer { try? FileManager.default.removeItem(at: root) }
    let store = try LocalSyncV2Store(root: root, policy: .createNew)
    let workID = WorkID(UUID())
    let document = makeDocument(title: "migration survivor")
    _ = try await store.checkpoint(
        V2CheckpointRequest(workID: workID, document: document, documentCreatedAt: testDate, expectedGeneration: 0, reason: .explicit),
        scope: scopeA
    )
    let url = await store.databaseURL
    await store.close()
    let current = try SnapshotSyncV2SchemaContract.resourceSQL()
    let previous = String(decoding: current, as: UTF8.self).components(separatedBy: "\n-- Work deletion journal.")[0]
    let checksum = SnapshotSyncV2SchemaContract.checksum(Data(previous.utf8)).map { String(format: "%02x", $0) }.joined()
    #expect(try sqliteExecutionSucceeded(databaseURL: url, sql: """
    DROP TABLE legacy_command_recovery; DROP TABLE history_backfills; DROP TABLE shallow_boundaries; DROP TABLE work_deletions;
    UPDATE schema_meta SET checksum=X'\(checksum)' WHERE key='schema';
    """))
    let upgraded = try LocalSyncV2Store(root: root, policy: .openExisting)
    #expect(try await upgraded.open(workID: workID, scope: scopeA).document == document)
    #expect(try await upgraded.workDeletionIDs().isEmpty)
    await upgraded.close()
}

@Test func pendingDeletionReplansOnlyWithinSameAccountAfterFenceRotation() async throws {
    let root = temporaryStoreRoot("deletion-fence")
    defer { try? FileManager.default.removeItem(at: root) }
    let store = try LocalSyncV2Store(root: root, policy: .createNew)
    let workID = WorkID(UUID())
    _ = try await store.checkpoint(
        V2CheckpointRequest(workID: workID, document: makeDocument(title: "preserved"),
                            documentCreatedAt: testDate, expectedGeneration: 0, reason: .explicit), scope: scopeA
    )
    let old = try await store.prepareWorkDeletion(workID: workID, activeBinding: bindingA)
    let rotated = V2AccountBinding(accountID: bindingA.accountID, accountFence: "new-fence",
                                   serverInstanceID: bindingA.serverInstanceID)
    try await store.transitionAccountScopes(from: bindingA, to: rotated)
    await store.close()
    let reopened = try LocalSyncV2Store(root: root, policy: .openExisting)
    for wrong in [
        V2AccountBinding(accountID: "other", accountFence: rotated.accountFence, serverInstanceID: rotated.serverInstanceID),
        V2AccountBinding(accountID: rotated.accountID, accountFence: rotated.accountFence, serverInstanceID: "other"),
        V2AccountBinding(accountID: rotated.accountID, accountFence: rotated.accountFence, serverInstanceID: rotated.serverInstanceID, protocolEpoch: 99)
    ] {
        await #expect(throws: SyncV2StoreError.accountMismatch) {
            try await reopened.prepareWorkDeletion(workID: workID, activeBinding: wrong)
        }
    }
    let current = try await reopened.prepareWorkDeletion(workID: workID, activeBinding: rotated)
    #expect(current.binding == rotated)
    #expect(!current.completed)
    await #expect(throws: SyncV2StoreError.invalidLifecycle) { try await reopened.completeWorkDeletion(old) }
    try await reopened.completeWorkDeletion(current)
    #expect(try await reopened.workDeletion(workID: workID)?.completed == true)
    await reopened.close()
}

@Test func deletingPortableResourcesKeepsSharedBytesUntilLastReference() async throws {
    let root = temporaryStoreRoot("deletion-resource")
    defer { try? FileManager.default.removeItem(at: root) }
    let store = try LocalSyncV2Store(root: root, policy: .createNew)
    let first = WorkID(UUID()), second = WorkID(UUID())
    let shared = PortableResource(pathComponents: ["opaque.bin"], kind: .regularFile, bytes: Data("shared".utf8))
    let owned = PortableResource(pathComponents: ["private.bin"], kind: .regularFile, bytes: Data("owned".utf8))
    for workID in [first, second] {
        _ = try await store.checkpoint(V2CheckpointRequest(
            workID: workID, document: makeDocument(title: "resources"), documentCreatedAt: testDate,
            expectedGeneration: 0, reason: .explicit, resources: workID == first ? [shared, owned] : [shared]
        ), scope: .unbound)
    }
    let deletion = try await store.prepareWorkDeletion(workID: first, activeBinding: nil)
    try await store.completeWorkDeletion(deletion)
    #expect(try await store.open(workID: second, scope: .unbound).resources == [shared])
    let url = await store.databaseURL
    #expect(try sqliteScalarInt(databaseURL: url, sql: "SELECT COUNT(*) FROM resources") == 1)
    let last = try await store.prepareWorkDeletion(workID: second, activeBinding: nil)
    try await store.completeWorkDeletion(last)
    #expect(try sqliteScalarInt(databaseURL: url, sql: "SELECT COUNT(*) FROM resources") == 0)
    await store.close()
}

@Test func synchronizedDeletionKeepsUnsentCheckpointForLocalRescue() async throws {
    let root = temporaryStoreRoot("deletion-rescue")
    defer { try? FileManager.default.removeItem(at: root) }
    let store = try LocalSyncV2Store(root: root, policy: .createNew)
    let work = WorkID(UUID()), rescued = WorkID(UUID())
    let original = makeDocument(title: "unsent original")
    let file = SyncAttachment(attachmentId: UUID(), fileName: "material.txt", bytes: Data("private note".utf8))
    _ = try await store.checkpoint(V2CheckpointRequest(workID: work, document: original,
                                                       documentCreatedAt: testDate, expectedGeneration: 0, reason: .explicit, attachments: [file]), scope: scopeA)
    let pendingDate = try #require(await store.oldestUnreceivedChange(workID: work, scope: scopeA))
    var updated = original
    updated.title = "last unsent title"
    _ = try await store.checkpoint(V2CheckpointRequest(workID: work, document: updated,
                                                       documentCreatedAt: testDate, expectedGeneration: 1, reason: .explicit, attachments: [file]), scope: scopeA)
    #expect(try await store.oldestUnreceivedChange(workID: work, scope: scopeA) == pendingDate)
    #expect(try await store.oldestUnreceivedChange(workID: work, scope: .unbound) == nil)
    let deletion = try await store.prepareWorkDeletion(workID: work, activeBinding: bindingA)
    try await store.completeWorkDeletion(deletion)
    let rescue = try await store.rescueLocalWork(sourceWorkID: work, sourceScope: scopeA,
                                                 newWorkID: rescued, newDocumentID: DocumentID(UUID()))
    #expect(rescue.document?.title == updated.title)
    #expect(rescue.document?.id != original.id)
    #expect(rescue.attachments == [file])
    #expect(try await store.open(workID: work, scope: scopeA).document == updated)
    #expect(try await store.pendingIntents(scope: scopeA, workID: rescued).isEmpty)
    #expect(try await store.open(workID: rescued, scope: .unbound).document == rescue.document)
    await store.close()
}

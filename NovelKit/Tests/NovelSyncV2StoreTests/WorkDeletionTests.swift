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
                expectedGeneration: 0,
                attachments: [shared]
            ),
            scope: scopeA
        )
    }
    let wrong = V2AccountBinding(accountID: "other", accountFence: "other", serverInstanceID: "other")
    await #expect(throws: SyncV2StoreError.accountMismatch) {
        try await store.prepareWorkDeletion(workID: target, activeBinding: wrong)
    }
    let deletion = try await store.prepareWorkDeletion(workID: target, activeBinding: bindingA)
    #expect(!deletion.completed)
    #expect(try await store.open(workID: target, scope: scopeA).attachments == [shared])
    await #expect(throws: SyncV2StoreError.workDeletionPending) {
        try await store.checkpoint(
            V2CheckpointRequest(
                workID: target,
                document: makeDocument(title: "late"),
                documentCreatedAt: testDate,
                expectedGeneration: 1
            ),
            scope: scopeA
        )
    }
    await store.close()
    let reopened = try LocalSyncV2Store(root: root, policy: .openExisting)
    #expect(try await reopened.prepareWorkDeletion(workID: target, activeBinding: bindingA) == deletion)
    try await reopened.completeWorkDeletion(deletion)
    let complete = try #require(await reopened.workDeletion(workID: target))
    #expect(complete.completed)
    try await reopened.completeWorkDeletion(complete)
    await #expect(throws: SyncV2StoreError.workNotFound) { try await reopened.open(workID: target, scope: scopeA) }
    #expect(try await reopened.open(workID: retained, scope: scopeA).attachments == [shared])
    let second = try await reopened.prepareWorkDeletion(workID: retained, activeBinding: bindingA)
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
        V2CheckpointRequest(workID: workID, document: document, documentCreatedAt: testDate, expectedGeneration: 0),
        scope: scopeA
    )
    let url = await store.databaseURL
    await store.close()
    let current = try SnapshotSyncV2SchemaContract.resourceSQL()
    let previous = String(decoding: current, as: UTF8.self).components(separatedBy: "\n-- Work deletion journal.")[0]
    let checksum = SnapshotSyncV2SchemaContract.checksum(Data(previous.utf8)).map { String(format: "%02x", $0) }.joined()
    #expect(try sqliteExecutionSucceeded(databaseURL: url, sql: "DROP TABLE work_deletions; UPDATE schema_meta SET checksum=X'\(checksum)' WHERE key='schema';"))
    let upgraded = try LocalSyncV2Store(root: root, policy: .openExisting)
    #expect(try await upgraded.open(workID: workID, scope: scopeA).document == document)
    #expect(try await upgraded.workDeletionIDs().isEmpty)
    await upgraded.close()
}

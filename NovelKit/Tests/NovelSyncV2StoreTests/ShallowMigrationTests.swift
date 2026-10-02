import CSQLite
import Foundation
import NovelSyncV2
@testable import NovelSyncV2Store
import Testing

@Test(arguments: ["\n-- Work deletion journal.", "\n-- Shallow history (D-106)."])
func shallowMigrationAttestsEveryTail(marker: String) async throws {
    let root = temporaryStoreRoot("shallow-migration")
    defer { try? FileManager.default.removeItem(at: root) }
    let store = try LocalSyncV2Store(root: root, policy: .createNew)
    let databaseURL = await store.databaseURL
    await store.close()
    let sql = try String(decoding: V2StoreSchema.resourceSQL(), as: UTF8.self)
    let old = Data(sql.components(separatedBy: marker)[0].utf8)
    let checksum = V2StoreSchema.checksum(old).hexString
    let deletion = marker.contains("deletion") ? "DROP TABLE work_deletions;" : ""
    #expect(try sqliteExecutionSucceeded(databaseURL: databaseURL, sql: """
    DROP TABLE legacy_command_recovery; DROP TABLE history_backfills; DROP TABLE shallow_boundaries;
    \(deletion) UPDATE schema_meta SET checksum=X'\(checksum)' WHERE key='schema';
    """))
    let upgraded = try LocalSyncV2Store(root: root, policy: .openExisting)
    #expect(try await upgraded.query("SELECT COUNT(*) FROM shallow_boundaries").first?.scalar.int64 == 0)
    #expect(try await upgraded.schemaVersionAndChecksum().1 == V2StoreSchema.checksum(Data(sql.utf8)))
    await upgraded.close()
}

@Test func shallowMigrationRejectsTamperedTriggerWithoutUpgrading() async throws {
    let root = temporaryStoreRoot("shallow-tamper")
    defer { try? FileManager.default.removeItem(at: root) }
    let store = try LocalSyncV2Store(root: root, policy: .createNew)
    let url = await store.databaseURL
    await store.close()
    #expect(try sqliteExecutionSucceeded(databaseURL: url, sql: "DROP TRIGGER shallow_boundaries_guard_delete"))
    #expect(throws: SyncV2StoreError.schemaMismatch) { try LocalSyncV2Store(root: root, policy: .openExisting) }
}

@Test func shallowInstallCASBindingAndCancellationRollback() async throws {
    let root = temporaryStoreRoot("shallow-cancel")
    defer { try? FileManager.default.removeItem(at: root) }
    let fixture = try ShallowFixture()
    let store = try LocalSyncV2Store(root: root, policy: .createNew)
    await #expect(throws: SyncV2StoreError.staleCAS) {
        try await store.installShallowHead(fixture.graph, scope: .unbound)
    }
    try await store.cancelShallowInstallAfterWrite()
    let task = Task { try await store.installShallowHead(fixture.graph, scope: scopeA) }
    await #expect(throws: CancellationError.self) { try await task.value }
    for table in ["works", "snapshots", "objects", "shallow_boundaries", "history_backfills"] {
        #expect(try await store.query("SELECT COUNT(*) FROM \(table)").first?.scalar.int64 == 0)
    }
    try await store.exec("DROP TRIGGER cancel_shallow")
    try await store.installShallowHead(fixture.graph, scope: scopeA)
    await #expect(throws: SyncV2StoreError.staleCAS) { try await store.installShallowHead(fixture.graph, scope: scopeA)
    }
    let foreign = V2AccountBinding(accountID: "foreign", accountFence: "x", serverInstanceID: bindingA.serverInstanceID)
    await #expect(throws: SyncV2StoreError.accountMismatch) {
        try await store.installShallowHead(fixture.graph, scope: .bound(foreign))
    }
    await store.close()
}

@Test func differentAccountParksBackfillAndDeletionPreservesBoundWork() async throws {
    let root = temporaryStoreRoot("shallow-park")
    defer { try? FileManager.default.removeItem(at: root) }
    let fixture = try ShallowFixture()
    let store = try LocalSyncV2Store(root: root, policy: .createNew)
    try await store.installShallowHead(fixture.graph, scope: scopeA)
    let foreign = V2AccountBinding(accountID: "foreign", accountFence: "x", serverInstanceID: bindingA.serverInstanceID)
    try await store.transitionAccountScopes(from: bindingA, to: foreign)
    await #expect(throws: SyncV2StoreError.accountMismatch) { try await store.resumeBackfill(
        workID: fixture.workID,
        binding: foreign
    ) }
    #expect(try await store.open(workID: fixture.workID, scope: .parked).document?.title == "version 3")
    try await store.transitionAccountScopes(from: foreign, to: bindingA)
    let deletion = try await store.prepareWorkDeletion(workID: fixture.workID, activeBinding: bindingA)
    await #expect(throws: SyncV2StoreError.workDeletionPending) {
        try await store.applyBackfillPage(
            fixture.page(),
            workID: fixture.workID,
            binding: bindingA,
            root: fixture.head.snapshotId,
            expectedCursor: nil
        )
    }
    try await store.completeWorkDeletion(deletion)
    #expect(try await store.backfillState(workID: fixture.workID) != nil)
    await store.close()
}

@Test func backfillInvalidatesRegistrationCacheAndKeepsPublishBase() async throws {
    let root = temporaryStoreRoot("shallow-cache")
    defer { try? FileManager.default.removeItem(at: root) }
    let fixture = try ShallowFixture()
    let store = try LocalSyncV2Store(root: root, policy: .createNew)
    try await store.installShallowHead(fixture.graph, scope: scopeA)
    let registered = try await store.registeredSnapshotIDs(workID: fixture.workID, binding: bindingA)
    #expect(registered == [fixture.head.snapshotId])
    var document = try #require(try await store.open(workID: fixture.workID, scope: scopeA).document)
    document.title = "new leaf"
    let saved = try await store.checkpoint(V2CheckpointRequest(
        workID: fixture.workID,
        document: document,
        documentCreatedAt: testDate,
        expectedGeneration: 1,
        reason: .autosave
    ), scope: scopeA)
    #expect(try await store.promoteCurrentLeaf(workID: fixture.workID, scope: scopeA))
    #expect(try await store.publishBaseHead(workID: fixture.workID, snapshotID: saved.snapshotID)?.snapshotID == fixture
        .head.snapshotId)
    try await store.applyBackfillPage(
        fixture.page(),
        workID: fixture.workID,
        binding: bindingA,
        root: fixture.head.snapshotId,
        expectedCursor: nil
    )
    let after = try await store.registeredSnapshotIDs(workID: fixture.workID, binding: bindingA)
    let expectedIDs = Set(fixture.snapshots.map(\.snapshotId))
    #expect(after == expectedIDs)
    #expect(try await store.publishBaseHead(workID: fixture.workID, snapshotID: saved.snapshotID)?.snapshotID == fixture
        .head.snapshotId)
    await store.close()
}

private extension LocalSyncV2Store {
    func cancelShallowInstallAfterWrite() throws {
        let result = sqlite3_create_function_v2(
            executor.connection,
            "cancel_shallow_task",
            0,
            SQLITE_UTF8,
            nil,
            { context, _, _ in
                withUnsafeCurrentTask { $0?.cancel() }
                sqlite3_result_null(context)
            },
            nil,
            nil,
            nil
        )
        #expect(result == SQLITE_OK)
        try exec(
            "CREATE TEMP TRIGGER cancel_shallow AFTER INSERT ON history_backfills BEGIN SELECT cancel_shallow_task(); END"
        )
    }
}

@Test(arguments: [0, 1, 2])
func everyAcceptedLegacyChecksumMigratesToShallowSchema(index: Int) async throws {
    let source = try String(decoding: V2StoreSchema.resourceSQL(), as: UTF8.self)
    let base = Data(source.components(separatedBy: "\n-- Work deletion journal.")[0].utf8)
    let schemas = [V2StoreSchema.legacyResourceSQL(from: base),
                   V2StoreSchema.withoutTransferJournalSQL(from: base),
                   V2StoreSchema.legacyTransferResourceSQL(from: base)]
    let checksums = ["745d947270838584aa854262fd794c7808316a0aa507966a22e9d33fe9cccf74",
                     "e38615c6acc8bbe4b16d28ec9144bf75c1cbf239024ae06b8cb77a2729ec43fa",
                     "9af3fd4c7a743ccce0810aea444b93fd7df060b4d48a78fc5156555afbe98280"]
    #expect(V2StoreSchema.checksum(schemas[index]).hexString == checksums[index])
    let root = temporaryStoreRoot("shallow-legacy-\(index)")
    defer { try? FileManager.default.removeItem(at: root) }
    let store = try LocalSyncV2Store(root: root, policy: .createNew)
    let url = await store.databaseURL
    await store.close()
    try FileManager.default.removeItem(at: url)
    var db: OpaquePointer?
    #expect(sqlite3_open(url.path, &db) == SQLITE_OK)
    let handle = try #require(db)
    let sql = String(decoding: schemas[index], as: UTF8.self) +
        "INSERT INTO schema_meta(key,value,checksum) VALUES('schema','2',X'\(checksums[index])');"
    #expect(sqlite3_exec(handle, sql, nil, nil, nil) == SQLITE_OK)
    sqlite3_close(handle)
    let migrated = try LocalSyncV2Store(root: root, policy: .openExisting)
    #expect(try await migrated.schemaVersionAndChecksum().1 == V2StoreSchema.checksum(Data(source.utf8)))
    await migrated.close()
}

import Foundation
import NovelCore
import NovelSyncV2
@testable import NovelSyncV2Store
import Testing

@Test
func checkpointCacheSeedsOnlyAfterFullValidationOrCommit() async throws {
    let root = temporaryStoreRoot("checkpoint-cache")
    defer { try? FileManager.default.removeItem(at: root) }
    let store = try LocalSyncV2Store(root: root, policy: .createNew)
    let work = WorkID(UUID())
    let document = makeDocument(title: "cached")
    let result = try await store.checkpoint(V2CheckpointRequest(workID: work,
                                                                document: document,
                                                                documentCreatedAt: testDate,
                                                                expectedGeneration: 0),
                                            scope: scopeA)
    let count = await store.checkpointFullValidationCount
    try await store.validateCheckpointBase(workID: work, scope: scopeA)
    #expect(await store.checkpointFullValidationCount == count)
    // Account scope is part of the key. A failed lookup also discards the token.
    await #expect(throws: SyncV2StoreError.workNotFound) {
        try await store.validateCheckpointBase(workID: work, scope: .unbound)
    }
    try await store.validateCheckpointBase(workID: work, scope: scopeA)
    #expect(await store.checkpointFullValidationCount == count + 1)
    _ = try await store.checkpoint(V2CheckpointRequest(workID: work,
                                                       document: document,
                                                       documentCreatedAt: testDate,
                                                       expectedGeneration: result.generation), scope: scopeA)
    _ = try await store.open(workID: work, scope: scopeA)
    let afterOpen = await store.checkpointFullValidationCount
    try await store.validateCheckpointBase(workID: work, scope: scopeA)
    #expect(await store.checkpointFullValidationCount == afterOpen)
    // A real account transition invalidates even when the snapshot ID remains unchanged.
    _ = try await store.checkpoint(V2CheckpointRequest(workID: work,
                                                       document: document,
                                                       documentCreatedAt: testDate,
                                                       expectedGeneration: result.generation), scope: scopeA)
    try await store.parkWork(workID: work, binding: bindingA)
    let afterPark = await store.checkpointFullValidationCount
    try await store.validateCheckpointBase(workID: work, scope: .parked)
    #expect(await store.checkpointFullValidationCount == afterPark + 1)
    await store.close()
    let reopened = try LocalSyncV2Store(root: root, policy: .openExisting)
    try await reopened.validateCheckpointBase(workID: work, scope: .parked)
    #expect(await reopened.checkpointFullValidationCount == 1)
    await reopened.close()
}

@Test
func checkpointCacheRejectsDifferentWorkAndGeneration() async throws {
    let root = temporaryStoreRoot("checkpoint-cache-identity")
    defer { try? FileManager.default.removeItem(at: root) }
    let store = try LocalSyncV2Store(root: root, policy: .createNew)
    let first = WorkID(UUID())
    let other = WorkID(UUID())
    let document = makeDocument(title: "one")
    _ = try await store.checkpoint(V2CheckpointRequest(workID: first,
                                                       document: document,
                                                       documentCreatedAt: testDate,
                                                       expectedGeneration: 0),
                                   scope: .unbound)
    _ = try await store.checkpoint(V2CheckpointRequest(workID: other,
                                                       document: makeDocument(title: "two"),
                                                       documentCreatedAt: testDate,
                                                       expectedGeneration: 0),
                                   scope: .unbound)
    let count = await store.checkpointFullValidationCount
    try await store.validateCheckpointBase(workID: first, scope: .unbound)
    #expect(await store.checkpointFullValidationCount == count + 1)
    _ = try await store.checkpoint(V2CheckpointRequest(workID: first,
                                                       document: document,
                                                       documentCreatedAt: testDate,
                                                       expectedGeneration: 1),
                                   scope: .unbound)
    let databaseURL = await store.databaseURL
    let generationSQL = "UPDATE works SET local_generation=local_generation+1 WHERE work_id='\(first)'"
    #expect(try sqliteExecutionSucceeded(databaseURL: databaseURL, sql: generationSQL))
    let before = await store.checkpointFullValidationCount
    try await store.validateCheckpointBase(workID: first, scope: .unbound)
    #expect(await store.checkpointFullValidationCount == before + 1)
    await #expect(throws: SyncV2StoreError.generationMismatch) {
        try await store.checkpoint(V2CheckpointRequest(workID: first,
                                                       document: document,
                                                       documentCreatedAt: testDate,
                                                       expectedGeneration: 1),
                                   scope: .unbound)
    }
    await store.close()
}

@Test(arguments: ["object", "manifest", "resource"])
func checkpointCacheDoesNotHideCorruptionAfterExternalWrite(kind: String) async throws {
    let root = temporaryStoreRoot("checkpoint-cache-corruption")
    defer { try? FileManager.default.removeItem(at: root) }
    let store = try LocalSyncV2Store(root: root, policy: .createNew)
    let work = WorkID(UUID())
    let resources = [PortableResource(pathComponents: ["opaque.bin"], kind: .regularFile, bytes: Data([1]))]
    _ = try await store.checkpoint(V2CheckpointRequest(workID: work,
                                                       document: makeDocument(title: "safe"),
                                                       documentCreatedAt: testDate,
                                                       expectedGeneration: 0,
                                                       resources: resources), scope: .unbound)
    let sql = switch kind {
    case "object": "DROP TRIGGER objects_immutable_update; UPDATE objects SET bytes=x'00',byte_count=1"
    case "manifest": "DROP TRIGGER snapshots_immutable_update; UPDATE snapshots SET manifest_bytes=x'00'"
    default: "UPDATE resources SET bytes=x'00'"
    }
    let databaseURL = await store.databaseURL
    #expect(try sqliteExecutionSucceeded(databaseURL: databaseURL, sql: sql))
    await #expect(throws: (any Error).self) { try await store.validateCheckpointBase(workID: work, scope: .unbound) }
    #expect(await store.checkpointFullValidationCount > 0)
    await #expect(throws: (any Error).self) { try await store.open(workID: work, scope: .unbound) }
    await store.close()
}

@Test
func checkpointCacheInvalidatedByRemoteAdoptionImportAndRestore() async throws {
    let root = temporaryStoreRoot("checkpoint-cache-install")
    defer { try? FileManager.default.removeItem(at: root) }
    let store = try LocalSyncV2Store(root: root, policy: .createNew)
    let work = WorkID(UUID())
    var document = makeDocument(title: "local")
    try await store.installCacheTestRoot(work: work, document: document)
    let first = try await store.checkpoint(V2CheckpointRequest(workID: work,
                                                               document: document,
                                                               documentCreatedAt: testDate,
                                                               expectedGeneration: 1),
                                           scope: scopeA)
    document.title = "remote"
    let encoded = try encodeSnapshot(workID: work, document: document, parents: [first.snapshotID])
    let remote = try V2RemoteSnapshot(workID: work,
                                      encoded: encoded,
                                      expectedCurrentSnapshotID: first.snapshotID,
                                      expectedLocalGeneration: first.generation,
                                      expectedRemoteHead: V2RemoteHead(snapshotID: encoded.snapshotId, generation: 2))
    try await store.stageRemote(remote, scope: scopeA)
    try await store.verifyInbox(inboxID: remote.inboxID, scope: scopeA)
    try await store.adoptInbox(inboxID: remote.inboxID, scope: scopeA)
    let before = await store.checkpointFullValidationCount
    try await store.validateCheckpointBase(workID: work, scope: scopeA)
    #expect(await store.checkpointFullValidationCount == before + 1)
    let summary = try await store.workSummary(workID: work, scope: scopeA)
    _ = try await store.checkpoint(V2CheckpointRequest(workID: work,
                                                       document: document,
                                                       documentCreatedAt: testDate,
                                                       expectedGeneration: summary.localGeneration), scope: scopeA)
    _ = try await store.prepareRestore(V2RestorePreparationRequest(workID: work,
                                                                   selectedSnapshotID: first.snapshotID,
                                                                   expectedLocalGeneration: summary.localGeneration),
                                       scope: scopeA)
    let beforeRestoreCheck = await store.checkpointFullValidationCount
    try await store.validateCheckpointBase(workID: work, scope: scopeA)
    #expect(await store.checkpointFullValidationCount == beforeRestoreCheck + 1)
    let imported = WorkID(UUID())
    _ = try await store.checkpoint(V2CheckpointRequest(workID: imported,
                                                       document: makeDocument(title: "import"),
                                                       documentCreatedAt: testDate,
                                                       expectedGeneration: 0,
                                                       reason: .migration), scope: .unbound)
    let beforeImportCheck = await store.checkpointFullValidationCount
    try await store.validateCheckpointBase(workID: imported, scope: .unbound)
    #expect(await store.checkpointFullValidationCount == beforeImportCheck + 1)
    await store.close()
}

private extension LocalSyncV2Store {
    func installCacheTestRoot(work: WorkID, document: NovelDocument) throws {
        let initial = try encodeSnapshot(workID: work, document: document)
        let initialRemote = try V2RemoteSnapshot(workID: work,
                                                 encoded: initial,
                                                 expectedCurrentSnapshotID: nil,
                                                 expectedLocalGeneration: 0,
                                                 expectedRemoteHead: V2RemoteHead(snapshotID: initial.snapshotId,
                                                                                  generation: 1))
        try stageRemote(initialRemote, scope: scopeA)
        try verifyInbox(inboxID: initialRemote.inboxID, scope: scopeA)
        try adoptInbox(inboxID: initialRemote.inboxID, scope: scopeA)
    }
}

@Test
func remoteInstallInvalidatesOtherWorkCheckpointCache() async throws {
    let root = temporaryStoreRoot("checkpoint-cache-initial-install")
    defer { try? FileManager.default.removeItem(at: root) }
    let store = try LocalSyncV2Store(root: root, policy: .createNew)
    let local = WorkID(UUID())
    _ = try await store.checkpoint(V2CheckpointRequest(workID: local, document: makeDocument(title: "local"),
                                                       documentCreatedAt: testDate, expectedGeneration: 0),
                                   scope: scopeA)
    let remoteWork = WorkID(UUID())
    let encoded = try encodeSnapshot(workID: remoteWork, document: makeDocument(title: "remote"))
    let graph = try V2RemoteSnapshotGraph(workID: remoteWork, headSnapshotID: encoded.snapshotId, snapshots: [encoded],
                                          expectedCurrentSnapshotID: nil, expectedLocalGeneration: 0,
                                          expectedRemoteHead: V2RemoteHead(snapshotID: encoded.snapshotId,
                                                                           generation: 1))
    try await store.installInitialGraph(graph, scope: scopeA)
    let count = await store.checkpointFullValidationCount
    try await store.validateCheckpointBase(workID: local, scope: scopeA)
    #expect(await store.checkpointFullValidationCount == count + 1)
    await store.close()
}

@Test(arguments: [false, true])
func cachedCheckpointRechecksExternalChangesUnderCommitLock(changed: Bool) async throws {
    let root = temporaryStoreRoot("checkpoint-cache-cas-validation")
    defer { try? FileManager.default.removeItem(at: root) }
    let store = try LocalSyncV2Store(root: root, policy: .createNew)
    let work = WorkID(UUID())
    var document = makeDocument(title: "safe")
    let first = try await store.checkpoint(V2CheckpointRequest(workID: work, document: document,
                                                               documentCreatedAt: testDate, expectedGeneration: 0),
                                           scope: .unbound)
    if changed {
        document.title += "edit"
    }
    await store.corruptObjectAfterEncoding()
    await #expect(throws: SyncV2StoreError.generationMismatch) {
        try await store.checkpoint(V2CheckpointRequest(workID: work, document: document,
                                                       documentCreatedAt: testDate,
                                                       expectedGeneration: first.generation), scope: .unbound)
    }
    #expect(try await store.workSummary(workID: work, scope: .unbound).currentSnapshotID == first.snapshotID)
    #expect(try await store.historyCount(workID: work, scope: .unbound) == 1)
    await #expect(throws: (any Error).self) { try await store.open(workID: work, scope: .unbound) }
    await store.close()
}

@Test(arguments: [false, true])
func corruptRemoteInputRejectedWithWarmCheckpointCache(manifest: Bool) async throws {
    let root = temporaryStoreRoot("checkpoint-cache-invalid-incoming")
    defer { try? FileManager.default.removeItem(at: root) }
    let store = try LocalSyncV2Store(root: root, policy: .createNew)
    let work = WorkID(UUID())
    let document = makeDocument(title: "local")
    let first = try await store.checkpoint(V2CheckpointRequest(workID: work, document: document,
                                                               documentCreatedAt: testDate, expectedGeneration: 0),
                                           scope: scopeA)
    let encoded = try encodeSnapshot(workID: work, document: document, parents: [first.snapshotID])
    var objects = encoded.objects
    try objects[#require(objects.keys.first)] = Data([0])
    let corrupt = EncodedSnapshot(manifest: encoded.manifest,
                                  manifestBytes: manifest ? Data([0]) : encoded.manifestBytes,
                                  objects: manifest ? encoded.objects : objects)
    await #expect(throws: (any Error).self) {
        let remote = try V2RemoteSnapshot(workID: work, encoded: corrupt, expectedCurrentSnapshotID: first.snapshotID,
                                          expectedLocalGeneration: first.generation,
                                          expectedRemoteHead: V2RemoteHead(snapshotID: corrupt.snapshotId,
                                                                           generation: 2))
        try await store.stageRemote(remote, scope: scopeA)
    }
    #expect(try await store.open(workID: work, scope: scopeA).document == document)
    await store.close()
}

private extension LocalSyncV2Store {
    func corruptObjectAfterEncoding() {
        let url = databaseURL
        checkpointTimingObserver = { phase, _ in
            if phase == "encode" {
                let sql = "DROP TRIGGER objects_immutable_update; "
                    + "UPDATE objects SET bytes=x'00',byte_count=1"
                _ = try? sqliteExecutionSucceeded(databaseURL: url, sql: sql)
            }
        }
    }
}

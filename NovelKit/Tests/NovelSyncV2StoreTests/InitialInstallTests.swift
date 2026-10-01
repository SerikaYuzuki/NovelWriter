import Foundation
import NovelSyncV2
@testable import NovelSyncV2Store
import Testing

private func initialGraph() throws -> V2RemoteSnapshotGraph {
    let workID = WorkID(UUID())
    let snapshot = try encodeSnapshot(workID: workID, document: makeDocument(title: "synthetic"))
    return try V2RemoteSnapshotGraph(workID: workID, headSnapshotID: snapshot.snapshotId,
                                     snapshots: [snapshot], expectedCurrentSnapshotID: nil, expectedLocalGeneration: 0,
                                     expectedRemoteHead: V2RemoteHead(snapshotID: snapshot.snapshotId, generation: 1))
}

@Test func initialInstallRollsBackEveryRowOnWriteFailure() async throws {
    let root = temporaryStoreRoot("initial-rollback")
    defer { try? FileManager.default.removeItem(at: root) }
    let store = try LocalSyncV2Store(root: root, policy: .createNew)
    let graph = try initialGraph()
    // Fail after objects/snapshots have been inserted, before current is installed.
    try await store.exec("CREATE TEMP TRIGGER fail_install BEFORE UPDATE OF current_snapshot_id ON works BEGIN SELECT RAISE(ABORT,'injected'); END")
    await #expect(throws: (any Error).self) { try await store.installInitialGraph(graph, scope: scopeA) }
    for table in ["works", "objects", "snapshots", "history_occurrences", "inbox_batches"] {
        #expect(try await store.query("SELECT COUNT(*) FROM \(table)").first?[0].int64 == 0)
    }
    try await store.exec("DROP TRIGGER fail_install")
    try await store.installInitialGraph(graph, scope: scopeA)
    #expect(try await store.open(workID: graph.workID, scope: scopeA).document?.title == "synthetic")
    await #expect(throws: SyncV2StoreError.staleCAS) { try await store.installInitialGraph(graph, scope: scopeA) }
    await store.close()
}

@Test(arguments: ["1", "old-validator"])
func persistedInboxStillRejectsCorruption(version: String) async throws {
    let root = temporaryStoreRoot("inbox-corruption")
    defer { try? FileManager.default.removeItem(at: root) }
    let store = try LocalSyncV2Store(root: root, policy: .createNew)
    let graph = try initialGraph()
    try await store.stageRemoteGraph(graph, scope: scopeA)
    try await store.exec("UPDATE schema_meta SET value=? WHERE key=?",
                         [.text(version), .text("inbox-validator/" + graph.inboxID.uuidString.lowercased())])
    await store.close()
    let reopened = try LocalSyncV2Store(root: root, policy: .openExisting)
    try await reopened.verifyInbox(inboxID: graph.inboxID, scope: scopeA)
    try await reopened.exec("UPDATE inbox_objects SET bytes=zeroblob(byte_count)")
    await #expect(throws: SyncV2StoreError.invalidSnapshot) {
        try await reopened.adoptInbox(inboxID: graph.inboxID, scope: scopeA)
    }
    #expect(try await reopened.open(workID: graph.workID, scope: scopeA).document == nil)
    await reopened.close()
}

@Test func initialInstallRejectsCorruptPreexistingCASBytes() async throws {
    let root = temporaryStoreRoot("initial-corrupt-cas")
    defer { try? FileManager.default.removeItem(at: root) }
    let store = try LocalSyncV2Store(root: root, policy: .createNew)
    let first = try initialGraph()
    try await store.installInitialGraph(first, scope: scopeA)
    let title = try #require(first.snapshots[0].manifest.entries.first { $0.entityKey == "work/title" })
    // Simulate on-disk corruption beyond the immutable-row trigger, in this disposable fixture only.
    try await store.exec("DROP TRIGGER objects_immutable_update")
    try await store.exec("UPDATE objects SET bytes=zeroblob(byte_count) WHERE object_id=?", [.blob(title.objectId.bytes)])
    let second = try initialGraph()
    await #expect(throws: SyncV2StoreError.invalidSnapshot) {
        try await store.installInitialGraph(second, scope: scopeA)
    }
    #expect(try await store.listWorks(scope: scopeA).count == 1)
    await store.close()
}

@Test func existingSnapshotInsertionDoesNotRepairMissingEvidence() async throws {
    let root = temporaryStoreRoot("existing-row-attestation")
    defer { try? FileManager.default.removeItem(at: root) }
    let store = try LocalSyncV2Store(root: root, policy: .createNew)
    let graph = try initialGraph()
    try await store.installInitialGraph(graph, scope: scopeA)
    try await store.exec("DROP TRIGGER snapshot_entries_immutable_delete")
    try await store.exec("DELETE FROM snapshot_entries WHERE entity_key='work/title'")
    await #expect(throws: SyncV2StoreError.invalidSnapshot) {
        try await store.insertValidatedEncoded(graph.snapshots[0], workID: graph.workID)
    }
    #expect(try await store.query("SELECT COUNT(*) FROM snapshot_entries WHERE entity_key='work/title'").first?[0].int64 == 0)
    await store.close()
}

@Test func hexadecimalBytesAcceptUppercaseAndEmptyInput() {
    #expect(Data(hex: "aBcDEF0190") == Data([0xab, 0xcd, 0xef, 0x01, 0x90]))
    #expect(Data(hex: "") == Data())
}

@Test(arguments: ["a", "abc", "GG", "-1", "é", "0 "])
func hexadecimalBytesRejectMalformedInput(_ value: String) {
    #expect(Data(hex: value) == nil)
}

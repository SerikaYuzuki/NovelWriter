import Foundation
import NovelSyncV2
@testable import NovelSyncV2Store
import Testing

extension LocalSyncV2Store {
    /// Reconstruct the exact, attested schema shipped before D-107.
    func prepareLegacyCommandRecoveryFixture() throws {
        let sql = try String(decoding: SnapshotSyncV2SchemaContract.resourceSQL(), as: UTF8.self)
        let old = Data(sql.components(separatedBy: "\n-- Legacy unexpected-command recovery (D-107).")[0].utf8)
        try inTransaction {
            try exec("DROP TABLE legacy_command_recovery")
            try exec("UPDATE schema_meta SET checksum=? WHERE key='schema'", [.blob(SnapshotSyncV2SchemaContract.checksum(old))])
        }
    }
}

@Test func currentSchemaNeverSeedsNewQuarantinesOnReopen() async throws {
    let root = temporaryStoreRoot("new-quarantine")
    defer { try? FileManager.default.removeItem(at: root) }
    let store = try LocalSyncV2Store(root: root, policy: .createNew)
    let document = makeDocument(title: "local")
    let workID = WorkID(UUID())
    let checkpoint = try await store.checkpoint(V2CheckpointRequest(
        workID: workID, document: document, documentCreatedAt: testDate, expectedGeneration: 0, reason: .explicit
    ), scope: scopeA)
    let command = try createWorkCommand(workID: workID, documentID: document.id, checkpoint: checkpoint)
    try await store.seal(command, scope: scopeA)
    try await store.quarantine(commandID: command.commandId, scope: scopeA, reason: "unexpected")
    await store.close()
    for _ in 0 ..< 3 {
        let reopened = try LocalSyncV2Store(root: root, policy: .openExisting)
        #expect(try await reopened.query("SELECT COUNT(*) FROM legacy_command_recovery").first?.scalar.int64 == 0)
        try await reopened.retryUnacknowledgedCommands(scope: scopeA)
        #expect(try await reopened.allSealedCommands(scope: scopeA, workID: workID).first?.lifecycle == .quarantined)
        await reopened.close()
    }
}

import Foundation
import NovelSyncV2
@testable import NovelSyncV2Store
import Testing

@Test(arguments: ["create-work", "prepare-object", "finalize-object", "register-snapshot", "publish", "resolve-device", "resolve-server", "clone-work", "restore"], [false, true])
func upgradeRecoversEveryCommandWithoutChangingBytes(name: String, manualFirst: Bool) async throws {
    let fixtureRoot = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("docs/sync/v2/fixtures/canonical")
    let path = name == "publish" ? "publish-command.json" : "commands/\(name).json"
    var command = try SealedCommand.decodeCanonical(Data(contentsOf: fixtureRoot.appendingPathComponent(path)))
    let binding = V2AccountBinding(accountID: command.binding.accountId, accountFence: command.binding.accountFence,
                                   serverInstanceID: command.binding.serverInstanceId, protocolEpoch: command.binding.protocolEpoch)
    let scope = V2LocalWorkScope.bound(binding)
    let workID = try command.payload.workID
    let root = temporaryStoreRoot("command-upgrade")
    defer { try? FileManager.default.removeItem(at: root) }
    let store = try LocalSyncV2Store(root: root, policy: .createNew)
    let checkpoint = try await store.checkpoint(V2CheckpointRequest(
        workID: workID, document: makeDocument(title: "retained"), documentCreatedAt: testDate,
        expectedGeneration: 0, reason: .explicit
    ), scope: scope)
    var envelope = try #require(JSONSerialization.jsonObject(with: command.canonicalBytes) as? [String: Any])
    envelope["sourceSnapshotId"] = checkpoint.snapshotID.rawValue
    envelope["sourceGeneration"] = checkpoint.generation
    command = try SealedCommand.decodeCanonical(JSONSerialization.data(withJSONObject: envelope, options: [.sortedKeys, .withoutEscapingSlashes]))
    // Seed the durable state of an older app, independently of today's sealing rules.
    try await store.exec("""
    INSERT INTO sealed_commands(command_id,work_id,account_id,account_fence,server_instance_id,protocol_epoch,
      command_kind,canonical_request,request_digest,source_snapshot_id,source_generation,status)
    VALUES(?,?,?,?,?,?,?,?,?,?,?,'sealed')
    """, [.text(command.commandId.uuidString.lowercased()), .text(workID.description), .text(binding.accountID),
          .text(binding.accountFence), .text(binding.serverInstanceID), .int(binding.protocolEpoch), .text(command.commandKind),
          .blob(command.canonicalBytes), .blob(command.requestDigest.bytes), .blob(command.sourceSnapshotId.bytes), .int(command.sourceGeneration)])
    try await store.quarantine(commandID: command.commandId, scope: scope, reason: "unexpected")
    try await store.prepareLegacyCommandRecoveryFixture()
    await store.close()
    let reopened = try LocalSyncV2Store(root: root, policy: .openExisting)
    if manualFirst {
        try await reopened.requestSynchronization(workID: workID, scope: scope)
    } else {
        try await reopened.retryUnacknowledgedCommands(scope: scope)
    }
    try await reopened.retryUnacknowledgedCommands(scope: scope)
    let record = try #require(await reopened.allSealedCommands(scope: scope, workID: workID).first)
    #expect(record.lifecycle == .sealed)
    #expect(record.commandID == command.commandId)
    #expect(record.canonicalRequest == command.canonicalBytes)
    #expect(record.requestDigest == command.requestDigest)
    #expect(record.sourceGeneration == command.sourceGeneration)
    #expect(record.sourceSnapshotID == command.sourceSnapshotId)
    try await reopened.quarantine(commandID: command.commandId, scope: scope, reason: "unexpected")
    await reopened.close()
    let restarted = try LocalSyncV2Store(root: root, policy: .openExisting)
    try await restarted.retryUnacknowledgedCommands(scope: scope)
    #expect(try await restarted.allSealedCommands(scope: scope, workID: workID).first?.lifecycle == .quarantined)
    #expect(try await restarted.query("SELECT consumed FROM legacy_command_recovery").first?[0].int64 == 1)
    for _ in 0 ..< 2 {
        try await restarted.requestSynchronization(workID: workID, scope: scope)
        let manual = try #require(await restarted.allSealedCommands(scope: scope, workID: workID).first)
        #expect(manual.lifecycle == .sealed)
        #expect(manual.canonicalRequest == command.canonicalBytes)
        #expect(manual.commandID == command.commandId)
        try await restarted.quarantine(commandID: command.commandId, scope: scope, reason: "unexpected")
    }
    await restarted.close()
}

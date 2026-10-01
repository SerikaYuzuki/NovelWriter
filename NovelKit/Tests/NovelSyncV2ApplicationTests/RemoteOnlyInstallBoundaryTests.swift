import Foundation
import NovelSyncV2
import NovelSyncV2Application
@testable import NovelSyncV2Runtime
@testable import NovelSyncV2Store
import Testing

@Test("cancel or account switch between stage/verify/adopt preserves an uninstalled, recoverable work",
      arguments: [2, 3], [false, true])
func remoteOnlyInstallChecksEveryBoundary(boundary: Int, changeAccount: Bool) async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("import-boundary-\(UUID())")
    defer { try? FileManager.default.removeItem(at: root) }
    let store = try LocalSyncV2Store(root: root, policy: .createNew)
    let binding = V2AccountBinding(accountID: "account", accountFence: "fence", serverInstanceID: "test-server")
    let scope = ImportBoundaryScope(binding: binding, pauseAt: boundary)
    let kernel = ProductionSyncV2Kernel(store: store, scope: scope)
    let workID = WorkID(UUID())
    let snapshot = try SnapshotCodec.encode(SnapshotModel(workId: workID,
                                                          document: applicationTestDocument(title: "境界前の原稿"),
                                                          documentCreatedAt: applicationTestCreatedAt))
    let inbox = try SyncV2RemoteInbox(inboxID: UUID(), workID: workID, headSnapshotID: snapshot.snapshotId,
                                      snapshots: [snapshot], expectedCurrentSnapshotID: nil, expectedLocalGeneration: 0,
                                      expectedRemoteHead: SyncV2RemoteHead(snapshotID: snapshot.snapshotId, generation: 1),
                                      binding: SealedCommand.Binding(accountFence: binding.accountFence,
                                                                     accountId: binding.accountID, protocolEpoch: 2,
                                                                     serverInstanceId: binding.serverInstanceID))
    let task = Task { try await kernel.installRemoteOnly(inbox) }
    try await eventually { await scope.paused }
    #expect(try await store.inboxState(inboxID: inbox.inboxID, binding: binding) == (boundary == 2 ? "staged" : "verified"))
    if changeAccount {
        await scope.release(binding: V2AccountBinding(accountID: "other", accountFence: "other", serverInstanceID: "test-server"))
        await #expect(throws: SyncV2Failure.accountFenceChanged) { try await task.value }
    } else {
        task.cancel()
        await scope.release(binding: binding)
        await #expect(throws: CancellationError.self) { try await task.value }
    }
    let uninstalled = try await store.open(workID: workID, scope: .bound(binding))
    #expect(uninstalled.summary.localGeneration == 0)
    #expect(uninstalled.summary.currentSnapshotID == nil)
    await scope.release(binding: binding)
    let recovered = try await kernel.installRemoteOnly(inbox)
    #expect(recovered.document?.title == "境界前の原稿")
    #expect(recovered.generation == 1)
    await store.close()
}

private actor ImportBoundaryScope: SyncV2ScopeResolver {
    var binding: V2AccountBinding
    let pauseAt: Int
    var calls = 0
    var paused = false
    var continuation: CheckedContinuation<Void, Never>?

    init(binding: V2AccountBinding, pauseAt: Int) {
        self.binding = binding
        self.pauseAt = pauseAt
    }

    func activeBinding() async throws -> V2AccountBinding? {
        calls += 1
        if calls == pauseAt {
            paused = true
            await withCheckedContinuation { continuation = $0 }
        }
        return binding
    }

    func existingScope(workID _: WorkID) -> V2LocalWorkScope {
        .bound(binding)
    }

    func scopeForCheckpoint(workID _: WorkID) -> V2LocalWorkScope {
        .bound(binding)
    }

    func release(binding: V2AccountBinding) {
        self.binding = binding
        continuation?.resume()
        continuation = nil
    }
}

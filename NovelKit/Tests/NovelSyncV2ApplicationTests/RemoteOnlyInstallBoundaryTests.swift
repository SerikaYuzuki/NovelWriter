import Foundation
import NovelSyncV2
import NovelSyncV2Application
@testable import NovelSyncV2Runtime
@testable import NovelSyncV2Store
import Testing

@Test("cancel or account switch around atomic install never presents a stale result or leaves a partial work",
      arguments: [1, 2, 3], [false, true])
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
    let progress = ImportProgress()
    let task = Task {
        try await ImportProgress.$current.withValue(progress) { try await kernel.installRemoteOnly(inbox) }
    }
    try await eventually { await scope.paused }
    #expect(progress.value.stage == (boundary == 1 ? .checking : .saving))
    #expect(try await store.query("SELECT COUNT(*) FROM inbox_batches").first?.scalar.int64 == 0)

    if changeAccount {
        await scope.release(binding: V2AccountBinding(accountID: "other", accountFence: "other", serverInstanceID: "test-server"))
        await #expect(throws: SyncV2Failure.accountFenceChanged) { try await task.value }
    } else {
        task.cancel()
        await scope.release(binding: binding)
        await #expect(throws: CancellationError.self) { try await task.value }
    }
    await scope.release(binding: binding)
    if boundary < 3 {
        #expect(try await store.listWorks(scope: .bound(binding)).isEmpty)
        let recovered = try await kernel.installRemoteOnly(inbox)
        #expect(recovered.document?.title == "境界前の原稿")
        #expect(recovered.generation == 1)
    } else {
        // COMMIT won the race; presentation is rejected but the complete work
        // remains durably scoped to the original account, never half-installed.
        let installed = try await store.open(workID: workID, scope: .bound(binding))
        #expect(installed.summary.localGeneration == 1)
        #expect(installed.document?.title == "境界前の原稿")
    }
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

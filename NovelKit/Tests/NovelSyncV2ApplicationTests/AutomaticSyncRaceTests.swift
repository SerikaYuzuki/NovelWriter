import Foundation
import NovelCore
import NovelSyncV2
@testable import NovelSyncV2Application
import NovelSyncV2Runtime
import NovelSyncV2Store
import Testing

@Suite("Automatic sync boundaries")
struct AutomaticSyncRaceTests {
    enum Interruption: CaseIterable, Sendable { case cancellation, edit, account }

    @Test("a late head response cannot queue against a changed boundary", arguments: Interruption.allCases)
    func lateHead(interruption: Interruption) async throws {
        let configuration = try TestRuntimeConfiguration()
        let store = try LocalSyncV2Store(root: configuration.localRoot.url, policy: .createNew)
        let workID = WorkID(UUID())
        let document = applicationTestDocument(title: "local")
        let local = try SnapshotCodec.encode(SnapshotModel(
            workId: workID, document: document, documentCreatedAt: applicationTestCreatedAt
        ), parents: [])
        let seed = try V2RemoteSnapshot(
            workID: workID, encoded: local, expectedCurrentSnapshotID: nil, expectedLocalGeneration: 0,
            expectedRemoteHead: V2RemoteHead(snapshotID: local.snapshotId, generation: 1)
        )
        try await store.stageRemote(seed, scope: productionScope)
        try await store.verifyInbox(inboxID: seed.inboxID, scope: productionScope)
        try await store.adoptInbox(inboxID: seed.inboxID, scope: productionScope)
        let application = try await SnapshotSyncV2Runtime.makeApplication(mode: .test(configuration))
        _ = try await application.openLocal(workID: workID)
        try await eventually { await application.workerTasks[workID] == nil }
        let barrier = AutomaticHeadBarrier()
        await configuration.remote.setHeadHandler { _ in
            await barrier.wait()
            return try SyncV2RemoteHead(snapshotID: SnapshotID(data: Data("remote".utf8)), generation: 2)
        }
        let check = Task { try await application.checkForRemoteUpdates(workID: workID) }
        try await eventually { await configuration.remote.recordedHeadReads().count == 1 }
        // Concurrent views do not start a second read for this work.
        #expect(try await !application.checkForRemoteUpdates(workID: workID))
        #expect(await configuration.remote.recordedHeadReads().count == 1)
        switch interruption {
        case .cancellation:
            check.cancel()
        case .edit:
            var changed = document
            changed.title = "newer local edit"
            _ = try await store.checkpoint(V2CheckpointRequest(
                workID: workID, document: changed, documentCreatedAt: applicationTestCreatedAt,
                expectedGeneration: 1, reason: .explicit
            ), scope: productionScope)
        case .account:
            try await application.parkAccountScope(workID: workID, binding: SyncV2AccountScopeBinding(
                accountID: productionBinding.accountID, accountFence: productionBinding.accountFence,
                serverInstanceID: productionBinding.serverInstanceID
            ))
        }
        await barrier.release()
        do {
            #expect(try await check.value == false)
        } catch is CancellationError {
            #expect(interruption == .cancellation)
        }
        #expect(await configuration.remote.recordedOperations().isEmpty)
        if interruption == .edit {
            let pending = try await store.pendingIntents(scope: productionScope, workID: workID)
            #expect(pending.count == 1)
            #expect(pending.first?.sourceGeneration == 2)
        } else {
            #expect(try await store.pendingIntents(scope: productionScope, workID: workID).isEmpty)
        }
        await store.close()
    }
}

private actor AutomaticHeadBarrier {
    private var released = false
    private var continuation: CheckedContinuation<Void, Never>?
    func wait() async {
        guard !released else { return }
        await withCheckedContinuation { continuation = $0 }
    }

    func release() {
        released = true
        continuation?.resume()
        continuation = nil
    }
}

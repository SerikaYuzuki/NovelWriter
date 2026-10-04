import Foundation
@testable import FUMINIWA
import NovelCore
import NovelSyncV2
import NovelSyncV2Application
import NovelSyncV2Runtime
import NovelSyncV2Store
import Testing

@MainActor
struct SnapshotSyncV2LeafLifecycleTests {
    @Test("a clean revision still promotes the last autosave at termination")
    func terminationPromotesCleanLeaf() async throws {
        let configuration = try TestRuntimeConfiguration(account: nil)
        let state = AppState(dependencies: AppDependencies(
            userDefaults: makeIsolatedTestUserDefaults(),
            snapshotSyncV2Factory: { try await SnapshotSyncV2Runtime.makeApplication(mode: .test(configuration)) }
        ), initialStartupState: .ready)
        #expect(await state.configureSnapshotSyncV2(using: state.snapshotSyncV2Factory))
        let document = NovelDocument.newDocument(title: "durable autosave")
        let workID = WorkID(UUID())
        let createdAt = Date(timeIntervalSince1970: 1_700_000_000)
        #expect(state.installV2Document(document, workID: workID, createdAt: createdAt))
        #expect(await state.checkpointSnapshotSyncV2(document, reason: .autosave))
        let local = try LocalSyncV2Store(root: configuration.localRoot.url, policy: .openExisting)
        #expect(try await local.hasUnpromotedLeaf(workID: workID, scope: .unbound))
        #expect(try await local.pendingIntents(scope: .unbound).isEmpty)
        #expect(await state.saveBeforeTermination())
        #expect(try await !local.hasUnpromotedLeaf(workID: workID, scope: .unbound))
        #expect(try await local.pendingIntents(scope: .unbound).count == 1)
        #expect(state.workspaceModel.document == document)
        #expect(await configuration.remote.recordedOperations().isEmpty)
        await local.close()
    }
}

import Foundation
import NovelCore
import NovelSyncV2
import NovelSyncV2Application
@testable import NovelSyncV2Runtime
@testable import NovelSyncV2Store
import Testing

@Test
func checkpointScopeAccountAndWorkSwitchInvalidateEvenUnboundWork() async throws {
    let config = try TestRuntimeConfiguration()
    defer { try? FileManager.default.removeItem(at: config.localRoot.url) }
    let store = try LocalSyncV2Store(root: config.localRoot.url, policy: .createNew)
    let resolver = TestScopeResolver(vault: config.vault, store: store)
    let work = WorkID(UUID())
    let document = NovelDocument.newDocument()
    let date = Date(timeIntervalSince1970: 1_700_000_000)
    let request = V2CheckpointRequest(workID: work, document: document, documentCreatedAt: date, expectedGeneration: 0)
    let first = try await store.checkpoint(request, scope: .unbound)
    #expect(try await resolver.scopeForCheckpoint(workID: work) == .unbound)
    _ = try await store.checkpoint(V2CheckpointRequest(
        workID: work,
        document: document,
        documentCreatedAt: date,
        expectedGeneration: first.generation
    ), scope: .unbound)
    let warmed = await store.checkpointFullValidationCount
    #expect(try await resolver.scopeForCheckpoint(workID: work) == .unbound)
    #expect(await store.checkpointFullValidationCount == warmed)
    await config.vault.replaceAccount(TestAccount(accountID: "second", accountFence: "second-fence"))
    #expect(try await resolver.scopeForCheckpoint(workID: work) == .unbound)
    #expect(await store.checkpointFullValidationCount == warmed + 1)
    _ = try await store.checkpoint(V2CheckpointRequest(
        workID: work,
        document: document,
        documentCreatedAt: date,
        expectedGeneration: first.generation
    ), scope: .unbound)
    let other = WorkID(UUID())
    _ = try await store.checkpoint(V2CheckpointRequest(
        workID: other,
        document: NovelDocument.newDocument(),
        documentCreatedAt: date,
        expectedGeneration: 0
    ), scope: .unbound)
    let beforeOther = await store.checkpointFullValidationCount
    _ = try await resolver.scopeForCheckpoint(workID: other)
    #expect(await store.checkpointFullValidationCount == beforeOther + 1)
    let beforeReturn = await store.checkpointFullValidationCount
    _ = try await resolver.scopeForCheckpoint(workID: work)
    #expect(await store.checkpointFullValidationCount == beforeReturn + 1)
    await store.close()
}

@Test
func checkpointScopeKeepsValidationFromOpeningWork() async throws {
    let config = try TestRuntimeConfiguration()
    defer { try? FileManager.default.removeItem(at: config.localRoot.url) }
    let store = try LocalSyncV2Store(root: config.localRoot.url, policy: .createNew)
    let resolver = TestScopeResolver(vault: config.vault, store: store)
    let work = WorkID(UUID()), document = NovelDocument.newDocument()
    _ = try await store.checkpoint(V2CheckpointRequest(workID: work, document: document,
                                                       documentCreatedAt: applicationTestCreatedAt,
                                                       expectedGeneration: 0), scope: productionScope)
    let kernel = ProductionSyncV2Kernel(store: store, scope: resolver)
    let before = await store.checkpointFullValidationCount
    _ = try await kernel.open(workID: work)
    #expect(await store.checkpointFullValidationCount == before + 1)
    _ = try await resolver.scopeForCheckpoint(workID: work)
    #expect(await store.checkpointFullValidationCount == before + 1)
    await store.close()
}

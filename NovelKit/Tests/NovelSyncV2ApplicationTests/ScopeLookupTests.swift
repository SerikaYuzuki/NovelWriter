import Foundation
import NovelAuth
import NovelSyncV2
@testable import NovelSyncV2Runtime
@testable import NovelSyncV2Store
import Testing

@Test
func commandScopeLookupDoesNotOpenManuscriptButCheckpointStillValidatesIt() async throws {
    let store = MembershipOnlyStore()
    let resolver = ProductionScopeResolver(vault: InMemoryAuthSessionVault(), store: store)
    let workID = WorkID(UUID())
    #expect(try await resolver.existingScope(workID: workID) == .unbound)
    #expect(await store.openCount == 0)
    await #expect(throws: SyncV2StoreError.invalidSnapshot) {
        try await resolver.scopeForCheckpoint(workID: workID)
    }
    #expect(await store.openCount == 1)
}

private actor MembershipOnlyStore: ProductionScopeStore {
    var openCount = 0

    func workSummary(workID: WorkID, scope _: V2LocalWorkScope) throws -> V2WorkSummary {
        V2WorkSummary(
            workID: workID, documentID: DocumentID(UUID()), localGeneration: 1,
            currentSnapshotID: nil, acknowledgedHeadGeneration: nil, syncLane: .normal
        )
    }

    func open(workID _: WorkID, scope _: V2LocalWorkScope) throws -> V2OpenResult {
        openCount += 1
        throw SyncV2StoreError.invalidSnapshot
    }
}

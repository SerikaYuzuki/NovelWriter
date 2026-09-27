import Foundation
import NovelCore
import NovelSyncV2
import NovelSyncV2Store
import Testing

@Test
func localHistoryPageIsNewestFirstStableAndScoped() async throws {
    let root = temporaryStoreRoot("history-page")
    defer { try? FileManager.default.removeItem(at: root) }
    let workID = WorkID(UUID())
    let store = try LocalSyncV2Store(root: root, policy: .createNew)
    let documentID = UUID()

    let first = try await store.checkpoint(
        V2CheckpointRequest(
            workID: workID,
            document: makeDocument(title: "first", id: documentID),
            documentCreatedAt: testDate,
            expectedGeneration: 0,
            reason: .explicit
        ),
        scope: scopeA
    )
    let second = try await store.checkpoint(
        V2CheckpointRequest(
            workID: workID,
            document: makeDocument(title: "second", id: documentID),
            documentCreatedAt: testDate,
            expectedGeneration: first.generation,
            reason: .navigation
        ),
        scope: scopeA
    )

    let page = try await store.historyPage(
        workID: workID,
        scope: scopeA,
        pageSize: 1
    )
    #expect(page.items.count == 1)
    #expect(page.items[0].snapshotID == second.snapshotID)
    #expect(page.items[0].occurrenceID != UUID())
    #expect(page.items[0].localGeneration == second.generation)
    #expect(page.items[0].createdAt.timeIntervalSince1970 > 0)

    let repeated = try await store.historyPage(
        workID: workID,
        scope: scopeA,
        pageSize: 1
    )
    #expect(repeated.items == page.items)
    let tail = try #require(page.nextCursor)
    let next = try await store.historyPage(
        workID: workID,
        scope: scopeA,
        cursor: tail,
        pageSize: 1
    )
    #expect(next.items.map(\.snapshotID) == [first.snapshotID])

    let foreign = V2LocalWorkScope.bound(
        V2AccountBinding(
            accountID: "other-account",
            accountFence: "other-fence",
            serverInstanceID: "server-a"
        )
    )
    await #expect(throws: SyncV2StoreError.workNotFound) {
        try await store.historyPage(workID: workID, scope: foreign, pageSize: 10)
    }
}

@Test
func historyCursorCannotResumeAcrossFenceTransition() async throws {
    let root = temporaryStoreRoot("history-fence-cursor")
    defer { try? FileManager.default.removeItem(at: root) }
    let workID = WorkID(UUID())
    let store = try LocalSyncV2Store(root: root, policy: .createNew)
    var document = makeDocument(title: "one")
    let first = try await store.checkpoint(
        V2CheckpointRequest(
            workID: workID,
            document: document,
            documentCreatedAt: testDate,
            expectedGeneration: 0
        ),
        scope: scopeA
    )
    document.title = "two"
    _ = try await store.checkpoint(
        V2CheckpointRequest(
            workID: workID,
            document: document,
            documentCreatedAt: testDate,
            expectedGeneration: first.generation
        ),
        scope: scopeA
    )
    let page = try await store.historyPage(workID: workID, scope: scopeA, pageSize: 1)
    let cursor = try #require(page.nextCursor)
    let rotated = V2AccountBinding(
        accountID: bindingA.accountID,
        accountFence: "history-rotated",
        serverInstanceID: bindingA.serverInstanceID
    )
    try await store.transitionAccountScopes(from: bindingA, to: rotated)
    await #expect(throws: SyncV2StoreError.invalidHistoryCursor) {
        try await store.historyPage(
            workID: workID,
            scope: .bound(rotated),
            cursor: cursor,
            pageSize: 1
        )
    }
}

@Test
func localHistoryRejectsInvalidCreatedAt() async throws {
    let root = temporaryStoreRoot("history-invalid-date")
    defer { try? FileManager.default.removeItem(at: root) }
    let workID = WorkID(UUID())
    let store = try LocalSyncV2Store(root: root, policy: .createNew)
    _ = try await store.checkpoint(
        V2CheckpointRequest(
            workID: workID,
            document: makeDocument(title: "invalid date"),
            documentCreatedAt: testDate,
            expectedGeneration: 0
        ),
        scope: scopeA
    )
    let databaseURL = await store.databaseURL
    #expect(
        try sqliteExecutionSucceeded(
            databaseURL: databaseURL,
            sql: "UPDATE history_occurrences SET created_at='not-a-date'"
        )
    )
    await #expect(throws: SyncV2StoreError.invalidHistoryDate) {
        try await store.historyPage(workID: workID, scope: scopeA, pageSize: 10)
    }
}

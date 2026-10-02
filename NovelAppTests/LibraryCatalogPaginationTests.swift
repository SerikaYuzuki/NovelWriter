import Foundation
@testable import FUMINIWA
import NovelSyncV2
import NovelSyncV2Application
import NovelSyncV2Runtime
import Testing

struct LibraryCatalogPaginationTests {
    @Test("catalog pages append on request and reset on refresh")
    @MainActor
    func catalogPagesAppendOnRequest() async throws {
        let first = WorkID(UUID())
        let second = WorkID(UUID())
        let configuration = try TestRuntimeConfiguration()
        var dependencies = AppDependencies(
            userDefaults: makeIsolatedTestUserDefaults(),
            snapshotSyncV2Factory: { try await SnapshotSyncV2Runtime.makeApplication(mode: .test(configuration)) }
        )
        dependencies.snapshotSyncV2CatalogOverride = { _, cursor, _ in
            .init(items: [.init(workID: cursor == nil ? first : second,
                                title: cursor == nil ? "最初の作品" : "次の作品", head: nil)],
                  nextCursor: cursor == nil ? "page-2" : nil)
        }
        let state = AppState(dependencies: dependencies)
        #expect(await state.configureSnapshotSyncV2(using: state.snapshotSyncV2Factory))
        await state.bootstrap()
        _ = await state.transitionFuminiwaSession(
            to: makeMacV2Session(accountID: "account-a", fence: "fence-a"),
            authState: .signedIn(accountID: "account-a")
        )
        await state.refreshSnapshotRemoteCatalog()
        #expect(state.snapshotSyncRemoteCatalogItems.map(\.workID) == [first])
        #expect(state.snapshotSyncRemoteCatalogNextCursor == "page-2")
        await state.refreshSnapshotRemoteCatalog(loadMore: true)
        #expect(Set(state.snapshotSyncRemoteCatalogItems.map(\.workID)) == [first, second])
        #expect(state.snapshotSyncRemoteCatalogNextCursor == nil)
        await state.refreshSnapshotRemoteCatalog()
        #expect(state.snapshotSyncRemoteCatalogItems.map(\.workID) == [first])
    }
}

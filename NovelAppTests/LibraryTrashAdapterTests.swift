import Foundation
@testable import FUMINIWA
import NovelSyncV2
import NovelSyncV2Application
import NovelSyncV2Runtime
import NovelWorkspace
import Testing

@MainActor
struct LibraryTrashAdapterTests {
    @Test("Macのゴミ箱操作は別作品のコピー救出と既存削除境界に接続する")
    func actions() async throws {
        let configuration = try TestRuntimeConfiguration(account: nil)
        let defaults = makeIsolatedTestUserDefaults()
        let state = AppState(dependencies: AppDependencies(userDefaults: defaults,
                                                           snapshotSyncV2Factory: { try await SnapshotSyncV2Runtime.makeApplication(mode: .test(configuration)) }))
        #expect(await state.configureSnapshotSyncV2(using: state.snapshotSyncV2Factory))
        await state.bootstrap()
        let current = state.currentSnapshotSyncV2WorkID, target = WorkID(UUID())
        var events: [String] = []
        state.libraryRefreshOperationsOverride = { original in
            var operations = original
            operations.recover = { id, _ in #expect(id == target); events.append("restore") }
            operations.rescue = { id in #expect(id == target); events.append("rescue") }
            operations.reserveDeletion = { id in #expect(id == target); events.append("reserve") }
            operations.delete = { id in #expect(id == target); events.append("delete") }
            return operations
        }
        let request = SyncV2RecoveryRequest(snapshotID: SnapshotID(data: Data("snapshot".utf8)))
        #expect(await state.restoreTrashWork(target, request: request))
        #expect(await state.rescueTrashWork(target))
        #expect(state.currentSnapshotSyncV2WorkID == current)
        #expect(await state.deleteTrashWork(target))
        #expect(events == ["restore", "rescue", "reserve", "delete"])
        #expect(state.currentSnapshotSyncV2WorkID == current)
    }

    @Test("Macの手動更新は全pageとprotectionを読み名前・ゴミ箱を反映する")
    func fullRefresh() async throws {
        let config = try TestRuntimeConfiguration()
        let state = AppState(dependencies: AppDependencies(userDefaults: makeIsolatedTestUserDefaults(),
                                                           snapshotSyncV2Factory: { try await SnapshotSyncV2Runtime.makeApplication(mode: .test(config)) }))
        #expect(await state.configureSnapshotSyncV2(using: state.snapshotSyncV2Factory))
        await state.bootstrap()
        _ = await state.transitionFuminiwaSession(to: makeMacV2Session(accountID: "account-a", fence: "fence-a"),
                                                  authState: .signedIn(accountID: "account-a"))
        let renamed = WorkID(UUID()), deleted = WorkID(UUID())
        let head = try SyncV2RemoteHead(snapshotID: SnapshotID(rawValue: String(repeating: "a", count: 64)), generation: 2)
        let local = [renamed, deleted].map { SyncV2LibraryItem(workID: $0, title: "古い名前", availability: .cached, accountState: .active,
                                                               acknowledgedHeadGeneration: 1, hasUnsentLocalChanges: false) }
        var cursors: [String?] = []
        state.libraryRefreshOperationsOverride = { original in
            var operations = original
            operations.library = { .init(items: local) }
            operations.catalog = { cursor, _ in
                cursors.append(cursor)
                return .init(items: cursor == nil ? [] : [.init(workID: renamed, title: "新しい名前", head: head)],
                             nextCursor: cursor == nil ? "next" : nil)
            }
            operations.protectedWorks = { [.init(workID: deleted, title: "削除", deletedAt: Date())] }
            return operations
        }
        await state.refreshFullLibrary()
        #expect(cursors == [nil, "next"])
        #expect(state.snapshotSyncLibraryWorks.first { $0.workID == renamed }?.title == "新しい名前")
        #expect(!state.snapshotSyncLibraryWorks.contains { $0.workID == deleted })
        #expect(state.workspaceModel.trashLocalItems.first?.workID == deleted)
        #expect(state.workspaceModel.libraryFullRefreshIsLoading == false)
    }
}

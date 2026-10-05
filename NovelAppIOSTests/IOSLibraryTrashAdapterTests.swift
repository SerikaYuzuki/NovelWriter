import Foundation
@testable import FUMINIWAIOS
import NovelAuth
import NovelSyncV2
import NovelSyncV2Application
import NovelWorkspace
import Testing

@MainActor
struct IOSLibraryTrashAdapterTests {
    @Test("iOSのゴミ箱操作は非表示作品のコピー救出と既存削除境界に接続する")
    func actions() async throws {
        let suite = "IOSLibraryTrash.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(suite)
        defer { defaults.removePersistentDomain(forName: suite); try? FileManager.default.removeItem(at: root) }
        let config = try TestRuntimeConfiguration(account: nil)
        let store = IOSDocumentStore(userDefaults: defaults, libraryRoot: root, runtimeComposition: .test(config))
        await store.bootstrap()
        #expect(await store.makeNewDocument())
        let current = store.workspaceModel.activeWorkID, target = WorkID(UUID())
        var events: [String] = []
        store.libraryRefreshOperationsOverride = { original in
            var operations = original
            operations.recover = { id, _ in #expect(id == target); events.append("restore") }
            operations.rescue = { id in #expect(id == target); events.append("rescue") }
            operations.reserveDeletion = { id in #expect(id == target); events.append("reserve") }
            operations.delete = { id in #expect(id == target); events.append("delete") }
            return operations
        }
        let request = SyncV2RecoveryRequest(snapshotID: SnapshotID(data: Data("snapshot".utf8)))
        #expect(await store.restoreTrashWork(target, request: request))
        #expect(await store.rescueTrashWork(target))
        #expect(store.workspaceModel.activeWorkID == current)
        #expect(await store.deleteTrashWork(target))
        #expect(events == ["restore", "rescue", "reserve", "delete"])
        #expect(store.workspaceModel.activeWorkID == current)
    }

    @Test("iOSの手動更新は全pageを確認し、名前とremote削除だけを棚へ反映する")
    func fullRefresh() async throws {
        let suite = "IOSLibraryTrashRefresh.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(suite)
        defer { defaults.removePersistentDomain(forName: suite); try? FileManager.default.removeItem(at: root) }
        let config = try TestRuntimeConfiguration()
        let store = IOSDocumentStore(userDefaults: defaults, libraryRoot: root, runtimeComposition: .test(config))
        await store.bootstrap()
        let now = Date()
        let session = FuminiwaSession(
            binding: .init(serverInstanceID: UUID(), syncProtocolEpoch: 2, accountID: "test-account",
                           accountAuthEpoch: 1, accountFence: "test-fence", sessionID: UUID()),
            tokens: .init(accessToken: "test-access", accessTokenExpiresAt: now.addingTimeInterval(900),
                          refreshToken: "test-refresh", refreshTokenExpiresAt: now.addingTimeInterval(86400), refreshGeneration: 1),
            receipt: .init(commandKind: "exchangeApple", operationID: UUID(), replayUntil: now.addingTimeInterval(300))
        )
        store.testServerInstanceIDOverride = "test-server"
        #expect(await store.accountTransitionCoordinator.transition(
            to: session, state: .signedIn(accountID: session.accountID), resumeRemote: false
        ))
        #expect(store.workspaceModel.authUIState == .signedIn(accountID: session.accountID))
        let renamed = WorkID(UUID()), deleted = WorkID(UUID())
        let head = try SyncV2RemoteHead(snapshotID: SnapshotID(rawValue: String(repeating: "a", count: 64)), generation: 2)
        let local = [renamed, deleted].map { SyncV2LibraryItem(workID: $0, title: "古い名前", availability: .cached,
                                                               accountState: .active, acknowledgedHeadGeneration: 1, hasUnsentLocalChanges: false) }
        var cursors: [String?] = []
        store.libraryRefreshOperationsOverride = { original in
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
        #expect(await store.refreshFullLibrary())
        #expect(cursors == [nil, "next"])
        #expect(store.workspaceModel.libraryRows.first { $0.workID == renamed }?.title == "新しい名前")
        #expect(!store.workspaceModel.libraryRows.contains { $0.workID == deleted })
        #expect(store.workspaceModel.trashLocalItems.first?.workID == deleted)
    }
}

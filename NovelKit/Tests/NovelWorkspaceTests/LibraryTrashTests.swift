import Foundation
import NovelSyncV2
import NovelSyncV2Application
import NovelWorkspace
import Testing

@MainActor
struct LibraryTrashTests {
    @Test("新しいcatalog名は受領済み世代より新しく未送信変更がないときだけ表示", arguments: [false, true])
    func renameProjection(unsent: Bool) throws {
        let workID = WorkID(UUID())
        let head = try SyncV2RemoteHead(snapshotID: SnapshotID(rawValue: String(repeating: "a", count: 64)), generation: 8)
        let local = SyncV2LibraryItem(workID: workID, title: "端末名", availability: .localOnly, accountState: .active,
                                      acknowledgedHeadGeneration: 7, hasUnsentLocalChanges: unsent)
        let rows = LibraryShelf.merge(localItems: [local], catalog: [.init(workID: workID, title: "新しい名前", head: head)],
                                      previousItems: [], pendingDeletionIDs: [], deletedIDs: [])
        #expect(rows.first?.title == (unsent ? "端末名" : "新しい名前"))
        #expect(rows.first?.hasNewerServerVersion == !unsent)
        #expect(rows.first?.acknowledgedHeadGeneration == 7)
    }

    @Test("同世代・世代不明のcatalogは端末名を上書きしない", arguments: [Int64(7), nil])
    func unchangedHead(acknowledged: Int64?) throws {
        let id = WorkID(UUID())
        let head = try SyncV2RemoteHead(snapshotID: SnapshotID(rawValue: String(repeating: "a", count: 64)), generation: 7)
        let local = SyncV2LibraryItem(workID: id, title: "端末", availability: .cached, accountState: .active,
                                      acknowledgedHeadGeneration: acknowledged, hasUnsentLocalChanges: false)
        let rows = LibraryShelf.merge(localItems: [local], catalog: [.init(workID: id, title: "サーバー", head: head)],
                                      previousItems: [], pendingDeletionIDs: [], deletedIDs: [])
        #expect(rows.first?.title == "端末")
    }

    @Test("完全なcatalogに不在かつ保護一覧の削除日時がある同一account作品だけゴミ箱へ")
    func confirmedDeletion() {
        let deleted = WorkID(UUID()), unknown = WorkID(UUID()), present = WorkID(UUID()), parked = WorkID(UUID())
        let items = [deleted, unknown, present, parked].map {
            SyncV2LibraryItem(workID: $0, title: "原稿", availability: .localOnly,
                              accountState: $0 == parked ? .parkedDifferentAccount : .active)
        }
        let protection = [deleted, present, parked].map { SyncV2ProtectedWork(workID: $0, title: "原稿", deletedAt: Date()) }
        let catalog = [SyncV2RemoteCatalogEntry(workID: present, title: "原稿", head: nil)]
        let ids = LibraryTrash.confirmedDeletedIDs(localItems: items, catalog: catalog, protection: protection)
        #expect(ids == [deleted])
        let rows = LibraryShelf.merge(localItems: items, catalog: catalog, previousItems: [], pendingDeletionIDs: [], deletedIDs: ids)
        let visibleIDs = Set(rows.map(\.workID))
        #expect(visibleIDs == [unknown, present, parked])
    }

    @Test("手動更新は全pageを読み、保護API失敗/404では削除確認しない", arguments: [false, true])
    func fullRefresh(unsupported: Bool) async throws {
        let host = FakeLibraryHost(), backend = FakeLibraryOperations(), id = WorkID(UUID())
        backend.items = [.init(workID: id, title: "端末", availability: .cached, accountState: .active)]
        var cursors: [String?] = []
        backend.onCatalog = { cursor, _ in
            cursors.append(cursor)
            return .init(items: [], nextCursor: cursor == nil ? "next" : nil)
        }
        var operations = backend.operations
        operations.protectedWorks = {
            if unsupported {
                throw SyncV2Failure.fatal(.remoteDataUnavailable)
            }
            return [.init(workID: id, title: "削除", deletedAt: Date())]
        }
        let result = try #require(try await LibraryCoordinator(operations: operations).fullRefresh(
            account: host.account, currentAccount: { host.account }, isCurrent: { true }
        ))
        #expect(cursors == [nil, "next"])
        let ids = LibraryTrash.confirmedDeletedIDs(localItems: result.refresh.projection.items, catalog: result.catalog,
                                                   protection: result.protection ?? [])
        #expect(ids == (unsupported ? [] : [id]))
        #expect((result.protection == nil) == unsupported)
    }

    @Test("端末内markerは再起動相当のread-backを保ち別account/fenceへ漏れない")
    func markerIsolation() throws {
        let suite = "LibraryTrash.\(UUID())", defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let host = FakeLibraryHost(), id = WorkID(UUID())
        LibraryTrash.writeMarker([id], defaults: defaults, account: host.account)
        #expect(LibraryTrash.readMarker(defaults: defaults, account: host.account) == [id])
        let other = WorkspaceAccountScope(accountID: "other", accountFence: "fence", serverInstanceID: "server", protocolEpoch: 1, generation: 0)
        #expect(LibraryTrash.readMarker(defaults: defaults, account: other).isEmpty)
    }
}

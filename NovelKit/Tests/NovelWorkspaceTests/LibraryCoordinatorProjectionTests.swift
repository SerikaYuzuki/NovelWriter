import Foundation
import NovelSyncV2
import NovelSyncV2Application
import NovelWorkspace
import Testing

@MainActor
struct LibraryCoordinatorProjectionTests {
    @Test("SQLiteの棚・削除IDを先に読み、catalogは独立して後からmergeする")
    func localShelfBeforeCatalog() async throws {
        let host = FakeLibraryHost(), backend = FakeLibraryOperations()
        let local = WorkID(UUID()), pending = WorkID(UUID()), deleted = WorkID(UUID())
        backend.items = [.init(workID: local, title: "端末", availability: .localOnly, accountState: .unbound)]
        backend.pending = [pending]
        backend.deleted = [deleted]
        let coordinator = LibraryCoordinator(operations: backend.operations)
        let result = try #require(try await coordinator.refresh(
            account: host.account, currentAccount: { host.account }, isCurrent: { true }
        ))
        #expect(backend.events == ["library"])
        let previous = [SyncV2LibraryItem(workID: pending, title: "削除待ち", availability: .remoteOnly, accountState: .active)]
        let rows = result.merged(catalog: [.init(workID: deleted, title: "削除済み", head: nil)], previousItems: previous)
        #expect(Set(rows.map { $0.workID }) == [local, pending])
        #expect(result.pendingDeletionIDs == [pending])
        #expect(result.deletedIDs == [deleted])
    }

    @Test("遅い棚読み込みはaccount・request世代変更で捨て、失敗は既存棚を上書きしない", arguments: [0, 1, 2])
    func refreshCompletionGuard(change: Int) async throws {
        let host = FakeLibraryHost(), backend = FakeLibraryOperations()
        let account = host.account
        var current = true
        backend.onLibrary = {
            if change == 0 {
                host.invalidateAccount()
            }
            if change == 1 {
                current = false
            }
            if change == 2 {
                throw SyncV2Failure.offline
            }
        }
        do {
            let result = try await LibraryCoordinator(operations: backend.operations).refresh(
                account: account, currentAccount: { host.account }, isCurrent: { current }
            )
            #expect(result == nil)
            #expect(change != 2)
        } catch { #expect(change == 2) }
    }

    @Test("catalogは要求ごとの1page、cursor append/reset、一意WorkIDを維持する", arguments: [false, true])
    func catalogPagination(orderByTitle: Bool) async throws {
        let host = FakeLibraryHost(), backend = FakeLibraryOperations()
        let first = WorkID(UUID()), second = WorkID(UUID())
        var cursors: [String?] = []
        backend.onCatalog = { cursor, size in
            cursors.append(cursor)
            #expect(size == 100)
            return .init(items: cursor == nil ? [.init(workID: first, title: "最初", head: nil)] : [
                .init(workID: first, title: "更新", head: nil), .init(workID: second, title: "次", head: nil)
            ], nextCursor: cursor == nil ? "page-2" : nil)
        }
        let coordinator = LibraryCoordinator(operations: backend.operations)
        let order: LibraryCoordinator.CatalogOrder = orderByTitle ? .title : .workID
        let page1 = try #require(try await coordinator.catalogPage(
            cursor: nil, existingItems: [], order: order, account: host.account,
            currentAccount: { host.account }, isCurrent: { true }
        ))
        let page2 = try #require(try await coordinator.catalogPage(
            cursor: page1.nextCursor, existingItems: page1.items, order: order, account: host.account,
            currentAccount: { host.account }, isCurrent: { true }
        ))
        #expect(Set(page2.items.map { $0.workID }) == [first, second])
        #expect(page2.items.first { $0.workID == first }?.title == "更新")
        #expect(page2.nextCursor == nil)
        let reset = try #require(try await coordinator.catalogPage(
            cursor: nil, existingItems: [], order: order, account: host.account,
            currentAccount: { host.account }, isCurrent: { true }
        ))
        #expect(reset.items.map { $0.workID } == [first])
        #expect(cursors == [nil, "page-2", nil])
    }

    @Test("catalogの遅い成功・失敗はaccount/request変更で捨てる", arguments: [false, true])
    func staleCatalog(fails: Bool) async throws {
        let host = FakeLibraryHost(), backend = FakeLibraryOperations()
        let account = host.account
        backend.onCatalog = { _, _ in
            host.invalidateAccount()
            if fails {
                throw SyncV2Failure.authenticationRequired
            }
            return .init(items: [.init(workID: WorkID(UUID()), title: "古い棚", head: nil)], nextCursor: nil)
        }
        let result = try await LibraryCoordinator(operations: backend.operations).catalogPage(
            cursor: nil, existingItems: [], order: .workID, account: account,
            currentAccount: { host.account }, isCurrent: { true }
        )
        #expect(result == nil)
    }
}

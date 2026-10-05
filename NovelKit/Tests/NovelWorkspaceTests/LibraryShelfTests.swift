import Foundation
import NovelSyncV2
import NovelSyncV2Application
import NovelWorkspace
import Testing

struct LibraryShelfTests {
    @Test("削除待ちはprojection／catalogから消えても最後の棚に保持する", arguments: [SyncV2LibraryAvailability.cached, .remoteOnly])
    func retainsPendingDeletion(availability: SyncV2LibraryAvailability) throws {
        let pending = SyncV2LibraryItem(workID: WorkID(UUID()), title: "削除待ちの作品", availability: availability,
                                        accountState: .active, remoteProgress: .offline)
        let other = SyncV2LibraryItem(workID: WorkID(UUID()), title: "古い行", availability: .cached, accountState: .active)
        let rows = LibraryShelf.merge(localItems: [], catalog: [], previousItems: [pending, other],
                                      pendingDeletionIDs: [pending.workID], deletedIDs: [])
        let retained = try #require(rows.first)
        #expect(rows.count == 1)
        #expect(retained.workID == pending.workID)
        #expect(retained.title == pending.title)
        #expect(retained.availability == availability)
        #expect(retained.remoteProgress == .offline)
    }

    @Test("削除済みIDはlocal・remote・古い削除待ち行のいずれからも再表示しない")
    func dropsDeletedRows() {
        let deleted = SyncV2LibraryItem(workID: WorkID(UUID()), title: "削除済み", availability: .localOnly, accountState: .unbound)
        let remoteID = WorkID(UUID())
        let rows = LibraryShelf.merge(
            localItems: [deleted],
            catalog: [.init(workID: deleted.workID, title: "サーバーの行", head: nil), .init(workID: remoteID, title: "未取得", head: nil)],
            previousItems: [deleted], pendingDeletionIDs: [deleted.workID], deletedIDs: [deleted.workID, remoteID]
        )
        #expect(rows.isEmpty)
    }

    @Test("catalogだけの作品は未取得行となり、既存localの本文状態と題名は保持する")
    func mergesLocalAndRemoteRows() throws {
        let local = SyncV2LibraryItem(workID: WorkID(UUID()), title: "端末の題名", availability: .localOnly,
                                      accountState: .active, localGeneration: 7, remoteHeadConfirmed: false,
                                      remoteProgress: .needsChoice, oldestUnreceivedAt: Date(timeIntervalSince1970: 123),
                                      historyBackfillNote: "履歴を取得中")
        let remoteID = WorkID(UUID())
        let rows = LibraryShelf.merge(
            localItems: [local],
            catalog: [.init(workID: local.workID, title: "サーバーの題名", head: nil), .init(workID: remoteID, title: "未取得作品", head: nil)],
            previousItems: [], pendingDeletionIDs: [], deletedIDs: []
        )
        #expect(rows.count == 2)
        let cached = try #require(rows.first { $0.workID == local.workID })
        #expect(cached.title == local.title)
        #expect(cached.availability == .cached)
        #expect(cached.localGeneration == 7)
        #expect(cached.remoteProgress == .needsChoice)
        #expect(!cached.remoteHeadConfirmed)
        #expect(cached.oldestUnreceivedAt == local.oldestUnreceivedAt)
        #expect(cached.historyBackfillNote == local.historyBackfillNote)
        let remote = try #require(rows.first { $0.workID == remoteID })
        #expect(remote.title == "未取得作品")
        #expect(remote.availability == .remoteOnly)
        #expect(remote.accountState == .active)
    }

    @Test("別account保留行は同じIDのcatalogでcachedにならず題名も維持する")
    func preservesParkedBoundary() throws {
        let parked = SyncV2LibraryItem(workID: WorkID(UUID()), title: "保留作品", availability: .localOnly, accountState: .parkedDifferentAccount)
        let rows = LibraryShelf.merge(localItems: [parked], catalog: [.init(workID: parked.workID, title: "remote", head: nil)],
                                      previousItems: [], pendingDeletionIDs: [], deletedIDs: [])
        let row = try #require(rows.first)
        #expect(row.title == parked.title)
        #expect(row.availability == .localOnly)
        #expect(row.accountState == .parkedDifferentAccount)
    }

    @Test("棚は共通presentationの自然順・同名WorkID順で安定する")
    func usesPresentationOrdering() throws {
        let first = try WorkID(#require(UUID(uuidString: "00000000-0000-0000-0000-000000000001")))
        let second = try WorkID(#require(UUID(uuidString: "00000000-0000-0000-0000-000000000002")))
        let tenth = WorkID(UUID())
        let catalog: [SyncV2RemoteCatalogEntry] = [
            .init(workID: tenth, title: "作品10", head: nil),
            .init(workID: second, title: "作品2", head: nil),
            .init(workID: first, title: "作品2", head: nil)
        ]
        let rows = LibraryShelf.merge(localItems: [], catalog: catalog, previousItems: [], pendingDeletionIDs: [], deletedIDs: [])
        #expect(rows.map { $0.workID } == [first, second, tenth])
        for (lhs, rhs) in zip(rows, rows.dropFirst()) {
            #expect(SyncV2LibraryPresentation.precedes(title: lhs.title, workID: lhs.workID, otherTitle: rhs.title, otherWorkID: rhs.workID))
        }
    }
}

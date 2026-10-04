import Foundation
import NovelCore
import NovelSyncV2
import NovelSyncV2Application
import NovelWorkspace
import Testing

@MainActor
struct LibraryCoordinatorMutationTests {
    private func context(_ host: FakeLibraryHost) -> WorkspaceOperationContext {
        .init(workID: host.workID, session: host.session, account: host.account, editGeneration: nil)
    }

    @Test("改名はtrimし、現在の作品だけtitleを更新する。ローカル改名はdownloadしない", arguments: [false, true])
    func renamePreservesInstalledWork(otherWork: Bool) async throws {
        let host = FakeLibraryHost(), backend = FakeLibraryOperations()
        let original = host.document
        let session = host.session
        let target = otherWork ? WorkID(UUID()) : try #require(host.workID)
        #expect(try await LibraryCoordinator(operations: backend.operations).rename(
            workID: target, remoteOnly: false, title: "  新しい名前\n", context: context(host), host: host
        ))
        #expect(backend.events == ["rename:新しい名前"])
        #expect(host.session == session)
        #expect(host.document.title == (otherWork ? original.title : "新しい名前"))
        #expect(host.document.chapters == original.chapters)
        #expect(host.events == ["IME/save", "refresh"])
    }

    @Test("空白名、古いsession/account、gate待ちとdownload後の変更を拒否する", arguments: [0, 1, 2, 3, 4])
    func staleRenameIsRejected(change: Int) async throws {
        let host = FakeLibraryHost(), backend = FakeLibraryOperations()
        let source = context(host)
        let target = try #require(host.workID)
        switch change {
        case 1: host.session = nil
        case 2: host.invalidateAccount()
        case 3: host.prepare = { host.session = nil }
        case 4: backend.onDownload = { host.invalidateAccount() }
        default: break
        }
        #expect(try await !LibraryCoordinator(operations: backend.operations).rename(
            workID: target, remoteOnly: change == 4, title: change == 0 ? " \n" : "変更",
            context: source, host: host
        ))
        #expect(!backend.events.contains { $0.hasPrefix("rename:") })
        #expect(host.document.title == "編集中")
    }

    @Test("remote-only改名のdownloadはgate外。失敗と保存失敗では改名しない", arguments: [false, true])
    func renameDownloadBoundary(fails: Bool) async throws {
        let host = FakeLibraryHost(), backend = FakeLibraryOperations()
        backend.onDownload = {
            #expect(!host.gateHeld)
            if fails {
                throw SyncV2Failure.offline
            }
        }
        host.saveSucceeds = false
        do {
            #expect(try await !LibraryCoordinator(operations: backend.operations).rename(
                workID: WorkID(UUID()), remoteOnly: true, title: "改名", context: context(host), host: host
            ))
            #expect(!fails)
        } catch { #expect(fails) }
        #expect(backend.events == ["download"])
    }

    @Test("削除は保存・予約・退役の順。通信はgate外で別作品のsessionを保持する", arguments: [false, true])
    func deletionOrdering(projectBeforeSending: Bool) async throws {
        let host = FakeLibraryHost(), backend = FakeLibraryOperations()
        let target = try #require(host.workID)
        let source = context(host)
        host.projectsDeletionBeforeSending = projectBeforeSending
        backend.onReserve = {
            #expect(host.gateHeld)
            #expect(host.events == ["cancel-background", "IME/save"])
            #expect(host.generation == 1)
        }
        let replacement = WorkspaceSessionToken(generation: 2, documentID: UUID(), workID: WorkID(UUID()))
        backend.onDelete = {
            #expect(!host.gateHeld)
            #expect(backend.pending.contains(target))
            #expect(host.workID == nil)
            #expect(host.events.contains("refresh") == projectBeforeSending)
            host.session = replacement
            host.workID = replacement.workID
        }
        #expect(try await LibraryCoordinator(operations: backend.operations).delete(workID: target, context: source, host: host))
        #expect(backend.events == ["reserve", "delete"])
        #expect(host.session == replacement)
        #expect(backend.deleted == [target])
    }

    @Test("保存失敗、古いgate要求、予約中の編集/session/account変更は通信・退役しない", arguments: [0, 1, 2, 3, 4])
    func deletionRejectsUnsafeBoundary(change: Int) async throws {
        let host = FakeLibraryHost(), backend = FakeLibraryOperations()
        let source = context(host)
        switch change {
        case 0: host.saveSucceeds = false
        case 1: host.prepare = { host.session = nil }
        case 2: backend.onReserve = { host.generation += 1 }
        case 3: backend.onReserve = { host.session = nil }
        default: backend.onReserve = { host.invalidateAccount() }
        }
        #expect(try await !LibraryCoordinator(operations: backend.operations).delete(
            workID: #require(host.workID), context: source, host: host
        ))
        #expect(!backend.events.contains("delete"))
        #expect(!host.events.contains("retire"))
        #expect(!host.events.contains("remove"))
    }

    @Test("offline削除は予約を保持し、別accountへ遅い結果を反映しない", arguments: [false, true])
    func deletionCompletionScope(switchAccount: Bool) async throws {
        let host = FakeLibraryHost(), backend = FakeLibraryOperations()
        let target = WorkID(UUID()), source = context(host)
        backend.onDelete = {
            if switchAccount {
                host.invalidateAccount()
            }
            throw SyncV2Failure.offline
        }
        do {
            #expect(try await !LibraryCoordinator(operations: backend.operations).delete(workID: target, context: source, host: host))
            #expect(switchAccount)
        } catch { #expect(!switchAccount) }
        #expect(backend.pending == [target])
        #expect(!host.events.contains("remove"))
    }

    @Test("remote-only削除はdownloadせず、offline予約を再試行で完了する")
    func remoteOnlyDeletionRetry() async throws {
        let host = FakeLibraryHost(), backend = FakeLibraryOperations()
        host.workID = nil
        host.session = nil
        let source = context(host), target = WorkID(UUID())
        backend.onDelete = { throw SyncV2Failure.offline }
        let coordinator = LibraryCoordinator(operations: backend.operations)
        await #expect(throws: SyncV2Failure.offline) {
            try await coordinator.delete(workID: target, context: source, host: host)
        }
        #expect(backend.pending == [target])
        backend.onDelete = {}
        #expect(try await coordinator.delete(workID: target, context: source, host: host))
        #expect(backend.pending.isEmpty)
        #expect(backend.deleted == [target])
        #expect(backend.events == ["reserve", "delete", "reserve", "delete"])
    }
}

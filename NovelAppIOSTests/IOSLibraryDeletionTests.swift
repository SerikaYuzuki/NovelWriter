import Foundation
@testable import FUMINIWAIOS
import NovelCore
import NovelSyncV2
import NovelSyncV2Application
import NovelTiming
import Testing

@MainActor
struct IOSLibraryDeletionTests {
    @Test("最後の端末作品を保存して削除し、再起動でも空の棚を表示する", arguments: [false, true])
    func lastLocalWork(dirty: Bool) async throws {
        let config = try TestRuntimeConfiguration(account: nil)
        let defaults = try #require(UserDefaults(suiteName: "IOSDeletion.\(UUID())"))
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = IOSDocumentStore(userDefaults: defaults, libraryRoot: root, runtimeComposition: .test(config))
        await store.bootstrap()
        #expect(await store.makeNewDocument())
        if dirty {
            let chapter = try #require(store.selectedChapterID)
            let episode = try #require(store.selectedEpisodeID)
            store.updateEpisodeContent("削除前に保存する原稿", chapterID: chapter, episodeID: episode)
        }
        _ = await store.refreshLibrary()
        let item = try #require(store.syncV2LibraryItems.first)
        let oldSession = store.currentDocumentSessionToken
        #expect(await store.deleteLibraryWork(item, expectedSession: oldSession, accountScope: store.snapshotSyncV2AccountScope))
        #expect(store.syncV2ActiveWorkID == nil)
        #expect(store.currentDocumentSessionToken == nil)
        #expect(store.startupState == .library)
        #expect(store.syncV2LibraryItems.isEmpty)
        #expect(await config.remote.recordedDeletions().isEmpty)
        let restarted = IOSDocumentStore(userDefaults: defaults, libraryRoot: root, runtimeComposition: .test(config))
        await restarted.bootstrap()
        #expect(restarted.startupState == .library)
        #expect(restarted.syncV2LibraryItems.isEmpty)
    }

    @Test("別作品の削除は現在の本文とsessionを保ち、古いsession/accountと取り込み中を拒否する")
    func deletionBoundaries() async throws {
        let config = try TestRuntimeConfiguration(account: nil)
        let defaults = try #require(UserDefaults(suiteName: "IOSDeletion.\(UUID())"))
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = IOSDocumentStore(userDefaults: defaults, libraryRoot: root, runtimeComposition: .test(config))
        await store.bootstrap()
        #expect(await store.makeNewDocument())
        _ = await store.refreshLibrary()
        let item = try #require(store.syncV2LibraryItems.first)
        let staleSession = store.currentDocumentSessionToken
        #expect(await store.makeNewDocument())
        let session = store.currentDocumentSessionToken
        let account = store.snapshotSyncV2AccountScope
        #expect(await !store.deleteLibraryWork(item, expectedSession: staleSession, accountScope: account))
        store.libraryPrefetchWorkID = item.workID
        #expect(store.libraryDeletionDisabledReason(for: item.workID) != nil)
        #expect(await !store.deleteLibraryWork(item, expectedSession: session, accountScope: account))
        store.libraryPrefetchWorkID = nil
        let chapter = try #require(store.selectedChapterID)
        let episode = try #require(store.selectedEpisodeID)
        store.updateEpisodeContent("残す本文", chapterID: chapter, episodeID: episode)
        #expect(await store.deleteLibraryWork(item, expectedSession: session, accountScope: account))
        #expect(store.currentDocumentSessionToken == session)
        #expect(store.selectedEpisode?.content == "残す本文")
        store.testServerInstanceIDOverride = "different-account"
        #expect(await !store.deleteLibraryWork(item, expectedSession: session, accountScope: account))
    }
}

extension IOSLibraryDeletionTests {
    @Test("未取得作品も同じ削除APIを使い、offline時は再試行まで棚に残す")
    func remoteOnlyDeletion() async throws {
        let config = try TestRuntimeConfiguration()
        let defaults = try #require(UserDefaults(suiteName: "IOSDeletion.\(UUID())"))
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = IOSDocumentStore(userDefaults: defaults, libraryRoot: root, runtimeComposition: .test(config))
        await store.bootstrap()
        store.authUIState = .signedIn(accountID: "test-account")
        let item = SyncV2LibraryItem(workID: WorkID(UUID()), title: "未取得の作品", availability: .remoteOnly, accountState: .active)
        store.syncV2LibraryItems = [item]
        let scope = store.snapshotSyncV2AccountScope
        #expect(await !store.deleteLibraryWork(item, expectedSession: nil, accountScope: scope))
        #expect(store.pendingDeletionWorkIDs.contains(item.workID))
        #expect(store.syncV2LibraryItems.contains { $0.workID == item.workID })
        #expect(await config.remote.recordedDeletions() == [item.workID])
        #expect(await config.remote.recordedHeadReads().isEmpty)
        await config.remote.setDeletionFailure(nil)
        #expect(await store.deleteLibraryWork(item, expectedSession: nil, accountScope: scope))
        #expect(!store.pendingDeletionWorkIDs.contains(item.workID))
        #expect(store.syncV2LibraryItems.isEmpty)
        #expect(await config.remote.recordedDeletions() == [item.workID, item.workID])
    }

    @Test("保存が失敗したらintentを作らず、開いている原稿を保持する")
    func saveFailureKeepsEditor() async throws {
        let config = try TestRuntimeConfiguration(account: nil)
        let defaults = try #require(UserDefaults(suiteName: "IOSDeletion.\(UUID())"))
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = IOSDocumentStore(userDefaults: defaults, libraryRoot: root, runtimeComposition: .test(config))
        await store.bootstrap()
        #expect(await store.makeNewDocument())
        _ = await store.refreshLibrary()
        let item = try #require(store.syncV2LibraryItems.first)
        let session = store.currentDocumentSessionToken
        store.saveCoordinator = V2DocumentSaveCoordinator(
            timing: FuminiwaTiming(autosaveDebounceSeconds: 60, autosavePostSaveWaitSeconds: 60),
            currentDocument: { store.document },
            saveOperation: { _ in throw SyncV2ApplicationError.safeBoundaryRejected }
        )
        store.saveCoordinator.markDirty()
        #expect(await !store.deleteLibraryWork(item, expectedSession: session, accountScope: store.snapshotSyncV2AccountScope))
        #expect(store.currentDocumentSessionToken == session)
        #expect(store.startupState == .ready)
        let app = try #require(store.snapshotSyncV2Application)
        #expect(try await app.pendingDeletionWorkIDs().isEmpty)
        #expect(try await app.deletedWorkIDs().isEmpty)
    }
}

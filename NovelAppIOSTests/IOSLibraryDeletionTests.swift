import Foundation
@testable import FUMINIWAIOS
import NovelCore
import NovelSyncV2
import NovelSyncV2Application
import NovelTiming
import NovelWorkspace
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
}

extension IOSLibraryDeletionTests {
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

@testable import EditorKit
import Foundation
@testable import FUMINIWAIOS
import NovelCore
import NovelSyncV2
import NovelSyncV2Application
import NovelSyncV2Store
import Testing

@MainActor
struct IOSLibraryDeletionSafetyTests {
    @Test("IME確定本文を保存してからintentを作り、offlineでも救出用原稿を保持する", arguments: [false, true])
    func confirmsIMEBeforeIntent(rejectIME: Bool) async throws {
        let config = try TestRuntimeConfiguration()
        let store = try await makeStore(config)
        #expect(await store.makeNewDocument())
        _ = await store.refreshLibrary()
        let item = try #require(store.workspaceModel.libraryRows.first)
        let chapter = try #require(store.workspaceModel.selectedChapterID)
        let episode = try #require(store.workspaceModel.selectedEpisodeID)
        let originalSession = store.currentDocumentSessionToken
        store.editorCommandSession.registerDocumentLifecycleHandler(id: UUID(), prepare: {
            guard !rejectIME else { return false }
            store.updateEpisodeContent("入力確定した最後の原稿", chapterID: chapter, episodeID: episode)
            return true
        }, resume: {})
        #expect(await !store.deleteLibraryWork(item, expectedSession: originalSession, accountScope: store.snapshotSyncV2AccountScope))
        let disk = try LocalSyncV2Store(root: config.localRoot.url, policy: .openExisting)
        if rejectIME {
            #expect(try await disk.workDeletion(workID: item.workID) == nil)
            #expect(store.currentDocumentSessionToken == originalSession)
            #expect(await config.remote.recordedDeletions().isEmpty)
        } else {
            #expect(try await disk.workDeletion(workID: item.workID)?.completed == false)
            let saved = try await disk.open(workID: item.workID, scope: .bound(.init(
                accountID: "test-account", accountFence: "test-fence", serverInstanceID: "test-server"
            )))
            #expect(saved.document?.chapters.first?.episodes.first?.content == "入力確定した最後の原稿")
            #expect(store.currentDocumentSessionToken == nil)
            #expect(store.startupState == .library)
        }
        await disk.close()
    }

    @Test("通信中はgateを解放し、遅い削除完了で新しく開いた作品を閉じない")
    func networkDoesNotOwnDocumentGate() async throws {
        let config = try TestRuntimeConfiguration()
        let store = try await makeStore(config)
        #expect(await store.makeNewDocument())
        _ = await store.refreshLibrary()
        let item = try #require(store.workspaceModel.libraryRows.first)
        let started = AsyncStream<Void>.makeStream()
        let release = AsyncStream<Void>.makeStream()
        await config.remote.setDeletionHandler { _ in
            started.continuation.yield(())
            for await _ in release.stream {
                break
            }
        }
        let session = store.currentDocumentSessionToken
        let account = store.snapshotSyncV2AccountScope
        let deleting = Task { await store.deleteLibraryWork(item, expectedSession: session, accountScope: account) }
        var start = started.stream.makeAsyncIterator()
        _ = await start.next()
        #expect(store.currentDocumentSessionToken == nil)
        #expect(!store.workspaceModel.isDocumentTransitionInProgress)
        #expect(await store.makeNewDocument())
        let replacement = store.currentDocumentSessionToken
        release.continuation.finish()
        #expect(await deleting.value)
        #expect(store.currentDocumentSessionToken == replacement)
        #expect(store.startupState == .ready)
        started.continuation.finish()
    }

    private func makeStore(_ config: TestRuntimeConfiguration) async throws -> IOSDocumentStore {
        let defaults = try #require(UserDefaults(suiteName: config.defaults.suiteName))
        let store = IOSDocumentStore(userDefaults: defaults, libraryRoot: config.localRoot.url,
                                     runtimeComposition: .test(config))
        await store.bootstrap()
        store.workspaceModel.authUIState = .signedIn(accountID: "test-account")
        return store
    }
}

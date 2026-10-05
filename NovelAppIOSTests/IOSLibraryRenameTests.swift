import Foundation
@testable import FUMINIWAIOS
import NovelCore
import NovelSyncV2Application
import Testing

@MainActor
struct IOSLibraryRenameTests {
    @Test("一覧から別作品を改名しても現在の本文と選択は変わらず、再読込で名前を維持する")
    func renameFromLibraryPreservesCurrentWork() async throws {
        let suite = "IOSLibraryRename.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(suite)
        defer {
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: root)
        }
        let configuration = try TestRuntimeConfiguration(account: nil)
        let store = IOSDocumentStore(userDefaults: defaults, libraryRoot: root, runtimeComposition: .test(configuration))
        await store.bootstrap()
        #expect(await store.makeNewDocument())
        let first = try #require(store.workspaceModel.activeWorkID)
        #expect(await store.makeNewDocument())
        let second = try #require(store.workspaceModel.activeWorkID)
        let chapter = try #require(store.workspaceModel.selectedChapterID)
        let episode = try #require(store.workspaceModel.selectedEpisodeID)
        store.updateEpisodeContent("編集中の本文", chapterID: chapter, episodeID: episode)
        _ = await store.refreshLibrary()
        let firstItem = try #require(store.workspaceModel.libraryRows.first { $0.workID == first })
        let token = store.currentEpisodeEditingToken
        let session = store.currentDocumentSessionToken
        let scope = store.snapshotSyncV2AccountScope
        #expect(await store.renameLibraryWork(firstItem, title: "一覧で変更", expectedSession: session, accountScope: scope))
        #expect(store.workspaceModel.activeWorkID == second)
        #expect(store.selectedEpisode?.content == "編集中の本文")
        #expect(store.currentEpisodeEditingToken == token)
        #expect(store.workspaceModel.libraryRows.first { $0.workID == first }?.title == "一覧で変更")
        let secondItem = try #require(store.workspaceModel.libraryRows.first { $0.workID == second })
        #expect(await store.renameLibraryWork(secondItem, title: "現在の作品も変更", expectedSession: session, accountScope: scope))
        #expect(store.workspaceModel.document.title == "現在の作品も変更")
        #expect(store.currentEpisodeEditingToken == token)
        #expect(await store.saveNow())
        #expect(await store.openPrivateDocument(id: IOSPrivateDocumentID(workID: first)))
        #expect(store.workspaceModel.document.title == "一覧で変更")
    }
}

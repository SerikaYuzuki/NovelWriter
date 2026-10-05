import Foundation
@testable import FUMINIWA
import NovelCore
import NovelSyncV2
import NovelSyncV2Application
import NovelSyncV2Runtime
import Testing

@MainActor
struct LibraryRenameTests {
    @Test("一覧からの名前変更は編集中本文を保存し、同じ作品と選択を維持する")
    func activeWorkRenamePreservesEditor() async throws {
        let state = try await makeState()
        let chapterID = try #require(state.workspaceModel.selectedChapterID)
        let episodeID = try #require(state.workspaceModel.selectedEpisodeID)
        state.updateEpisodeContent("変更前の入力", for: episodeID, in: chapterID)
        let session = state.workspaceModel.documentSessionToken
        let generation = state.workspaceModel.editorContentGeneration
        await state.refreshSnapshotLibrary()
        let work = try #require(state.snapshotSyncLibraryWorks.first { $0.workID == state.currentSnapshotSyncV2WorkID })
        #expect(await state.renameLibraryWork(work, title: "一覧で変更", expectedSession: session,
                                              accountScope: state.snapshotSyncV2AccountScopeToken))
        #expect(state.workspaceModel.document.title == "一覧で変更")
        #expect(state.workspaceModel.selectedEpisodeID == episodeID)
        #expect(state.workspaceModel.documentSessionToken == session)
        #expect(state.workspaceModel.editorContentGeneration == generation)
        let application = try #require(state.snapshotSyncV2Application)
        let saved = try await application.openLocal(workID: work.workID)
        #expect(saved.document?.title == "一覧で変更")
        #expect(saved.document?.episode(episodeID)?.episode.content == "変更前の入力")
        #expect(state.snapshotSyncLibraryWorks.first { $0.workID == work.workID }?.title == "一覧で変更")
    }

    private func makeState() async throws -> AppState {
        let configuration = try TestRuntimeConfiguration(account: nil)
        let state = AppState(dependencies: AppDependencies(
            userDefaults: UserDefaults(suiteName: "LibraryRename.\(UUID())")!,
            snapshotSyncV2Factory: { try await SnapshotSyncV2Runtime.makeApplication(mode: .test(configuration)) }
        ))
        #expect(await state.configureSnapshotSyncV2(using: state.snapshotSyncV2Factory))
        await state.bootstrap()
        return state
    }
}

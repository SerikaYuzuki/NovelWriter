import Foundation
@testable import FUMINIWA
import NovelCore
import NovelWorkspace
import Testing

@MainActor
struct AppStateEpisodeSelectionTests {
    @Test("新規状態は最初の章と本文話を選択する")
    func newStateSelectsFirstEpisode() {
        let state = makeState()
        #expect(state.workspaceModel.selectedChapterID == state.workspaceModel.document.chapters.first?.id)
        #expect(state.workspaceModel.selectedEpisodeID == state.workspaceModel.document.chapters.first?.episodes.first?.id)
    }

    @Test("話単位の本文・メモ更新は選択中話だけへ反映する")
    func episodeOperationsUpdateSelectedEpisode() throws {
        let state = makeState()
        let chapterID = try #require(state.workspaceModel.selectedChapterID)
        let firstEpisodeID = try #require(state.workspaceModel.selectedEpisodeID)

        state.addEpisode(to: chapterID, title: "第2話")
        let secondEpisodeID = try #require(state.workspaceModel.selectedEpisodeID)
        state.updateSelectedEpisodeContent("第2話本文")
        state.updateSelectedEpisodeMemo("第2話メモ")

        #expect(secondEpisodeID != firstEpisodeID)
        #expect(state.workspaceModel.document.episode(secondEpisodeID)?.episode.content == "第2話本文")
        #expect(state.workspaceModel.document.episode(secondEpisodeID)?.episode.memo == "第2話メモ")
        state.selectEpisode(firstEpisodeID, in: chapterID)
        #expect(state.selectedEpisode?.content.isEmpty == true)
    }

    @Test("離脱のローカル保存が失敗したら選択を変更しない")
    func failedDepartureKeepsSelection() async throws {
        let state = makeState()
        let chapterID = try #require(state.workspaceModel.selectedChapterID)
        let original = try #require(state.workspaceModel.selectedEpisodeID)
        let added = state.workspaceModel.document.addEpisode(to: chapterID, title: "移動先")
        let target = try #require(added)
        state.saveCoordinator = V2DocumentSaveCoordinator(currentDocument: { state.workspaceModel.document }, saveOperation: { _ in
            throw CancellationError()
        })
        state.saveCoordinator.markDirty()
        #expect(await state.selectEpisodeAfterTransition(target, in: chapterID) == false)
        #expect(state.workspaceModel.selectedEpisodeID == original)
        #expect(!state.workspaceModel.isDocumentTransitionInProgress)
        #expect(!state.editorCommandSession.isDocumentTransitionPrepared)
    }

    private func makeState() -> AppState {
        AppState(
            dependencies: AppDependencies(
                userDefaults: UserDefaults(suiteName: "FUMINIWA.AppStateEpisodeSelectionTests.\(UUID().uuidString)")!
            ),
            initialStartupState: .ready
        )
    }
}

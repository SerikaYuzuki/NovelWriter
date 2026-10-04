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
        #expect(state.selectedChapterID == state.document.chapters.first?.id)
        #expect(state.selectedEpisodeID == state.document.chapters.first?.episodes.first?.id)
    }

    @Test("話単位の本文・メモ更新は選択中話だけへ反映する")
    func episodeOperationsUpdateSelectedEpisode() throws {
        let state = makeState()
        let chapterID = try #require(state.selectedChapterID)
        let firstEpisodeID = try #require(state.selectedEpisodeID)

        state.addEpisode(to: chapterID, title: "第2話")
        let secondEpisodeID = try #require(state.selectedEpisodeID)
        state.updateSelectedEpisodeContent("第2話本文")
        state.updateSelectedEpisodeMemo("第2話メモ")

        #expect(secondEpisodeID != firstEpisodeID)
        #expect(state.document.episode(secondEpisodeID)?.episode.content == "第2話本文")
        #expect(state.document.episode(secondEpisodeID)?.episode.memo == "第2話メモ")
        state.selectEpisode(firstEpisodeID, in: chapterID)
        #expect(state.selectedEpisode?.content.isEmpty == true)
    }

    @Test("離脱のローカル保存が失敗したら選択を変更しない")
    func failedDepartureKeepsSelection() async throws {
        let state = makeState()
        let chapterID = try #require(state.selectedChapterID)
        let original = try #require(state.selectedEpisodeID)
        let added = state.document.addEpisode(to: chapterID, title: "移動先")
        let target = try #require(added)
        state.saveCoordinator = V2DocumentSaveCoordinator(currentDocument: { state.document }, saveOperation: { _ in
            throw CancellationError()
        })
        state.saveCoordinator.markDirty()
        #expect(await state.selectEpisodeAfterTransition(target, in: chapterID) == false)
        #expect(state.selectedEpisodeID == original)
        #expect(!state.isDocumentTransitionInProgress)
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

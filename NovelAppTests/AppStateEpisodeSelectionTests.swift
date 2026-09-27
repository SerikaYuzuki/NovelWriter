import Foundation
@testable import FUMINIWA
import NovelCore
import Testing

@MainActor
struct AppStateEpisodeSelectionTests {
    @Test("新規状態は最初の章と本文話を選択する")
    func newStateSelectsFirstEpisode() {
        let state = makeState()
        #expect(state.selectedChapterID == state.document.chapters.first?.id)
        #expect(state.selectedEpisodeID == state.document.chapters.first?.episodes.first?.id)
    }

    @Test("タイトル省略の話追加は第N話になる")
    func addEpisodeWithoutTitleUsesNumberedDefault() throws {
        let state = makeState()
        let chapterID = try #require(state.selectedChapterID)
        state.addEpisode(to: chapterID)

        #expect(state.selectedEpisode?.title == "第2話")
        #expect(state.document.chapters[0].episodes.map(\.title) == ["本文", "第2話"])
    }

    @Test("章追加は空章を選択し、話追加は選択中の章へ追加する")
    func chapterAndEpisodeAddActionsKeepTheirTargetsSeparate() throws {
        let state = makeState()
        state.addChapter()
        let chapterID = try #require(state.selectedChapterID)
        #expect(state.document.chapters.last?.episodes.isEmpty == true)
        #expect(state.selectedEpisodeID == nil)

        state.addEpisode()
        #expect(try state.document.episode(#require(state.selectedEpisodeID))?.chapterID == chapterID)
        #expect(state.selectedEpisode?.title == "第1話")
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

    @Test("話削除後は同じ章の隣接話へ選択を移す")
    func deletingSelectedEpisodeFallsBackToNeighbor() throws {
        let state = makeState()
        let chapterID = try #require(state.selectedChapterID)
        state.addEpisode(to: chapterID, title: "第2話")
        let secondEpisodeID = try #require(state.selectedEpisodeID)
        let firstEpisodeID = state.document.chapters[0].episodes[0].id

        #expect(state.deleteEpisode(id: secondEpisodeID, from: chapterID))
        #expect(state.selectedEpisodeID == firstEpisodeID)
        #expect(state.document.chapters[0].episodes.count == 1)
    }

    @Test("別章へ話を移動すると選択章も追従する")
    func movingSelectedEpisodeAcrossChaptersMovesSelection() throws {
        let state = makeState()
        let sourceChapterID = try #require(state.selectedChapterID)
        let episodeID = try #require(state.selectedEpisodeID)
        state.addChapter()
        let destinationChapterID = try #require(state.selectedChapterID)
        state.selectEpisode(episodeID, in: sourceChapterID)

        #expect(state.moveEpisode(
            id: episodeID,
            from: sourceChapterID,
            to: destinationChapterID
        ))
        #expect(state.selectedChapterID == destinationChapterID)
        #expect(state.selectedEpisodeID == episodeID)
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

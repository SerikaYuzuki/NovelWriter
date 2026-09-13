import Foundation
@testable import FUMINIWA
import NovelCore
import Testing

@MainActor
struct EpisodeRenameTests {
    @Test("選択していない話を変更しても本文・選択・Editor世代を維持する")
    func renameKeepsEditorState() throws {
        let state = makeState()
        let chapterID = try #require(state.selectedChapterID)
        let original = try #require(state.selectedEpisode)
        var request = EpisodeRenameRequest(episode: original, chapterID: chapterID, appState: state)
        state.addEpisode(to: chapterID)
        let selection = state.selectedEpisodeID
        let generation = state.editorContentGeneration
        request.title = "  新しい話名  "
        request.apply(to: state)
        #expect(state.document.episode(original.id)?.episode.title == "新しい話名")
        #expect(state.document.episode(original.id)?.episode.content == original.content)
        #expect(state.selectedEpisodeID == selection)
        #expect(state.editorContentGeneration == generation)
    }

    @Test("古いアカウント・空白の名前・存在しない章を拒否する")
    func rejectsInvalidRequests() throws {
        let state = makeState()
        let chapterID = try #require(state.selectedChapterID)
        let episode = try #require(state.selectedEpisode)
        var request = EpisodeRenameRequest(episode: episode, chapterID: chapterID, appState: state)
        request.title = " \n "
        request.apply(to: state)
        #expect(state.selectedEpisode?.title == episode.title)
        request.title = "古いアカウント"
        state.snapshotSyncV2AccountScopeGeneration += 1
        request.apply(to: state)
        #expect(state.selectedEpisode?.title == episode.title)
        state.updateEpisodeTitle("別の章", for: episode.id, in: ChapterID())
        #expect(state.selectedEpisode?.title == episode.title)
    }

    @Test("作品を開き直した後に古いダイアログを適用しない")
    func rejectsStaleSession() throws {
        let state = makeState()
        let chapterID = try #require(state.selectedChapterID)
        let episode = try #require(state.selectedEpisode)
        var request = EpisodeRenameRequest(episode: episode, chapterID: chapterID, appState: state)
        request.title = "古い作品の操作"
        state.documentSessionToken.generation += 1
        request.apply(to: state)
        #expect(state.selectedEpisode?.title == episode.title)
    }

    private func makeState() -> AppState {
        AppState(
            dependencies: AppDependencies(repository: RenameRepository(),
                                          userDefaults: UserDefaults(suiteName: "EpisodeRename.\(UUID())")!,
                                          fileManager: .default),
            initialStartupState: .ready
        )
    }
}

private actor RenameRepository: DocumentRepository {
    func load(from _: URL) async throws -> NovelDocument {
        .newDocument()
    }

    func save(_: NovelDocument, to _: URL) async throws {}
}

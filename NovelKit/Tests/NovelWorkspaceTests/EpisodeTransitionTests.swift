import NovelCore
import NovelWorkspace
import Testing

@MainActor
struct EpisodeTransitionTests {
    @Test("IME→旧話の保存→選択→保存→resume")
    func departureOrder() async throws {
        let host = FakeWorkspaceHost()
        let original = try #require(host.selectedEpisodeID)
        let chapter = try #require(host.selectedChapterID)
        #expect(OutlineCommands(host: host).addEpisode(to: chapter))
        let target = try #require(host.selectedEpisodeID)
        #expect(OutlineCommands(host: host).selectEpisode(original, in: chapter))
        #expect(await EpisodeTransition(host: host).perform(saveAfter: true) {
            host.events.append("switch")
            return OutlineCommands(host: host, preparedTransition: true).selectEpisode(target, in: chapter)
        })
        #expect(host.savedDepartureSelection == original)
        #expect(host.selectedEpisodeID == target)
        #expect(host.events == ["commit IME", "save departure", "switch", "save selection", "resume"])
    }

    @Test("IME・保存失敗とawait中のsession/account変更は操作しない", arguments: [0, 1, 2, 3])
    func rejectsFailedOrStaleDeparture(reason: Int) async {
        let host = FakeWorkspaceHost()
        let before = host.document
        host.departureAllowed = reason != 0
        host.saveSucceeds = reason != 1
        if reason == 2 {
            host.onDeparture = { host.session.generation += 1 }
        }
        if reason == 3 {
            host.onDeparture = { host.accountGeneration += 1 }
        }
        #expect(await EpisodeTransition(host: host).perform {
            OutlineCommands(host: host, preparedTransition: true).addChapter()
        } == false)
        #expect(host.document == before)
    }
}

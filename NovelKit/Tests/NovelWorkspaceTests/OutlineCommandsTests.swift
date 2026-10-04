import Foundation
import NovelCore
import NovelWorkspace
import Testing

@MainActor
struct OutlineCommandsTests {
    @Test("章追加と話タイトルのOS別policyを保つ", arguments: [false, true])
    func addDefaults(firstEpisode: Bool) throws {
        let host = FakeWorkspaceHost()
        let commands = OutlineCommands(host: host, policy: .flushNow)
        #expect(commands.addChapter(includingFirstEpisode: firstEpisode))
        let chapterID = try #require(host.selectedChapterID)
        #expect(host.document.chapters.last?.episodes.count == (firstEpisode ? 1 : 0))
        #expect(commands.addEpisode(to: chapterID, firstTitle: firstEpisode ? Episode.defaultTitle : nil))
        #expect(try host.document.episode(#require(host.selectedEpisodeID))?.episode.title == (firstEpisode ? "第2話" : "第1話"))
        #expect(host.policies == [.flushNow, .flushNow])
    }

    @Test("削除は隣接話／先頭話へ選択修復し、最後の章は保持", arguments: [OutlineSelectionRepair.adjacent, .first])
    func deletionRepair(repair: OutlineSelectionRepair) throws {
        let host = FakeWorkspaceHost()
        let commands = OutlineCommands(host: host)
        let chapter = try #require(host.selectedChapterID)
        #expect(commands.addEpisode(to: chapter))
        #expect(commands.addEpisode(to: chapter))
        let ids = host.document.chapters[0].episodes.map(\.id)
        #expect(commands.selectEpisode(ids[1], in: chapter))
        #expect(commands.deleteEpisodes([ids[1]], in: chapter, repair: repair))
        #expect(host.selectedEpisodeID == (repair == .adjacent ? ids[2] : ids[0]))
        #expect(!commands.deleteChapter(chapter))
        #expect(commands.addChapter())
        let added = try #require(host.selectedChapterID)
        #expect(commands.deleteChapter(added))
        #expect(host.selectedChapterID == chapter)
        #expect(host.selectedEpisodeID == ids[0])
    }

    @Test("配列順の移動と選択追従、古い改名を拒否")
    func moveAndRename() throws {
        let host = FakeWorkspaceHost()
        let commands = OutlineCommands(host: host, policy: .debounced)
        let chapter = try #require(host.selectedChapterID)
        let first = try #require(host.selectedEpisodeID)
        #expect(commands.addEpisode(to: chapter))
        let second = try #require(host.selectedEpisodeID)
        commands.moveEpisodes(in: chapter, fromOffsets: IndexSet(integer: 0), toOffset: 2)
        #expect(host.document.chapters[0].episodes.map { $0.id } == [second, first])
        #expect(commands.addChapter())
        let destination = try #require(host.selectedChapterID)
        #expect(commands.selectEpisode(first, in: chapter))
        #expect(commands.moveEpisode(first, from: chapter, to: destination))
        #expect(host.selectedChapterID == destination)
        #expect(host.selectedEpisodeID == first)
        let old = host.session
        host.session.generation += 1
        commands.renameEpisode("stale", id: first, in: destination, expectedSession: old)
        #expect(host.document.episode(first)?.episode.title != "stale")
        commands.renameChapter("改名", id: destination)
        commands.renameEpisode("話名", id: first, in: destination)
        #expect(host.document.chapters.last?.title == "改名")
        #expect(host.document.episode(first)?.episode.title == "話名")
    }
}

import NovelCore
import NovelTextAnalysis
import NovelWorkspace
import Testing

@MainActor
struct WorkReplacementHostFactoryTests {
    @Test func replacementUsesPortAndRejectsStaleSessionOrText() {
        let host = FakeWorkspaceHost()
        host.document = NovelDocument(title: "作品", chapters: [Chapter(title: "章", episodes: [Episode(title: "話", content: "元の本文")])])
        let chapter = host.document.chapters[0], episode = chapter.episodes[0]
        let change = EpisodeTextChange(chapterID: chapter.id, episodeID: episode.id, before: episode.content, after: "新しい本文", count: 1)
        let replacement = WorkReplacementHostFactory.make(host: host, scope: "scope")
        #expect(replacement.apply([change]))
        #expect(host.document.chapters[0].episodes[0].content == "新しい本文")
        #expect(host.policies == [.debounced])
        #expect(!replacement.apply([change]))
        host.session.generation += 1
        #expect(!replacement.validate())
        #expect(!replacement.apply([change.inverse]))
        #expect(host.policies.count == 1)
    }
}

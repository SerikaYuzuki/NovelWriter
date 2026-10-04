import EditorKit
import NovelCore
import NovelWorkspace
import Testing

@MainActor
struct ManuscriptCopyCommandTests {
    @Test("exact選択と配列順の章は現在Editor本文だけを使い、modelを書かない")
    func plainTextScopes() throws {
        let host = FakeWorkspaceHost()
        let chapter = try #require(host.selectedChapterID)
        let first = try #require(host.selectedEpisodeID)
        host.document.updateEpisodeContent("一話本文", for: first, in: chapter)
        #expect(OutlineCommands(host: host).addEpisode(to: chapter, title: "二話"))
        let second = try #require(host.selectedEpisodeID)
        host.selectedEpisodeEditorActive = true
        host.manuscriptCapture = .captured("Editor確定本文")
        let before = host.document
        let command = ManuscriptCopyCommand(host: host)
        let exact = "  e\u{301}😀\r\n選択本文  "
        #expect(command.copy(.selection(text: exact, chapterID: chapter, episodeID: second), expectedSession: host.session) == .success)
        #expect(host.clipboard == [exact])
        #expect(command.copy(.chapter(chapter), expectedSession: host.session) == .success)
        #expect(host.clipboard.last == "第1章\n\n本文\n\n一話本文\n\n二話\n\nEditor確定本文")
        #expect(host.document == before)
    }

    @Test("IME中は全scope拒否、失効・空・上限・clipboard失敗の結果を共有")
    func failures() throws {
        let host = FakeWorkspaceHost()
        let chapter = try #require(host.selectedChapterID)
        let episode = try #require(host.selectedEpisodeID)
        host.selectedEpisodeEditorActive = true
        host.manuscriptCapture = .compositionInProgress
        let command = ManuscriptCopyCommand(host: host)
        let requests: [ManuscriptCopyRequest] = [.selection(text: "本文", chapterID: chapter, episodeID: episode),
                                                 .episode(chapterID: chapter, episodeID: episode), .chapter(chapter)]
        for request in requests {
            #expect(command.copy(request, expectedSession: host.session) == .failure(.compositionInProgress))
        }
        #expect(host.clipboard.isEmpty)
        host.manuscriptCapture = .notActive
        #expect(command.copy(requests[1], expectedSession: host.session) == .failure(.emptyContent))
        host.manuscriptCapture = .captured("本文")
        var stale = host.session
        stale.generation += 1
        #expect(command.copy(requests[1], expectedSession: stale) == .failure(.staleContext))
        #expect(command.copy(requests[1], expectedSession: host.session,
                             limits: .init(maximumSourceCharacters: 0, maximumSourceUTF8Bytes: 0, maximumOutputUTF8Bytes: 0)) == .failure(.contentTooLarge))
        #expect(host.clipboard.isEmpty)
        host.clipboardSucceeds = false
        #expect(command.copy(requests[1], expectedSession: host.session) == .failure(.clipboardWriteFailed))
        #expect(host.clipboard.count == 1)
    }
}

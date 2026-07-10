import Foundation
import NovelCore
import Testing

@Test func addEpisodeAppendsToChapterAndReturnsID() throws {
    let chapter = Chapter(title: "第1章", episodes: [])
    var document = NovelDocument(title: "話操作", chapters: [chapter])

    let episodeID = document.addEpisode(to: chapter.id, title: "第一話")

    #expect(try document.chapters[0].episodes.map(\.id) == [#require(episodeID)])
    #expect(document.chapters[0].episodes[0].title == "第一話")
}

@Test func updateAndRemoveEpisodeChangesOnlyTarget() throws {
    let first = Episode(title: "第一話", content: "A", memo: "メモA")
    let second = Episode(title: "第二話", content: "B", memo: "メモB")
    let chapter = Chapter(title: "第1章", episodes: [first, second])
    var document = NovelDocument(title: "話操作", chapters: [chapter])

    document.updateEpisodeTitle("更新", for: first.id, in: chapter.id)
    document.updateEpisodeContent("本文", for: first.id, in: chapter.id)
    document.updateEpisodeMemo("新メモ", for: first.id, in: chapter.id)
    let removed = document.removeEpisode(id: second.id, from: chapter.id)

    #expect(document.chapters[0].episodes.count == 1)
    #expect(document.chapters[0].episodes[0] == Episode(id: first.id, title: "更新", content: "本文", memo: "新メモ"))
    #expect(try #require(removed).episode == second)
    #expect(try #require(removed).index == 1)
}

@Test func moveEpisodesReordersWithinChapter() {
    let episodes = (1 ... 3).map { Episode(title: "第\($0)話") }
    let chapter = Chapter(title: "第1章", episodes: episodes)
    var document = NovelDocument(title: "話操作", chapters: [chapter])

    document.moveEpisodes(in: chapter.id, fromOffsets: IndexSet(integer: 0), toOffset: 3)

    #expect(document.chapters[0].episodes.map(\.id) == [episodes[1].id, episodes[2].id, episodes[0].id])
}

@Test func moveEpisodeCanMoveAcrossChaptersAndPreserveSelectionTarget() {
    let moved = Episode(title: "移動")
    let source = Chapter(title: "第1章", episodes: [moved])
    let targetEpisode = Episode(title: "先にある話")
    let target = Chapter(title: "第2章", episodes: [targetEpisode])
    var document = NovelDocument(title: "話操作", chapters: [source, target])

    let didMove = document.moveEpisode(id: moved.id, from: source.id, to: target.id, before: targetEpisode.id)
    #expect(didMove)
    #expect(document.chapters[0].episodes.isEmpty)
    #expect(document.chapters[1].episodes.map(\.id) == [moved.id, targetEpisode.id])
    #expect(document.episode(moved.id)?.chapterID == target.id)
}

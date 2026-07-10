import Foundation
@testable import NovelCore
import Testing

@Test func addEpisodeAppendsAndReturnsSelectionID() throws {
    var document = NovelDocument(title: "話操作", chapters: [Chapter(title: "第1章", episodes: [])])

    let episodeID = document.addEpisode(to: document.chapters[0].id, title: "第1話")

    #expect(episodeID != nil)
    #expect(try document.chapters[0].episodes.map(\.id) == [#require(episodeID)])
    #expect(document.chapters[0].episodes[0].title == "第1話")
}

@Test func episodeUpdatesTargetOnly() {
    let first = Episode(title: "第1話", content: "A", memo: "a")
    let second = Episode(title: "第2話", content: "B", memo: "b")
    let chapter = Chapter(title: "第1章", episodes: [first, second])
    var document = NovelDocument(title: "話操作", chapters: [chapter])

    document.updateEpisodeTitle("更新", for: second.id, in: chapter.id)
    document.updateEpisodeContent("本文", for: second.id, in: chapter.id)
    document.updateEpisodeMemo("メモ", for: second.id, in: chapter.id)

    #expect(document.chapters[0].episodes[0] == first)
    #expect(document.chapters[0].episodes[1] == Episode(id: second.id, title: "更新", content: "本文", memo: "メモ"))
}

@Test func moveEpisodeAcrossChaptersPreservesOrder() {
    let first = Episode(title: "第1話")
    let second = Episode(title: "第2話")
    let destinationFirst = Episode(title: "移動先")
    let source = Chapter(title: "第1章", episodes: [first, second])
    let destination = Chapter(title: "第2章", episodes: [destinationFirst])
    var document = NovelDocument(title: "話操作", chapters: [source, destination])

    let moved = document.moveEpisode(
        id: second.id,
        from: source.id,
        to: destination.id,
        before: destinationFirst.id
    )
    #expect(moved)
    #expect(document.chapters[0].episodes.map(\.id) == [first.id])
    #expect(document.chapters[1].episodes.map(\.id) == [second.id, destinationFirst.id])
}

@Test func removeEpisodeReturnsOriginalIndex() {
    let first = Episode(title: "第1話")
    let second = Episode(title: "第2話")
    let chapter = Chapter(title: "第1章", episodes: [first, second])
    var document = NovelDocument(title: "話操作", chapters: [chapter])

    let removed = document.removeEpisode(id: second.id, from: chapter.id)

    #expect(removed?.episode == second)
    #expect(removed?.index == 1)
    #expect(document.chapters[0].episodes == [first])
}

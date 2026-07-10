import Foundation
@testable import NovelCore
import Testing

@Test func episodeIDIsCodable() throws {
    let id = EpisodeID()
    let data = try JSONEncoder().encode(id)
    let decoded = try JSONDecoder().decode(EpisodeID.self, from: data)
    #expect(decoded == id)
    #expect(decoded.description == id.rawValue.uuidString)
}

@Test func chapterPreservesEpisodeOrderAndContent() throws {
    let first = Episode(title: "第1話", content: "最初")
    let second = Episode(title: "第2話", content: "次", memo: "メモ")
    let chapter = Chapter(title: "第1章", episodes: [first, second])

    let data = try JSONEncoder().encode(chapter)
    let decoded = try JSONDecoder().decode(Chapter.self, from: data)

    #expect(decoded.episodes == [first, second])
    #expect(decoded.content == "最初")
    #expect(decoded.memo == "")
}

@Test func novelDocumentManuscriptCharacterCountSumsAllEpisodes() {
    let doc = NovelDocument(
        title: "話ごとの文字数",
        chapters: [
            Chapter(
                title: "第1章",
                episodes: [
                    Episode(title: "第1話", content: "一二"),
                    Episode(title: "第2話", content: "三四五")
                ]
            )
        ]
    )

    #expect(doc.manuscriptCharacterCount == 5)
}

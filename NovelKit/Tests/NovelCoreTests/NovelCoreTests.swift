import Foundation
@testable import NovelCore
import Testing

// `NovelCore` のモデル(`ChapterID` / `Chapter` / `NovelDocument`)に対するテスト
// (docs/DESIGN.md 4.1)。

@Test func chapterIDGeneratesUniqueValues() {
    let firstID = ChapterID()
    let secondID = ChapterID()
    #expect(firstID != secondID)
}

@Test func chapterIDRoundTripsThroughRawValue() {
    let uuid = UUID()
    let id = ChapterID(rawValue: uuid)
    #expect(id.rawValue == uuid)
    #expect(id.description == uuid.uuidString)
}

@Test func chapterIDIsCodable() throws {
    let id = ChapterID()
    let data = try JSONEncoder().encode(id)
    let decoded = try JSONDecoder().decode(ChapterID.self, from: data)
    #expect(decoded == id)
}

@Test func chapterDefaultsToEmptyContent() {
    let chapter = Chapter(title: "第1章")
    #expect(chapter.content.isEmpty)
    #expect(chapter.title == "第1章")
}

@Test func novelDocumentChaptersOrderIsArrayOrder() {
    let first = Chapter(title: "第1章")
    let second = Chapter(title: "第2章")
    let doc = NovelDocument(title: "テスト作品", chapters: [first, second])

    #expect(doc.chapters.map(\.id) == [first.id, second.id])

    var reordered = doc
    reordered.chapters.swapAt(0, 1)
    #expect(reordered.chapters.map(\.id) == [second.id, first.id])
}

@Test func newDocumentFactoryCreatesOneChapter() {
    let doc = NovelDocument.newDocument()
    #expect(doc.chapters.count == 1)
    #expect(!doc.title.isEmpty)
    #expect(!doc.chapters[0].title.isEmpty)
}

@Test func novelDocumentIsCodableRoundTrip() throws {
    let doc = NovelDocument(
        title: "テスト作品",
        chapters: [Chapter(title: "第1章", content: "本文")]
    )
    let data = try JSONEncoder().encode(doc)
    let decoded = try JSONDecoder().decode(NovelDocument.self, from: data)
    #expect(decoded == doc)
}

// MARK: - addChapter / moveChapters / updateContent (docs/DESIGN.md 5.2)

@Test func addChapterAppendsToEndAndReturnsItsID() {
    var doc = NovelDocument(title: "テスト作品", chapters: [Chapter(title: "第1章")])
    let newID = doc.addChapter(title: "第2章")

    #expect(doc.chapters.count == 2)
    #expect(doc.chapters.last?.id == newID)
    #expect(doc.chapters.last?.title == "第2章")
    #expect(doc.chapters.last?.content.isEmpty == true)
}

@Test func moveChaptersReordersLikeSwiftUIOnMove() {
    let first = Chapter(title: "第1章")
    let second = Chapter(title: "第2章")
    let third = Chapter(title: "第3章")
    var doc = NovelDocument(title: "テスト作品", chapters: [first, second, third])

    // 先頭の要素を末尾へ移動する(List.onMove と同じ (IndexSet, Int) 形)。
    doc.moveChapters(fromOffsets: IndexSet(integer: 0), toOffset: 3)

    #expect(doc.chapters.map(\.id) == [second.id, third.id, first.id])
}

@Test func updateContentUpdatesMatchingChapterOnly() {
    let first = Chapter(title: "第1章", content: "旧本文")
    let second = Chapter(title: "第2章", content: "変わらない")
    var doc = NovelDocument(title: "テスト作品", chapters: [first, second])

    doc.updateContent("新本文", for: first.id)

    #expect(doc.chapters[0].content == "新本文")
    #expect(doc.chapters[1].content == "変わらない")
}

@Test func updateContentIgnoresUnknownChapterID() {
    let chapter = Chapter(title: "第1章", content: "本文")
    var doc = NovelDocument(title: "テスト作品", chapters: [chapter])

    doc.updateContent("書き換え", for: ChapterID())

    #expect(doc.chapters == [chapter])
}

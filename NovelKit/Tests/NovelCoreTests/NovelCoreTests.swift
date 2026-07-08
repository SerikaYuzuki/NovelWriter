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
    #expect(chapter.memo.isEmpty)
    #expect(chapter.title == "第1章")
}

@Test func chapterDecodesMissingMemoAsEmptyString() throws {
    let id = ChapterID()
    let json = """
    {
      "id": {"rawValue": "\(id.rawValue.uuidString)"},
      "title": "第1章",
      "content": "本文"
    }
    """

    let decoded = try JSONDecoder().decode(Chapter.self, from: Data(json.utf8))

    #expect(decoded.id == id)
    #expect(decoded.title == "第1章")
    #expect(decoded.content == "本文")
    #expect(decoded.memo == "")
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
        chapters: [Chapter(title: "第1章", content: "本文")],
        characters: [NovelCore.Character(name: "灯", kana: "あかり", memo: "主人公", colorHex: "#C44536")],
        plotCards: [PlotCard(title: "出会い", memo: "導入")]
    )
    let data = try JSONEncoder().encode(doc)
    let decoded = try JSONDecoder().decode(NovelDocument.self, from: data)
    #expect(decoded == doc)
}

@Test func novelDocumentDecodesMissingCharactersAsEmptyArray() throws {
    let chapterID = ChapterID()
    let documentID = UUID()
    let json = """
    {
      "id": "\(documentID.uuidString)",
      "title": "旧形式",
      "chapters": [
        {
          "id": {"rawValue": "\(chapterID.rawValue.uuidString)"},
          "title": "第1章",
          "content": "本文"
        }
      ]
    }
    """

    let decoded = try JSONDecoder().decode(NovelDocument.self, from: Data(json.utf8))

    #expect(decoded.id == documentID)
    #expect(decoded.characters.isEmpty)
}

@Test func novelDocumentDecodesMissingPlotCardsAsEmptyArray() throws {
    let chapterID = ChapterID()
    let documentID = UUID()
    let json = """
    {
      "id": "\(documentID.uuidString)",
      "title": "旧形式",
      "chapters": [
        {
          "id": {"rawValue": "\(chapterID.rawValue.uuidString)"},
          "title": "第1章",
          "content": "本文"
        }
      ]
    }
    """

    let decoded = try JSONDecoder().decode(NovelDocument.self, from: Data(json.utf8))

    #expect(decoded.id == documentID)
    #expect(decoded.plotCards.isEmpty)
}

// MARK: - addChapter / moveChapters / updateContent (docs/DESIGN.md 5.2)

@Test func addChapterAppendsToEndAndReturnsItsID() {
    var doc = NovelDocument(title: "テスト作品", chapters: [Chapter(title: "第1章")])
    let newID = doc.addChapter(title: "第2章")

    #expect(doc.chapters.count == 2)
    #expect(doc.chapters.last?.id == newID)
    #expect(doc.chapters.last?.title == "第2章")
    #expect(doc.chapters.last?.content.isEmpty == true)
    #expect(doc.chapters.last?.memo.isEmpty == true)
}

@Test func updateTitleUpdatesMatchingChapterOnly() {
    let first = Chapter(title: "旧タイトル", content: "本文")
    let second = Chapter(title: "変わらない", content: "本文2")
    var doc = NovelDocument(title: "テスト作品", chapters: [first, second])

    doc.updateTitle("新タイトル", for: first.id)

    #expect(doc.chapters[0].title == "新タイトル")
    #expect(doc.chapters[1].title == "変わらない")
}

@Test func updateTitleIgnoresUnknownChapterID() {
    let chapter = Chapter(title: "第1章", content: "本文")
    var doc = NovelDocument(title: "テスト作品", chapters: [chapter])

    doc.updateTitle("書き換え", for: ChapterID())

    #expect(doc.chapters == [chapter])
}

@Test func removeChapterDeletesMatchingChapterAndReportsOriginalIndex() throws {
    let first = Chapter(title: "第1章")
    let second = Chapter(title: "第2章")
    let third = Chapter(title: "第3章")
    var doc = NovelDocument(title: "テスト作品", chapters: [first, second, third])

    let removedResult = doc.removeChapter(id: second.id)
    let removed = try #require(removedResult)

    #expect(removed.chapter == second)
    #expect(removed.index == 1)
    #expect(doc.chapters.map(\.id) == [first.id, third.id])
}

@Test func removeChapterIgnoresUnknownChapterID() {
    let chapter = Chapter(title: "第1章")
    var doc = NovelDocument(title: "テスト作品", chapters: [chapter])

    let removed = doc.removeChapter(id: ChapterID())

    #expect(removed == nil)
    #expect(doc.chapters == [chapter])
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

@Test func updateMemoUpdatesMatchingChapterOnly() {
    let first = Chapter(title: "第1章", content: "本文", memo: "旧メモ")
    let second = Chapter(title: "第2章", content: "本文2", memo: "変わらない")
    var doc = NovelDocument(title: "テスト作品", chapters: [first, second])

    doc.updateMemo("新メモ", for: first.id)

    #expect(doc.chapters[0].memo == "新メモ")
    #expect(doc.chapters[1].memo == "変わらない")
}

@Test func updateMemoIgnoresUnknownChapterID() {
    let chapter = Chapter(title: "第1章", content: "本文", memo: "メモ")
    var doc = NovelDocument(title: "テスト作品", chapters: [chapter])

    doc.updateMemo("書き換え", for: ChapterID())

    #expect(doc.chapters == [chapter])
}

@Test func manuscriptCharacterCountExcludesNewlinesButIncludesSpaces() {
    let text = "abc\n　 d\r\n"

    #expect(ManuscriptMetrics.countCharacters(in: text) == 6)
}

@Test func manuscriptCharacterCountTreatsEmojiAsOneCharacter() {
    #expect(ManuscriptMetrics.countCharacters(in: "😀\n👨‍👩‍👧‍👦") == 2)
}

@Test func novelDocumentManuscriptCharacterCountSumsChapterContentOnly() {
    let doc = NovelDocument(
        title: "文字数テスト",
        chapters: [
            Chapter(title: "第1章", content: "本文\nA", memo: "メモは数えない"),
            Chapter(title: "第2章", content: "😀")
        ]
    )

    #expect(doc.manuscriptCharacterCount == 4)
}

@Test func manuscriptPages400RoundsUp() {
    #expect(ManuscriptMetrics.manuscriptPages400(for: 0) == 0)
    #expect(ManuscriptMetrics.manuscriptPages400(for: 1) == 1)
    #expect(ManuscriptMetrics.manuscriptPages400(for: 400) == 1)
    #expect(ManuscriptMetrics.manuscriptPages400(for: 401) == 2)
}

// MARK: - characters

@Test func characterIDGeneratesUniqueValues() {
    let firstID = CharacterID()
    let secondID = CharacterID()
    #expect(firstID != secondID)
}

@Test func addCharacterAppendsToEndAndNormalizesEmptyName() {
    var doc = NovelDocument(title: "人物テスト", chapters: [Chapter(title: "第1章")])

    let newID = doc.addCharacter(name: " \n ", kana: "ななし", memo: "メモ", colorHex: "#1565C0")

    #expect(doc.characters.count == 1)
    #expect(doc.characters[0].id == newID)
    #expect(doc.characters[0].name == "名無し")
    #expect(doc.characters[0].kana == "ななし")
    #expect(doc.characters[0].memo == "メモ")
    #expect(doc.characters[0].colorHex == "#1565C0")
}

@Test func updateCharacterUpdatesMatchingCharacterOnly() {
    let first = NovelCore.Character(name: "旧名", kana: "きゅうめい", memo: "旧メモ")
    let second = NovelCore.Character(name: "変わらない")
    var doc = NovelDocument(title: "人物テスト", chapters: [Chapter(title: "第1章")], characters: [first, second])

    doc.updateCharacter(id: first.id, name: "新名", kana: "しんめい", memo: "新メモ", colorHex: "#2E7D32")

    #expect(doc.characters[0].name == "新名")
    #expect(doc.characters[0].kana == "しんめい")
    #expect(doc.characters[0].memo == "新メモ")
    #expect(doc.characters[0].colorHex == "#2E7D32")
    #expect(doc.characters[1] == second)
}

@Test func removeCharacterDeletesMatchingCharacterOnly() {
    let first = NovelCore.Character(name: "残る")
    let second = NovelCore.Character(name: "消す")
    var doc = NovelDocument(title: "人物テスト", chapters: [Chapter(title: "第1章")], characters: [first, second])

    let removed = doc.removeCharacter(id: second.id)

    #expect(removed == second)
    #expect(doc.characters == [first])
}

@Test func moveCharactersReordersLikeSwiftUIOnMove() {
    let first = NovelCore.Character(name: "A")
    let second = NovelCore.Character(name: "B")
    let third = NovelCore.Character(name: "C")
    var doc = NovelDocument(title: "人物テスト", chapters: [Chapter(title: "第1章")], characters: [first, second, third])

    doc.moveCharacters(fromOffsets: IndexSet(integer: 0), toOffset: 3)

    #expect(doc.characters.map(\.id) == [second.id, third.id, first.id])
}

// MARK: - plot cards

@Test func plotCardIDGeneratesUniqueValues() {
    let firstID = PlotCardID()
    let secondID = PlotCardID()
    #expect(firstID != secondID)
}

@Test func addPlotCardAppendsToEndAndNormalizesEmptyTitle() {
    let chapter = Chapter(title: "第1章")
    var doc = NovelDocument(title: "プロットテスト", chapters: [chapter])

    let newID = doc.addPlotCard(title: " \n ", memo: "メモ", chapterID: chapter.id)

    #expect(doc.plotCards.count == 1)
    #expect(doc.plotCards[0].id == newID)
    #expect(doc.plotCards[0].title == "無題のカード")
    #expect(doc.plotCards[0].memo == "メモ")
    #expect(doc.plotCards[0].chapterID == chapter.id)
}

@Test func updatePlotCardUpdatesMatchingCardOnly() {
    let chapter = Chapter(title: "第1章")
    let first = PlotCard(title: "旧カード")
    let second = PlotCard(title: "変わらない")
    var doc = NovelDocument(title: "プロットテスト", chapters: [chapter], plotCards: [first, second])

    doc.updatePlotCard(id: first.id, title: "新カード", memo: "新メモ", chapterID: chapter.id)

    #expect(doc.plotCards[0].title == "新カード")
    #expect(doc.plotCards[0].memo == "新メモ")
    #expect(doc.plotCards[0].chapterID == chapter.id)
    #expect(doc.plotCards[1] == second)
}

@Test func removePlotCardDeletesMatchingCardOnly() {
    let first = PlotCard(title: "残る")
    let second = PlotCard(title: "消す")
    var doc = NovelDocument(title: "プロットテスト", chapters: [Chapter(title: "第1章")], plotCards: [first, second])

    let removed = doc.removePlotCard(id: second.id)

    #expect(removed == second)
    #expect(doc.plotCards == [first])
}

@Test func movePlotCardsReordersLikeSwiftUIOnMove() {
    let first = PlotCard(title: "A")
    let second = PlotCard(title: "B")
    let third = PlotCard(title: "C")
    var doc = NovelDocument(title: "プロットテスト", chapters: [Chapter(title: "第1章")], plotCards: [first, second, third])

    doc.movePlotCards(fromOffsets: IndexSet(integer: 0), toOffset: 3)

    #expect(doc.plotCards.map(\.id) == [second.id, third.id, first.id])
}

@Test func removingChapterClearsPlotCardChapterLink() {
    let firstChapter = Chapter(title: "第1章")
    let secondChapter = Chapter(title: "第2章")
    let linkedCard = PlotCard(title: "紐付き", chapterID: firstChapter.id)
    let otherCard = PlotCard(title: "別章", chapterID: secondChapter.id)
    var doc = NovelDocument(
        title: "プロットテスト",
        chapters: [firstChapter, secondChapter],
        plotCards: [linkedCard, otherCard]
    )

    doc.removeChapter(id: firstChapter.id)

    #expect(doc.plotCards[0].chapterID == nil)
    #expect(doc.plotCards[1].chapterID == secondChapter.id)
}

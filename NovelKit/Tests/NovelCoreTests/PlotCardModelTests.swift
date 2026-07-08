import Foundation
import NovelCore
import Testing

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

@Test func movePlotCardMovesBetweenChapterLanesBeforeTarget() {
    let firstChapter = Chapter(title: "第1章")
    let secondChapter = Chapter(title: "第2章")
    let first = PlotCard(title: "A", chapterID: firstChapter.id)
    let second = PlotCard(title: "B", chapterID: secondChapter.id)
    let third = PlotCard(title: "C", chapterID: secondChapter.id)
    var doc = NovelDocument(
        title: "プロットテスト",
        chapters: [firstChapter, secondChapter],
        plotCards: [first, second, third]
    )

    doc.movePlotCard(id: first.id, toChapter: secondChapter.id, before: third.id)

    #expect(doc.plotCards.map(\.id) == [second.id, first.id, third.id])
    #expect(doc.plotCards[1].chapterID == secondChapter.id)
}

@Test func movePlotCardAppendsToEmptyUnassignedLane() {
    let chapter = Chapter(title: "第1章")
    let first = PlotCard(title: "A", chapterID: chapter.id)
    var doc = NovelDocument(title: "プロットテスト", chapters: [chapter], plotCards: [first])

    doc.movePlotCard(id: first.id, toChapter: nil)

    #expect(doc.plotCards == [PlotCard(id: first.id, title: "A", chapterID: nil)])
}

@Test func movePlotCardBeforeItselfOnlyUpdatesChapter() {
    let chapter = Chapter(title: "第1章")
    let first = PlotCard(title: "A")
    let second = PlotCard(title: "B")
    var doc = NovelDocument(title: "プロットテスト", chapters: [chapter], plotCards: [first, second])

    doc.movePlotCard(id: first.id, toChapter: chapter.id, before: first.id)

    #expect(doc.plotCards.map(\.id) == [first.id, second.id])
    #expect(doc.plotCards[0].chapterID == chapter.id)
}

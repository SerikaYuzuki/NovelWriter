import Foundation
@testable import NovelCore
import Testing

@Test func flagIDGeneratesUniqueValues() {
    let firstID = FlagID()
    let secondID = FlagID()
    #expect(firstID != secondID)
}

@Test func addFlagAppendsToEndAndNormalizesEmptyTitle() {
    let chapter = Chapter(title: "第1章")
    var doc = NovelDocument(title: "伏線テスト", chapters: [chapter])

    let newID = doc.addFlag(title: " \n ", note: "メモ", plantedChapterID: chapter.id)

    #expect(doc.flags.count == 1)
    #expect(doc.flags[0].id == newID)
    #expect(doc.flags[0].title == "無題の伏線")
    #expect(doc.flags[0].note == "メモ")
    #expect(doc.flags[0].isResolved == false)
    #expect(doc.flags[0].plantedChapterID == chapter.id)
}

@Test func updateFlagUpdatesMatchingFlagOnly() {
    let chapter = Chapter(title: "第1章")
    let first = Flag(title: "旧伏線")
    let second = Flag(title: "変わらない")
    var doc = NovelDocument(title: "伏線テスト", chapters: [chapter], flags: [first, second])

    var updated = first
    updated.title = "新伏線"
    updated.note = "新メモ"
    updated.isResolved = true
    updated.plantedChapterID = chapter.id
    updated.resolvedChapterID = chapter.id
    doc.updateFlag(updated)

    #expect(doc.flags[0].title == "新伏線")
    #expect(doc.flags[0].note == "新メモ")
    #expect(doc.flags[0].isResolved)
    #expect(doc.flags[0].plantedChapterID == chapter.id)
    #expect(doc.flags[0].resolvedChapterID == chapter.id)
    #expect(doc.flags[1] == second)
}

@Test func removeFlagDeletesMatchingFlagOnly() {
    let first = Flag(title: "残る")
    let second = Flag(title: "消す")
    var doc = NovelDocument(title: "伏線テスト", chapters: [Chapter(title: "第1章")], flags: [first, second])

    let removed = doc.removeFlag(id: second.id)

    #expect(removed == second)
    #expect(doc.flags == [first])
}

@Test func moveFlagsReordersLikeSwiftUIOnMove() {
    let first = Flag(title: "A")
    let second = Flag(title: "B")
    let third = Flag(title: "C")
    var doc = NovelDocument(title: "伏線テスト", chapters: [Chapter(title: "第1章")], flags: [first, second, third])

    doc.moveFlags(fromOffsets: IndexSet(integer: 0), toOffset: 3)

    #expect(doc.flags.map(\.id) == [second.id, third.id, first.id])
}

@Test func removingChapterClearsFlagChapterLinks() {
    let firstChapter = Chapter(title: "第1章")
    let secondChapter = Chapter(title: "第2章")
    let linkedFlag = Flag(
        title: "両方",
        isResolved: true,
        plantedChapterID: firstChapter.id,
        resolvedChapterID: firstChapter.id
    )
    let otherFlag = Flag(
        title: "別章",
        isResolved: true,
        plantedChapterID: secondChapter.id,
        resolvedChapterID: secondChapter.id
    )
    var doc = NovelDocument(
        title: "伏線テスト",
        chapters: [firstChapter, secondChapter],
        flags: [linkedFlag, otherFlag]
    )

    doc.removeChapter(id: firstChapter.id)

    #expect(doc.flags[0].plantedChapterID == nil)
    #expect(doc.flags[0].resolvedChapterID == nil)
    #expect(doc.flags[1].plantedChapterID == secondChapter.id)
    #expect(doc.flags[1].resolvedChapterID == secondChapter.id)
}

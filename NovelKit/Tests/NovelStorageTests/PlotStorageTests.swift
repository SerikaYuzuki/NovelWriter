import Foundation
import NovelCore
@testable import NovelStorage
import Testing

@Test func plotCardsPersistInArrayOrderAfterSave() async throws {
    let tempDir = try makeTempDirectory()
    defer { try? FileManager.default.removeItem(at: tempDir) }

    let packageURL = tempDir.appendingPathComponent("PlotCards.novelpkg")
    let repository = NovelpkgRepository()
    let chapter = Chapter(title: "第1章")

    var doc = NovelDocument(
        title: "プロット保存テスト",
        chapters: [chapter],
        plotCards: [
            PlotCard(title: "A", chapterID: chapter.id),
            PlotCard(title: "B"),
            PlotCard(title: "C")
        ]
    )

    try await repository.save(doc, to: packageURL)
    doc.plotCards.swapAt(0, 2)
    try await repository.save(doc, to: packageURL)

    let loaded = try await repository.load(from: packageURL)
    #expect(loaded.plotCards.map(\.title) == ["C", "B", "A"])
    #expect(loaded.plotCards.last?.chapterID == chapter.id)
}

@Test func loadingPlotCardsClearsInvalidChapterReference() async throws {
    let tempDir = try makeTempDirectory()
    defer { try? FileManager.default.removeItem(at: tempDir) }

    let packageURL = tempDir.appendingPathComponent("InvalidPlotReference.novelpkg")
    let repository = NovelpkgRepository()
    let invalidChapterID = ChapterID()
    let doc = NovelDocument(
        title: "プロット参照矯正テスト",
        chapters: [Chapter(title: "第1章")],
        plotCards: [PlotCard(title: "孤立カード", chapterID: invalidChapterID)]
    )

    try await repository.save(doc, to: packageURL)

    let loaded = try await repository.load(from: packageURL)
    #expect(loaded.plotCards.count == 1)
    #expect(loaded.plotCards[0].chapterID == nil)
}

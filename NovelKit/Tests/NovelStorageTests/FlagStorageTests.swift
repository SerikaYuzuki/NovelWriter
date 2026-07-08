import Foundation
import NovelCore
@testable import NovelStorage
import Testing

@Test func flagsPersistInArrayOrderAfterSave() async throws {
    let tempDir = try makeTempDirectory()
    defer { try? FileManager.default.removeItem(at: tempDir) }

    let packageURL = tempDir.appendingPathComponent("Flags.novelpkg")
    let repository = NovelpkgRepository()
    let chapter = Chapter(title: "第1章")

    var doc = NovelDocument(
        title: "伏線保存テスト",
        chapters: [chapter],
        flags: [
            Flag(title: "A", plantedChapterID: chapter.id),
            Flag(title: "B"),
            Flag(title: "C", isResolved: true, resolvedChapterID: chapter.id)
        ]
    )

    try await repository.save(doc, to: packageURL)
    doc.flags.swapAt(0, 2)
    try await repository.save(doc, to: packageURL)

    let loaded = try await repository.load(from: packageURL)
    #expect(loaded.flags.map(\.title) == ["C", "B", "A"])
    #expect(loaded.flags[0].resolvedChapterID == chapter.id)
    #expect(loaded.flags[2].plantedChapterID == chapter.id)
}

@Test func loadingFlagsClearsInvalidChapterReferences() async throws {
    let tempDir = try makeTempDirectory()
    defer { try? FileManager.default.removeItem(at: tempDir) }

    let packageURL = tempDir.appendingPathComponent("InvalidFlagReferences.novelpkg")
    let repository = NovelpkgRepository()
    let invalidPlantedChapterID = ChapterID()
    let invalidResolvedChapterID = ChapterID()
    let doc = NovelDocument(
        title: "伏線参照矯正テスト",
        chapters: [Chapter(title: "第1章")],
        flags: [
            Flag(
                title: "孤立伏線",
                isResolved: true,
                plantedChapterID: invalidPlantedChapterID,
                resolvedChapterID: invalidResolvedChapterID
            )
        ]
    )

    try await repository.save(doc, to: packageURL)

    let loaded = try await repository.load(from: packageURL)
    #expect(loaded.flags.count == 1)
    #expect(loaded.flags[0].plantedChapterID == nil)
    #expect(loaded.flags[0].resolvedChapterID == nil)
}

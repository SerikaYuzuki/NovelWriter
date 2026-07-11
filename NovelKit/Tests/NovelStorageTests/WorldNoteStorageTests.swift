import Foundation
import NovelCore
@testable import NovelStorage
import Testing

@Test func worldNotesRoundTripInDedicatedMetadataAndContentFiles() async throws {
    let tempDir = try makeTempDirectory()
    defer { try? FileManager.default.removeItem(at: tempDir) }

    let packageURL = tempDir.appendingPathComponent("World.novelpkg")
    let repository = NovelpkgRepository()
    let notes = [
        WorldNote(title: "魔法体系", content: "月光を媒介にする。"),
        WorldNote(title: "年表", content: "暦元1年に建国。")
    ]
    let document = NovelDocument(
        title: "世界観テスト",
        chapters: [Chapter(title: "第1章")],
        worldNotes: notes
    )

    try await repository.save(document, to: packageURL)

    let metadata = try #require(
        try JSONSerialization.jsonObject(
            with: Data(contentsOf: packageURL.appendingPathComponent("world.json"))
        ) as? [String: Any]
    )
    let entries = try #require(metadata["notes"] as? [[String: Any]])
    #expect(entries.map { $0["title"] as? String } == notes.map(\.title))
    for note in notes {
        let contentURL = packageURL
            .appendingPathComponent("world-notes", isDirectory: true)
            .appendingPathComponent("\(note.id.rawValue.uuidString).md")
        #expect(try String(contentsOf: contentURL, encoding: .utf8) == note.content)
    }
    #expect(try await repository.load(from: packageURL).worldNotes == notes)
    #expect(try manifestJSON(at: packageURL)["formatVersion"] as? String == "3")
}

@Test func emptyWorldNotesOmitWorldMetadataAndContentDirectory() async throws {
    let tempDir = try makeTempDirectory()
    defer { try? FileManager.default.removeItem(at: tempDir) }

    let packageURL = tempDir.appendingPathComponent("EmptyWorld.novelpkg")
    let repository = NovelpkgRepository()
    var document = NovelDocument(
        title: "空の世界観",
        chapters: [Chapter(title: "第1章")],
        worldNotes: [WorldNote(title: "削除するノート", content: "本文")]
    )
    try await repository.save(document, to: packageURL)

    document.worldNotes = []
    try await repository.save(document, to: packageURL)

    #expect(!FileManager.default.fileExists(atPath: packageURL.appendingPathComponent("world.json").path))
    #expect(!FileManager.default.fileExists(
        atPath: packageURL.appendingPathComponent("world-notes", isDirectory: true).path
    ))
    #expect(try await repository.load(from: packageURL).worldNotes.isEmpty)
}

@Test func missingWorldMetadataLoadsAsEmptyWorldNotesForLegacyPackages() async throws {
    let tempDir = try makeTempDirectory()
    defer { try? FileManager.default.removeItem(at: tempDir) }

    let packageURL = tempDir.appendingPathComponent("LegacyWorld.novelpkg")
    let repository = NovelpkgRepository()
    let document = NovelDocument(title: "旧作品", chapters: [Chapter(title: "第1章")])
    try await repository.save(document, to: packageURL)

    try convertPackageToVersionTwo(at: packageURL, chapterIDs: document.chapters.map(\.id))
    var loaded = try await repository.load(from: packageURL)
    #expect(loaded.worldNotes.isEmpty)
    try await repository.save(loaded, to: packageURL)
    #expect(try manifestJSON(at: packageURL)["formatVersion"] as? String == "3")
    #expect(!FileManager.default.fileExists(atPath: packageURL.appendingPathComponent("world.json").path))

    try convertPackageToVersionOne(at: packageURL, chapterIDs: loaded.chapters.map(\.id))
    loaded = try await repository.load(from: packageURL)
    #expect(loaded.worldNotes.isEmpty)
    try await repository.save(loaded, to: packageURL)
    #expect(try manifestJSON(at: packageURL)["formatVersion"] as? String == "3")
    #expect(!FileManager.default.fileExists(atPath: packageURL.appendingPathComponent("world.json").path))
}

@Test func worldNotesArePreservedBySnapshotRestoreAndSaveCopy() async throws {
    let tempDir = try makeTempDirectory()
    defer { try? FileManager.default.removeItem(at: tempDir) }

    let sourceURL = tempDir.appendingPathComponent("Source.novelpkg")
    let destinationURL = tempDir.appendingPathComponent("Destination.novelpkg")
    let repository = NovelpkgRepository()
    var document = NovelDocument(
        title: "保存経路テスト",
        chapters: [Chapter(title: "第1章")],
        worldNotes: [WorldNote(title: "初版", content: "スナップショット本文")]
    )
    try await repository.save(document, to: sourceURL)
    let snapshotURL = try await repository.saveSnapshot(document, to: sourceURL)

    document.worldNotes = [WorldNote(title: "改訂版", content: "別名保存本文")]
    try await repository.save(document, to: sourceURL)
    try await repository.saveCopy(document, from: sourceURL, to: destinationURL)
    #expect(try await repository.load(from: destinationURL).worldNotes == document.worldNotes)

    try await repository.restoreSnapshot(from: snapshotURL, into: sourceURL)
    #expect(try await repository.load(from: sourceURL).worldNotes.map(\.title) == ["初版"])
    #expect(try await repository.load(from: sourceURL).worldNotes.map(\.content) == ["スナップショット本文"])
}

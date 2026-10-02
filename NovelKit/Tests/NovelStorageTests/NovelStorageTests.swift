import Foundation
import NovelCore
@testable import NovelStorage
import Testing

// `NovelpkgRepository` に対するテスト(docs/DESIGN.md 4.2, 6.4)。

/// `FileManager.default.temporaryDirectory` 配下に、このテスト実行専用の
/// 一意なディレクトリを作成する。呼び出し側は `defer` で後始末すること。
func makeTempDirectory() throws -> URL {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("NovelStorageTests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

/// `manifest.json` を JSON として読み込む。`SnapshotStorageTests.swift` からも
/// 参照するため internal のままにする(同一テストターゲット内)。
func manifestJSON(at packageURL: URL) throws -> [String: Any] {
    let manifestURL = packageURL.appendingPathComponent("manifest.json")
    let data = try Data(contentsOf: manifestURL)
    return try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
}

@Test func saveAndLoadRoundTrip() async throws {
    let tempDir = try makeTempDirectory()
    defer { try? FileManager.default.removeItem(at: tempDir) }

    let packageURL = tempDir.appendingPathComponent("MyNovel.novelpkg")
    let repository = NovelpkgRepository()

    let doc = NovelDocument(
        title: "ラウンドトリップ作品",
        chapters: [
            Chapter(title: "第1章", content: "本文1", memo: "メモ1"),
            Chapter(title: "第2章", content: "本文2")
        ],
        characters: [
            NovelCore.Character(name: "灯", kana: "あかり", memo: "主人公", colorHex: "#C44536"),
            NovelCore.Character(name: "澪", kana: "みお", memo: "相棒")
        ],
        plotCards: [
            PlotCard(title: "開幕", memo: "導入", chapterID: nil)
        ],
        flags: [
            Flag(title: "鍵", note: "後で回収", plantedChapterID: nil)
        ]
    )

    try await repository.save(doc, to: packageURL)
    let loaded = try await repository.load(from: packageURL)
    let manifest = try manifestJSON(at: packageURL)

    #expect(manifest["formatVersion"] as? String == "3")
    #expect(loaded.id == doc.id)
    #expect(loaded.title == doc.title)
    #expect(loaded.chapters.map { $0.id } == doc.chapters.map { $0.id })
    #expect(loaded.chapters.map { $0.title } == doc.chapters.map { $0.title })
    #expect(loaded.chapters.map { $0.episodes } == doc.chapters.map { $0.episodes })
    #expect(loaded.chapters.map { $0.episodes.map { $0.title } } == doc.chapters.map { $0.episodes.map { $0.title } })
    #expect(loaded.characters == doc.characters)
    #expect(loaded.plotCards == doc.plotCards)
    #expect(loaded.flags == doc.flags)
}

@Test func saveAndLoadPreservesEpisodeOrderAndMetadata() async throws {
    let tempDir = try makeTempDirectory()
    defer { try? FileManager.default.removeItem(at: tempDir) }

    let packageURL = tempDir.appendingPathComponent("Episodes.novelpkg")
    let repository = NovelpkgRepository()
    let chapter = Chapter(
        title: "第1章",
        episodes: [
            Episode(title: "第1話", content: "最初"),
            Episode(title: "第2話", content: "次", memo: "次の展開")
        ]
    )
    let doc = NovelDocument(title: "話順テスト", chapters: [chapter])

    try await repository.save(doc, to: packageURL)
    let loaded = try await repository.load(from: packageURL)
    let manifest = try manifestJSON(at: packageURL)
    let manifestChapters = try #require(manifest["chapters"] as? [[String: Any]])
    let manifestEpisodes = try #require(manifestChapters[0]["episodes"] as? [[String: Any]])

    #expect(manifestEpisodes.count == 2)
    #expect(manifestEpisodes.map { $0["title"] as? String } == ["第1話", "第2話"])
    #expect(loaded.chapters[0].episodes == chapter.episodes)
    #expect(
        FileManager.default.fileExists(
            atPath: packageURL
                .appendingPathComponent("episode-notes", isDirectory: true)
                .appendingPathComponent("\(chapter.episodes[1].id.rawValue.uuidString).md")
                .path
        )
    )
}

@Test func emptyChapterMemoDoesNotCreateNoteFile() async throws {
    let tempDir = try makeTempDirectory()
    defer { try? FileManager.default.removeItem(at: tempDir) }

    let packageURL = tempDir.appendingPathComponent("EmptyMemo.novelpkg")
    let repository = NovelpkgRepository()
    let chapter = Chapter(title: "第1章", content: "本文", memo: "")
    let doc = NovelDocument(title: "空メモテスト", chapters: [chapter])

    try await repository.save(doc, to: packageURL)

    let episodeID = try #require(chapter.episodes.first?.id)
    let noteURL = packageURL
        .appendingPathComponent("episode-notes", isDirectory: true)
        .appendingPathComponent("\(episodeID.rawValue.uuidString).md")
    #expect(!FileManager.default.fileExists(atPath: noteURL.path))
}

@Test func clearingChapterMemoRemovesExistingNoteFileOnSave() async throws {
    let tempDir = try makeTempDirectory()
    defer { try? FileManager.default.removeItem(at: tempDir) }

    let packageURL = tempDir.appendingPathComponent("ClearMemo.novelpkg")
    let repository = NovelpkgRepository()
    var doc = NovelDocument(title: "メモ削除テスト", chapters: [Chapter(title: "第1章", memo: "残さない")])

    try await repository.save(doc, to: packageURL)
    doc.chapters[0].episodes[0].memo = ""
    try await repository.save(doc, to: packageURL)

    let notesURL = packageURL.appendingPathComponent("episode-notes", isDirectory: true)
    let episodeID = try #require(doc.chapters[0].episodes.first?.id)
    let noteURL = notesURL.appendingPathComponent("\(episodeID.rawValue.uuidString).md")
    #expect(!FileManager.default.fileExists(atPath: noteURL.path))
}

@Test func reorderingChaptersPersistsAfterSave() async throws {
    let tempDir = try makeTempDirectory()
    defer { try? FileManager.default.removeItem(at: tempDir) }

    let packageURL = tempDir.appendingPathComponent("Reorder.novelpkg")
    let repository = NovelpkgRepository()

    var doc = NovelDocument(
        title: "並べ替えテスト",
        chapters: [
            Chapter(title: "第1章", content: "A"),
            Chapter(title: "第2章", content: "B"),
            Chapter(title: "第3章", content: "C")
        ]
    )
    try await repository.save(doc, to: packageURL)

    // 章を並べ替えてから再保存する(第3章, 第2章, 第1章の順に)
    doc.chapters.swapAt(0, 2)
    try await repository.save(doc, to: packageURL)

    let loaded = try await repository.load(from: packageURL)
    #expect(loaded.chapters.map { $0.title } == ["第3章", "第2章", "第1章"])
    #expect(loaded.chapters.compactMap { $0.episodes.first?.content } == ["C", "B", "A"])
}

@Test func charactersPersistInArrayOrderAfterSave() async throws {
    let tempDir = try makeTempDirectory()
    defer { try? FileManager.default.removeItem(at: tempDir) }

    let packageURL = tempDir.appendingPathComponent("Characters.novelpkg")
    let repository = NovelpkgRepository()

    var doc = NovelDocument(
        title: "人物保存テスト",
        chapters: [Chapter(title: "第1章")],
        characters: [
            NovelCore.Character(name: "A"),
            NovelCore.Character(name: "B"),
            NovelCore.Character(name: "C")
        ]
    )

    try await repository.save(doc, to: packageURL)
    doc.characters.swapAt(0, 2)
    try await repository.save(doc, to: packageURL)

    let loaded = try await repository.load(from: packageURL)
    #expect(loaded.characters.map { $0.name } == ["C", "B", "A"])
}

@Test func overwriteSavePreservesAttachments() async throws {
    let tempDir = try makeTempDirectory()
    defer { try? FileManager.default.removeItem(at: tempDir) }

    let packageURL = tempDir.appendingPathComponent("WithAttachments.novelpkg")
    let repository = NovelpkgRepository()

    let doc = NovelDocument(title: "添付テスト", chapters: [Chapter(title: "第1章", content: "本文")])
    try await repository.save(doc, to: packageURL)

    // 保存済みパッケージの attachments/ に、手動でダミーファイルを置く
    // (将来の添付機能を見据えたもの。上書き保存で消えてはならない)
    let attachmentsURL = packageURL.appendingPathComponent("attachments", isDirectory: true)
    let dummyFileURL = attachmentsURL.appendingPathComponent("memo.txt")
    try "dummy".write(to: dummyFileURL, atomically: true, encoding: .utf8)

    var updatedDoc = doc
    updatedDoc.chapters[0].episodes[0].content = "更新後の本文"
    try await repository.save(updatedDoc, to: packageURL)

    #expect(FileManager.default.fileExists(atPath: dummyFileURL.path))
    let dummyContent = try String(contentsOf: dummyFileURL, encoding: .utf8)
    #expect(dummyContent == "dummy")

    let loaded = try await repository.load(from: packageURL)
    #expect(loaded.chapters[0].episodes[0].content == "更新後の本文")
}

@Test func overwriteSavePreservesUnknownRootItems() async throws {
    let tempDir = try makeTempDirectory()
    defer { try? FileManager.default.removeItem(at: tempDir) }

    let packageURL = tempDir.appendingPathComponent("UnknownRootItems.novelpkg")
    let repository = NovelpkgRepository()
    let doc = NovelDocument(title: "未知ファイル保持テスト", chapters: [Chapter(title: "第1章")])

    try await repository.save(doc, to: packageURL)

    let unknownFileURL = packageURL.appendingPathComponent("future-data.json")
    try #"{"kept":true}"#.write(to: unknownFileURL, atomically: true, encoding: .utf8)
    let unknownDirectoryURL = packageURL.appendingPathComponent("future", isDirectory: true)
    try FileManager.default.createDirectory(at: unknownDirectoryURL, withIntermediateDirectories: true)
    let nestedFileURL = unknownDirectoryURL.appendingPathComponent("payload.txt")
    try "payload".write(to: nestedFileURL, atomically: true, encoding: .utf8)

    var updatedDoc = doc
    updatedDoc.chapters[0].episodes[0].content = "更新"
    try await repository.save(updatedDoc, to: packageURL)

    #expect(FileManager.default.fileExists(atPath: unknownFileURL.path))
    #expect(FileManager.default.fileExists(atPath: nestedFileURL.path))
    #expect(try String(contentsOf: nestedFileURL, encoding: .utf8) == "payload")
}

@Test(arguments: ["1", "2", "99"])
func unsupportedPackageVersionIsRejectedWithoutChangingSource(version: String) async throws {
    let tempDir = try makeTempDirectory()
    defer { try? FileManager.default.removeItem(at: tempDir) }
    let packageURL = tempDir.appendingPathComponent("Unsupported.novelpkg")
    let repository = NovelpkgRepository()
    try await repository.save(NovelDocument.newDocument(), to: packageURL)
    var manifest = try manifestJSON(at: packageURL)
    manifest["formatVersion"] = version
    let bytes = try JSONSerialization.data(withJSONObject: manifest)
    let url = packageURL.appendingPathComponent("manifest.json")
    try bytes.write(to: url)
    await #expect(throws: NovelpkgError.unsupportedFormatVersion(version)) {
        _ = try await repository.load(from: packageURL)
    }
    #expect(try Data(contentsOf: url) == bytes)
}

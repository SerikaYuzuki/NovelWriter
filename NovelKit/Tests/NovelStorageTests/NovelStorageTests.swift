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

private func manifestJSON(at packageURL: URL) throws -> [String: Any] {
    let manifestURL = packageURL.appendingPathComponent("manifest.json")
    let data = try Data(contentsOf: manifestURL)
    return try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
}

private func rewriteManifestFormatVersion(_ formatVersion: String, at packageURL: URL) throws {
    let manifestURL = packageURL.appendingPathComponent("manifest.json")
    let data = try Data(contentsOf: manifestURL)
    var json = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
    json["formatVersion"] = formatVersion
    let rewritten = try JSONSerialization.data(withJSONObject: json)
    try rewritten.write(to: manifestURL)
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

    #expect(manifest["formatVersion"] as? String == "2")
    #expect(loaded.id == doc.id)
    #expect(loaded.title == doc.title)
    #expect(loaded.chapters.map(\.id) == doc.chapters.map(\.id))
    #expect(loaded.chapters.map(\.title) == doc.chapters.map(\.title))
    #expect(loaded.chapters.map(\.content) == doc.chapters.map(\.content))
    #expect(loaded.chapters.map(\.memo) == doc.chapters.map(\.memo))
    #expect(loaded.characters == doc.characters)
    #expect(loaded.plotCards == doc.plotCards)
    #expect(loaded.flags == doc.flags)
}

@Test func emptyChapterMemoDoesNotCreateNoteFile() async throws {
    let tempDir = try makeTempDirectory()
    defer { try? FileManager.default.removeItem(at: tempDir) }

    let packageURL = tempDir.appendingPathComponent("EmptyMemo.novelpkg")
    let repository = NovelpkgRepository()
    let chapter = Chapter(title: "第1章", content: "本文", memo: "")
    let doc = NovelDocument(title: "空メモテスト", chapters: [chapter])

    try await repository.save(doc, to: packageURL)

    let noteURL = packageURL
        .appendingPathComponent("notes", isDirectory: true)
        .appendingPathComponent("\(chapter.id.rawValue.uuidString).md")
    #expect(!FileManager.default.fileExists(atPath: noteURL.path))
}

@Test func clearingChapterMemoRemovesExistingNoteFileOnSave() async throws {
    let tempDir = try makeTempDirectory()
    defer { try? FileManager.default.removeItem(at: tempDir) }

    let packageURL = tempDir.appendingPathComponent("ClearMemo.novelpkg")
    let repository = NovelpkgRepository()
    var doc = NovelDocument(title: "メモ削除テスト", chapters: [Chapter(title: "第1章", memo: "残さない")])

    try await repository.save(doc, to: packageURL)
    doc.chapters[0].memo = ""
    try await repository.save(doc, to: packageURL)

    let notesURL = packageURL.appendingPathComponent("notes", isDirectory: true)
    let noteURL = notesURL.appendingPathComponent("\(doc.chapters[0].id.rawValue.uuidString).md")
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
    #expect(loaded.chapters.map(\.title) == ["第3章", "第2章", "第1章"])
    #expect(loaded.chapters.map(\.content) == ["C", "B", "A"])
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
    #expect(loaded.characters.map(\.name) == ["C", "B", "A"])
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
    updatedDoc.chapters[0].content = "更新後の本文"
    try await repository.save(updatedDoc, to: packageURL)

    #expect(FileManager.default.fileExists(atPath: dummyFileURL.path))
    let dummyContent = try String(contentsOf: dummyFileURL, encoding: .utf8)
    #expect(dummyContent == "dummy")

    let loaded = try await repository.load(from: packageURL)
    #expect(loaded.chapters[0].content == "更新後の本文")
}

@Test func saveSnapshotCreatesLoadablePackage() async throws {
    let tempDir = try makeTempDirectory()
    defer { try? FileManager.default.removeItem(at: tempDir) }

    let packageURL = tempDir.appendingPathComponent("SnapshotSource.novelpkg")
    let repository = NovelpkgRepository()
    let doc = NovelDocument(title: "退避テスト", chapters: [Chapter(title: "第1章", content: "本文")])

    try await repository.save(doc, to: packageURL)
    let snapshotURL = try await repository.saveSnapshot(doc, to: packageURL)

    #expect(FileManager.default.fileExists(atPath: snapshotURL.path))
    let loadedSnapshot = try await repository.load(from: snapshotURL)
    #expect(loadedSnapshot == doc)
}

@Test func overwriteSavePreservesSnapshots() async throws {
    let tempDir = try makeTempDirectory()
    defer { try? FileManager.default.removeItem(at: tempDir) }

    let packageURL = tempDir.appendingPathComponent("SnapshotPreserve.novelpkg")
    let repository = NovelpkgRepository()
    var doc = NovelDocument(title: "退避保持テスト", chapters: [Chapter(title: "第1章", content: "初版")])

    try await repository.save(doc, to: packageURL)
    let snapshotURL = try await repository.saveSnapshot(doc, to: packageURL)

    doc.chapters[0].content = "更新版"
    try await repository.save(doc, to: packageURL)

    #expect(FileManager.default.fileExists(atPath: snapshotURL.path))
    let loadedSnapshot = try await repository.load(from: snapshotURL)
    #expect(loadedSnapshot.chapters[0].content == "初版")
    let loadedCurrent = try await repository.load(from: packageURL)
    #expect(loadedCurrent.chapters[0].content == "更新版")
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
    updatedDoc.chapters[0].content = "更新"
    try await repository.save(updatedDoc, to: packageURL)

    #expect(FileManager.default.fileExists(atPath: unknownFileURL.path))
    #expect(FileManager.default.fileExists(atPath: nestedFileURL.path))
    #expect(try String(contentsOf: nestedFileURL, encoding: .utf8) == "payload")
}

@Test func versionOnePackageLoadsAndMigratesToVersionTwoOnSave() async throws {
    let tempDir = try makeTempDirectory()
    defer { try? FileManager.default.removeItem(at: tempDir) }

    let packageURL = tempDir.appendingPathComponent("V1Migration.novelpkg")
    let repository = NovelpkgRepository()
    let doc = NovelDocument(title: "移行テスト", chapters: [Chapter(title: "第1章", content: "本文")])

    try await repository.save(doc, to: packageURL)
    let attachmentsURL = packageURL.appendingPathComponent("attachments", isDirectory: true)
    let attachmentURL = attachmentsURL.appendingPathComponent("memo.txt")
    try "attachment".write(to: attachmentURL, atomically: true, encoding: .utf8)
    let snapshotURL = try await repository.saveSnapshot(doc, to: packageURL)
    try rewriteManifestFormatVersion("1", at: packageURL)

    var loaded = try await repository.load(from: packageURL)
    #expect(loaded.chapters[0].memo == "")
    #expect(loaded.characters.isEmpty)
    #expect(loaded.plotCards.isEmpty)
    #expect(loaded.flags.isEmpty)
    loaded.chapters[0].memo = "移行後メモ"
    try await repository.save(loaded, to: packageURL)

    let manifest = try manifestJSON(at: packageURL)
    #expect(manifest["formatVersion"] as? String == "2")
    #expect(FileManager.default.fileExists(atPath: attachmentURL.path))
    #expect(FileManager.default.fileExists(atPath: snapshotURL.path))

    let reloaded = try await repository.load(from: packageURL)
    #expect(reloaded.chapters[0].content == "本文")
    #expect(reloaded.chapters[0].memo == "移行後メモ")
}

@Test func loadingPackageWithoutManifestThrowsTypedError() async throws {
    let tempDir = try makeTempDirectory()
    defer { try? FileManager.default.removeItem(at: tempDir) }

    let packageURL = tempDir.appendingPathComponent("NoManifest.novelpkg")
    try FileManager.default.createDirectory(at: packageURL, withIntermediateDirectories: true)

    let repository = NovelpkgRepository()
    do {
        _ = try await repository.load(from: packageURL)
        Issue.record("manifest.json が無いのに load が成功してしまった")
    } catch let error as NovelpkgError {
        #expect(error == .manifestMissing(packageURL))
    } catch {
        Issue.record("想定外のエラー型: \(error)")
    }
}

@Test func loadingNonexistentPackageThrowsTypedError() async throws {
    let tempDir = try makeTempDirectory()
    defer { try? FileManager.default.removeItem(at: tempDir) }

    let packageURL = tempDir.appendingPathComponent("DoesNotExist.novelpkg")
    let repository = NovelpkgRepository()

    do {
        _ = try await repository.load(from: packageURL)
        Issue.record("存在しないパッケージの load が成功してしまった")
    } catch let error as NovelpkgError {
        #expect(error == .packageNotFound(packageURL))
    } catch {
        Issue.record("想定外のエラー型: \(error)")
    }
}

@Test func missingChapterFileLoadsAsEmptyContent() async throws {
    let tempDir = try makeTempDirectory()
    defer { try? FileManager.default.removeItem(at: tempDir) }

    let packageURL = tempDir.appendingPathComponent("MissingChapterFile.novelpkg")
    let repository = NovelpkgRepository()

    let chapter = Chapter(title: "第1章", content: "消される本文")
    let doc = NovelDocument(title: "欠損テスト", chapters: [chapter])
    try await repository.save(doc, to: packageURL)

    // 章ファイルを直接削除して、章ファイルが欠けた破損状態を模す
    let chapterFileURL = packageURL
        .appendingPathComponent("chapters", isDirectory: true)
        .appendingPathComponent("\(chapter.id.rawValue.uuidString).md")
    try FileManager.default.removeItem(at: chapterFileURL)

    // 章ファイルが1つ欠けていても、読み込み全体は失敗せず、空本文として読める
    let loaded = try await repository.load(from: packageURL)
    #expect(loaded.chapters.count == 1)
    #expect(loaded.chapters[0].title == "第1章")
    #expect(loaded.chapters[0].content.isEmpty)
}

@Test func orphanChapterFileIsIgnoredButNotDeletedOnLoad() async throws {
    let tempDir = try makeTempDirectory()
    defer { try? FileManager.default.removeItem(at: tempDir) }

    let packageURL = tempDir.appendingPathComponent("Orphan.novelpkg")
    let repository = NovelpkgRepository()

    let doc = NovelDocument(title: "孤児章テスト", chapters: [Chapter(title: "第1章", content: "本文")])
    try await repository.save(doc, to: packageURL)

    // manifest.json に載っていない章ファイルを直接置く
    let chaptersURL = packageURL.appendingPathComponent("chapters", isDirectory: true)
    let orphanURL = chaptersURL.appendingPathComponent("\(UUID().uuidString).md")
    try "manifestに載っていない本文".write(to: orphanURL, atomically: true, encoding: .utf8)

    let loaded = try await repository.load(from: packageURL)
    #expect(loaded.chapters.count == 1)
    // 無視はするが、削除はしない
    #expect(FileManager.default.fileExists(atPath: orphanURL.path))
}

@Test func unsupportedFormatVersionThrowsTypedError() async throws {
    let tempDir = try makeTempDirectory()
    defer { try? FileManager.default.removeItem(at: tempDir) }

    let packageURL = tempDir.appendingPathComponent("FutureVersion.novelpkg")
    let repository = NovelpkgRepository()

    let doc = NovelDocument(title: "バージョンテスト", chapters: [Chapter(title: "第1章")])
    try await repository.save(doc, to: packageURL)

    // manifest.json の formatVersion を非対応の値に書き換える
    try rewriteManifestFormatVersion("999", at: packageURL)

    do {
        _ = try await repository.load(from: packageURL)
        Issue.record("非対応バージョンなのに load が成功してしまった")
    } catch let error as NovelpkgError {
        #expect(error == .unsupportedFormatVersion("999"))
    } catch {
        Issue.record("想定外のエラー型: \(error)")
    }
}

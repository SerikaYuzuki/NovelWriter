import Foundation
import NovelCore
@testable import NovelStorage
import Testing

@Test func loadingPackageWithoutManifestThrowsTypedError() async throws {
    let tempDir = try makeTempDirectory()
    defer { try? FileManager.default.removeItem(at: tempDir) }

    let packageURL = tempDir.appendingPathComponent("NoManifest.novelpkg")
    try FileManager.default.createDirectory(at: packageURL, withIntermediateDirectories: true)

    do {
        _ = try await NovelpkgRepository().load(from: packageURL)
        Issue.record("manifest.json が無いのに load が成功してしまった")
    } catch let error as NovelpkgError {
        #expect(error == .manifestMissing(packageURL))
    }
}

@Test func loadingNonexistentPackageThrowsTypedError() async throws {
    let tempDir = try makeTempDirectory()
    defer { try? FileManager.default.removeItem(at: tempDir) }

    let packageURL = tempDir.appendingPathComponent("DoesNotExist.novelpkg")
    do {
        _ = try await NovelpkgRepository().load(from: packageURL)
        Issue.record("存在しないパッケージの load が成功してしまった")
    } catch let error as NovelpkgError {
        #expect(error == .packageNotFound(packageURL))
    }
}

@Test func missingRequiredEpisodeFileThrowsTypedError() async throws {
    let tempDir = try makeTempDirectory()
    defer { try? FileManager.default.removeItem(at: tempDir) }

    let packageURL = tempDir.appendingPathComponent("MissingEpisodeFile.novelpkg")
    let repository = NovelpkgRepository()
    let episode = Episode(content: "消される本文")
    let chapter = Chapter(title: "第1章", episodes: [episode])
    try await repository.save(NovelDocument(title: "欠損テスト", chapters: [chapter]), to: packageURL)

    let episodeFileURL = packageURL
        .appendingPathComponent("episodes", isDirectory: true)
        .appendingPathComponent("\(episode.id.rawValue.uuidString).md")
    try FileManager.default.removeItem(at: episodeFileURL)

    do {
        _ = try await repository.load(from: packageURL)
        Issue.record("必須の話本文が無いのに load が成功してしまった")
    } catch let error as NovelpkgError {
        guard case let .payloadUnreadable(url, relativePath, reason) = error else {
            Issue.record("想定外のエラー: \(error)")
            return
        }
        #expect(url == packageURL)
        #expect(relativePath == "episodes/\(episode.id.rawValue.uuidString).md")
        #expect(reason == "必須ファイルが見つかりません")
    }
}

@Test func invalidUTF8EpisodeBodyThrowsTypedError() async throws {
    let tempDir = try makeTempDirectory()
    defer { try? FileManager.default.removeItem(at: tempDir) }

    let packageURL = tempDir.appendingPathComponent("InvalidBody.novelpkg")
    let repository = NovelpkgRepository()
    let episode = Episode(content: "置き換える本文")
    try await repository.save(
        NovelDocument(title: "不正UTF-8本文", chapters: [Chapter(title: "第1章", episodes: [episode])]),
        to: packageURL
    )

    let relativePath = "episodes/\(episode.id.rawValue.uuidString).md"
    try Data([0xFF, 0xFE, 0x80]).write(to: packageURL.appendingPathComponent(relativePath))

    do {
        _ = try await repository.load(from: packageURL)
        Issue.record("不正UTF-8の話本文を load できてしまった")
    } catch let error as NovelpkgError {
        guard case let .payloadUnreadable(url, path, reason) = error else {
            Issue.record("想定外のエラー: \(error)")
            return
        }
        #expect(url == packageURL)
        #expect(path == relativePath)
        #expect(reason == "UTF-8 として解釈できません")
    }
}

@Test func absentEpisodeMemoRemainsAnEmptyOptionalPayload() async throws {
    let tempDir = try makeTempDirectory()
    defer { try? FileManager.default.removeItem(at: tempDir) }

    let packageURL = tempDir.appendingPathComponent("AbsentMemo.novelpkg")
    let repository = NovelpkgRepository()
    let episode = Episode(content: "本文", memo: "")
    try await repository.save(
        NovelDocument(title: "省略メモ", chapters: [Chapter(title: "第1章", episodes: [episode])]),
        to: packageURL
    )

    let loaded = try await repository.load(from: packageURL)
    #expect(loaded.chapters[0].episodes[0].memo.isEmpty)
}

@Test func invalidUTF8ExistingEpisodeMemoThrowsTypedError() async throws {
    let tempDir = try makeTempDirectory()
    defer { try? FileManager.default.removeItem(at: tempDir) }

    let packageURL = tempDir.appendingPathComponent("InvalidMemo.novelpkg")
    let repository = NovelpkgRepository()
    let episode = Episode(content: "本文", memo: "置き換えるメモ")
    try await repository.save(
        NovelDocument(title: "不正UTF-8メモ", chapters: [Chapter(title: "第1章", episodes: [episode])]),
        to: packageURL
    )

    let relativePath = "episode-notes/\(episode.id.rawValue.uuidString).md"
    try Data([0xC3, 0x28]).write(to: packageURL.appendingPathComponent(relativePath))

    do {
        _ = try await repository.load(from: packageURL)
        Issue.record("存在する不正UTF-8メモを空として load してしまった")
    } catch let error as NovelpkgError {
        guard case let .payloadUnreadable(url, path, reason) = error else {
            Issue.record("想定外のエラー: \(error)")
            return
        }
        #expect(url == packageURL)
        #expect(path == relativePath)
        #expect(reason == "UTF-8 として解釈できません")
    }
}

@Test func unreadableExistingEpisodeMemoThrowsTypedError() async throws {
    let tempDir = try makeTempDirectory()
    defer { try? FileManager.default.removeItem(at: tempDir) }

    let packageURL = tempDir.appendingPathComponent("UnreadableMemo.novelpkg")
    let repository = NovelpkgRepository()
    let episode = Episode(content: "本文", memo: "置き換えるメモ")
    try await repository.save(
        NovelDocument(title: "読込不能メモ", chapters: [Chapter(title: "第1章", episodes: [episode])]),
        to: packageURL
    )

    let relativePath = "episode-notes/\(episode.id.rawValue.uuidString).md"
    let memoURL = packageURL.appendingPathComponent(relativePath)
    try FileManager.default.removeItem(at: memoURL)
    try FileManager.default.createDirectory(at: memoURL, withIntermediateDirectories: false)

    do {
        _ = try await repository.load(from: packageURL)
        Issue.record("読み込めない既存メモを空として load してしまった")
    } catch let error as NovelpkgError {
        guard case let .payloadUnreadable(url, path, reason) = error else {
            Issue.record("想定外のエラー: \(error)")
            return
        }
        #expect(url == packageURL)
        #expect(path == relativePath)
        #expect(!reason.isEmpty)
    }
}

@Test func orphanEpisodeFileIsIgnoredButNotDeletedOnLoad() async throws {
    let tempDir = try makeTempDirectory()
    defer { try? FileManager.default.removeItem(at: tempDir) }

    let packageURL = tempDir.appendingPathComponent("Orphan.novelpkg")
    let repository = NovelpkgRepository()
    let document = NovelDocument(title: "孤児話テスト", chapters: [Chapter(title: "第1章")])
    try await repository.save(document, to: packageURL)

    let episodesURL = packageURL.appendingPathComponent("episodes", isDirectory: true)
    let orphanURL = episodesURL.appendingPathComponent("\(UUID().uuidString).md")
    try "manifestに載っていない本文".write(to: orphanURL, atomically: true, encoding: .utf8)

    _ = try await repository.load(from: packageURL)
    #expect(FileManager.default.fileExists(atPath: orphanURL.path))
}

@Test func unsupportedFormatVersionThrowsTypedError() async throws {
    let tempDir = try makeTempDirectory()
    defer { try? FileManager.default.removeItem(at: tempDir) }

    let packageURL = tempDir.appendingPathComponent("FutureVersion.novelpkg")
    let repository = NovelpkgRepository()
    let document = NovelDocument(title: "バージョンテスト", chapters: [Chapter(title: "第1章")])
    try await repository.save(document, to: packageURL)
    try rewriteManifestFormatVersion("999", at: packageURL)

    do {
        _ = try await repository.load(from: packageURL)
        Issue.record("非対応バージョンなのに load が成功してしまった")
    } catch let error as NovelpkgError {
        #expect(error == .unsupportedFormatVersion("999"))
    }
}

private func rewriteManifestFormatVersion(_ formatVersion: String, at packageURL: URL) throws {
    let manifestURL = packageURL.appendingPathComponent("manifest.json")
    let data = try Data(contentsOf: manifestURL)
    var json = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
    json["formatVersion"] = formatVersion
    let rewritten = try JSONSerialization.data(withJSONObject: json)
    try rewritten.write(to: manifestURL)
}

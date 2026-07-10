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

@Test func missingEpisodeFileLoadsAsEmptyContent() async throws {
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

    let loaded = try await repository.load(from: packageURL)
    #expect(loaded.chapters[0].episodes[0].content.isEmpty)
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

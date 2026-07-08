import Foundation
import NovelCore
@testable import NovelStorage
import Testing

// メタデータ破損(Phase 4 レビュー F-C)に対するテスト。
//
// characters.json / plot.json / flags.json が壊れている場合、manifest.json 自体は
// 無事なので `.manifestCorrupted` ではなく `.metadataCorrupted` を投げる。挙動
// (load 全体を失敗させ、黙殺上書きを防ぐ)自体は変えない。
//
// `makeTempDirectory()` は NovelStorageTests.swift 側で定義されたヘルパーを
// そのまま利用する(同一テストターゲット内なので参照可能)。

@Test func corruptedCharactersFileThrowsMetadataCorruptedError() async throws {
    let tempDir = try makeTempDirectory()
    defer { try? FileManager.default.removeItem(at: tempDir) }

    let packageURL = tempDir.appendingPathComponent("CorruptedCharacters.novelpkg")
    let repository = NovelpkgRepository()

    let doc = NovelDocument(title: "破損テスト", chapters: [Chapter(title: "第1章")])
    try await repository.save(doc, to: packageURL)

    let charactersURL = packageURL.appendingPathComponent("characters.json")
    try "{ 壊れたJSON".write(to: charactersURL, atomically: true, encoding: .utf8)

    do {
        _ = try await repository.load(from: packageURL)
        Issue.record("characters.json が壊れているのに load が成功してしまった")
    } catch let error as NovelpkgError {
        guard case let .metadataCorrupted(url, file, _) = error else {
            Issue.record("想定外のエラーケース: \(error)")
            return
        }
        #expect(url == packageURL)
        #expect(file == "characters.json")
    } catch {
        Issue.record("想定外のエラー型: \(error)")
    }
}

@Test func corruptedPlotFileThrowsMetadataCorruptedError() async throws {
    let tempDir = try makeTempDirectory()
    defer { try? FileManager.default.removeItem(at: tempDir) }

    let packageURL = tempDir.appendingPathComponent("CorruptedPlot.novelpkg")
    let repository = NovelpkgRepository()

    let doc = NovelDocument(title: "破損テスト", chapters: [Chapter(title: "第1章")])
    try await repository.save(doc, to: packageURL)

    let plotURL = packageURL.appendingPathComponent("plot.json")
    try "{ 壊れたJSON".write(to: plotURL, atomically: true, encoding: .utf8)

    do {
        _ = try await repository.load(from: packageURL)
        Issue.record("plot.json が壊れているのに load が成功してしまった")
    } catch let error as NovelpkgError {
        guard case let .metadataCorrupted(url, file, _) = error else {
            Issue.record("想定外のエラーケース: \(error)")
            return
        }
        #expect(url == packageURL)
        #expect(file == "plot.json")
    } catch {
        Issue.record("想定外のエラー型: \(error)")
    }
}

@Test func corruptedFlagsFileThrowsMetadataCorruptedError() async throws {
    let tempDir = try makeTempDirectory()
    defer { try? FileManager.default.removeItem(at: tempDir) }

    let packageURL = tempDir.appendingPathComponent("CorruptedFlags.novelpkg")
    let repository = NovelpkgRepository()

    let doc = NovelDocument(title: "破損テスト", chapters: [Chapter(title: "第1章")])
    try await repository.save(doc, to: packageURL)

    let flagsURL = packageURL.appendingPathComponent("flags.json")
    try "{ 壊れたJSON".write(to: flagsURL, atomically: true, encoding: .utf8)

    do {
        _ = try await repository.load(from: packageURL)
        Issue.record("flags.json が壊れているのに load が成功してしまった")
    } catch let error as NovelpkgError {
        guard case let .metadataCorrupted(url, file, _) = error else {
            Issue.record("想定外のエラーケース: \(error)")
            return
        }
        #expect(url == packageURL)
        #expect(file == "flags.json")
    } catch {
        Issue.record("想定外のエラー型: \(error)")
    }
}

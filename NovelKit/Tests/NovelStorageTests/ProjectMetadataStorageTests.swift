import Foundation
import NovelCore
@testable import NovelStorage
import Testing

@Test func synopsisRoundTripsAndEmptySaveRemovesProjectMetadata() async throws {
    let tempDir = try makeTempDirectory()
    defer { try? FileManager.default.removeItem(at: tempDir) }

    let packageURL = tempDir.appendingPathComponent("Synopsis.novelpkg")
    let repository = NovelpkgRepository()
    var document = NovelDocument(
        title: "あらすじテスト",
        synopsis: "最初のあらすじ",
        chapters: [Chapter(title: "第1章")]
    )

    try await repository.save(document, to: packageURL)
    let projectURL = packageURL.appendingPathComponent("project.json")
    let metadata = try #require(
        try JSONSerialization.jsonObject(with: Data(contentsOf: projectURL)) as? [String: Any]
    )
    #expect(metadata["synopsis"] as? String == "最初のあらすじ")
    #expect(try await repository.load(from: packageURL).synopsis == "最初のあらすじ")

    document.synopsis = ""
    try await repository.save(document, to: packageURL)

    #expect(!FileManager.default.fileExists(atPath: projectURL.path))
    #expect(try await repository.load(from: packageURL).synopsis.isEmpty)
    #expect(try manifestJSON(at: packageURL)["formatVersion"] as? String == "3")
}

@Test func missingProjectMetadataLoadsAsEmptySynopsis() async throws {
    let tempDir = try makeTempDirectory()
    defer { try? FileManager.default.removeItem(at: tempDir) }

    let packageURL = tempDir.appendingPathComponent("NoProject.novelpkg")
    let repository = NovelpkgRepository()
    let document = NovelDocument(title: "旧v3", chapters: [Chapter(title: "第1章")])

    try await repository.save(document, to: packageURL)

    #expect(!FileManager.default.fileExists(atPath: packageURL.appendingPathComponent("project.json").path))
    #expect(try await repository.load(from: packageURL).synopsis.isEmpty)
}

@Test func synopsisIsPreservedBySnapshotsAndSaveCopy() async throws {
    let tempDir = try makeTempDirectory()
    defer { try? FileManager.default.removeItem(at: tempDir) }

    let sourceURL = tempDir.appendingPathComponent("Source.novelpkg")
    let destinationURL = tempDir.appendingPathComponent("Destination.novelpkg")
    let repository = NovelpkgRepository()
    var document = NovelDocument(
        title: "メタデータ保持",
        synopsis: "スナップショット時点",
        chapters: [Chapter(title: "第1章")]
    )

    try await repository.save(document, to: sourceURL)
    let snapshotURL = try await repository.saveSnapshot(document, to: sourceURL)

    document.synopsis = "別名保存先のあらすじ"
    try await repository.save(document, to: sourceURL)
    try await repository.saveCopy(document, from: sourceURL, to: destinationURL)

    #expect(try await repository.load(from: destinationURL).synopsis == "別名保存先のあらすじ")

    try await repository.restoreSnapshot(from: snapshotURL, into: sourceURL)

    #expect(try await repository.load(from: sourceURL).synopsis == "スナップショット時点")
}

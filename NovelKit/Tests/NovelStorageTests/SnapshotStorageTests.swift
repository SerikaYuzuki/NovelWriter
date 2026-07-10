import Foundation
import NovelCore
@testable import NovelStorage
import Testing

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

@Test func listSnapshotsReturnsNewestFirst() async throws {
    let tempDir = try makeTempDirectory()
    defer { try? FileManager.default.removeItem(at: tempDir) }

    let packageURL = tempDir.appendingPathComponent("SnapshotList.novelpkg")
    let repository = NovelpkgRepository()
    let doc = NovelDocument(title: "一覧テスト", chapters: [Chapter(title: "第1章", content: "本文")])

    try await repository.save(doc, to: packageURL)
    #expect(try await repository.listSnapshots(in: packageURL).isEmpty)

    let firstURL = try await repository.saveSnapshot(doc, to: packageURL)
    // 作成日時の差を確実にするため、ごく短く待つ。
    try await Task.sleep(for: .milliseconds(20))
    let secondURL = try await repository.saveSnapshot(doc, to: packageURL)

    let listed = try await repository.listSnapshots(in: packageURL)
    #expect(listed.map(\.url.lastPathComponent) == [
        secondURL.lastPathComponent,
        firstURL.lastPathComponent
    ])
    #expect(!listed[0].displayName.isEmpty)
}

@Test func restoreSnapshotRewritesPackageWhilePreservingSnapshots() async throws {
    let tempDir = try makeTempDirectory()
    defer { try? FileManager.default.removeItem(at: tempDir) }

    let packageURL = tempDir.appendingPathComponent("SnapshotRestore.novelpkg")
    let attachmentSourceURL = tempDir.appendingPathComponent("旧資料.txt")
    let repository = NovelpkgRepository()
    var doc = NovelDocument(title: "復元テスト", chapters: [Chapter(title: "第1章", content: "初版")])

    try await repository.save(doc, to: packageURL)
    try "旧資料".write(to: attachmentSourceURL, atomically: true, encoding: .utf8)
    _ = try await repository.addAttachment(from: attachmentSourceURL, to: packageURL)
    let snapshotURL = try await repository.saveSnapshot(doc, to: packageURL)

    doc.chapters[0].content = "更新版"
    try await repository.save(doc, to: packageURL)
    let newerAttachmentURL = tempDir.appendingPathComponent("新資料.txt")
    try "新資料".write(to: newerAttachmentURL, atomically: true, encoding: .utf8)
    _ = try await repository.addAttachment(from: newerAttachmentURL, to: packageURL)

    // 復元前に現在状態を退避する(App 層と同じ手順)。
    let currentDocument = try await repository.load(from: packageURL)
    let backupURL = try await repository.saveSnapshot(currentDocument, to: packageURL)
    try await repository.restoreSnapshot(from: snapshotURL, into: packageURL)

    let restored = try await repository.load(from: packageURL)
    #expect(restored.chapters[0].content == "初版")
    #expect(try await repository.listAttachments(in: packageURL).map(\.fileName) == ["旧資料.txt"])

    let listed = try await repository.listSnapshots(in: packageURL)
    #expect(Set(listed.map(\.url.lastPathComponent)) == Set([
        snapshotURL.lastPathComponent,
        backupURL.lastPathComponent
    ]))
}

import Foundation
import NovelCore
@testable import NovelStorage
import Testing

@Test func addingAttachmentThenSavingPreservesFile() async throws {
    let tempDir = try makeTempDirectory()
    defer { try? FileManager.default.removeItem(at: tempDir) }

    let packageURL = tempDir.appendingPathComponent("Attachments.novelpkg")
    let sourceURL = tempDir.appendingPathComponent("資料.txt")
    let repository = NovelpkgRepository()
    let doc = NovelDocument(title: "資料テスト", chapters: [Chapter(title: "第1章")])

    try await repository.save(doc, to: packageURL)
    try "参考資料".write(to: sourceURL, atomically: true, encoding: .utf8)
    let attachment = try await repository.addAttachment(from: sourceURL, to: packageURL)
    try await repository.save(doc, to: packageURL)

    let listed = try await repository.listAttachments(in: packageURL)
    let storedURL = repository.attachmentURL(named: attachment.fileName, in: packageURL)
    #expect(listed == [Attachment(fileName: "資料.txt", byteCount: 12)])
    #expect(try String(contentsOf: storedURL, encoding: .utf8) == "参考資料")
}

@Test func deletingAttachmentRemovesFileFromPackage() async throws {
    let tempDir = try makeTempDirectory()
    defer { try? FileManager.default.removeItem(at: tempDir) }

    let packageURL = tempDir.appendingPathComponent("DeleteAttachment.novelpkg")
    let sourceURL = tempDir.appendingPathComponent("guide.txt")
    let repository = NovelpkgRepository()

    try await repository.save(NovelDocument.newDocument(), to: packageURL)
    try "guide".write(to: sourceURL, atomically: true, encoding: .utf8)
    let attachment = try await repository.addAttachment(from: sourceURL, to: packageURL)
    try await repository.deleteAttachment(named: attachment.fileName, from: packageURL)

    let listed = try await repository.listAttachments(in: packageURL)
    let storedURL = repository.attachmentURL(named: attachment.fileName, in: packageURL)
    #expect(listed.isEmpty)
    #expect(!FileManager.default.fileExists(atPath: storedURL.path))
}

@Test func attachmentNameCollisionUsesNumberedFileName() async throws {
    let tempDir = try makeTempDirectory()
    defer { try? FileManager.default.removeItem(at: tempDir) }

    let firstDir = tempDir.appendingPathComponent("first", isDirectory: true)
    let secondDir = tempDir.appendingPathComponent("second", isDirectory: true)
    try FileManager.default.createDirectory(at: firstDir, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: secondDir, withIntermediateDirectories: true)

    let packageURL = tempDir.appendingPathComponent("Collision.novelpkg")
    let firstSourceURL = firstDir.appendingPathComponent("image.png")
    let secondSourceURL = secondDir.appendingPathComponent("image.png")
    let repository = NovelpkgRepository()

    try await repository.save(NovelDocument.newDocument(), to: packageURL)
    try Data([1, 2, 3]).write(to: firstSourceURL)
    try Data([4, 5]).write(to: secondSourceURL)

    let first = try await repository.addAttachment(from: firstSourceURL, to: packageURL)
    let second = try await repository.addAttachment(from: secondSourceURL, to: packageURL)

    let listed = try await repository.listAttachments(in: packageURL)
    #expect(first.fileName == "image.png")
    #expect(second.fileName == "image-2.png")
    #expect(Set(listed.map(\.fileName)) == Set(["image.png", "image-2.png"]))
}

import Foundation
import NovelCore
import NovelStorage
import NovelSyncV2
import NovelSyncV2PortableBridge
import Testing

private func portableBridgeTempDirectory() throws -> URL {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("NovelKit-PortableBridge-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

private func portableBridgeDocument() -> NovelDocument {
    NovelDocument(
        id: UUID(uuidString: "11111111-2222-3333-4444-555555555555")!,
        title: "橋渡しテスト",
        synopsis: "SQLiteが正本",
        chapters: [Chapter(title: "第一章", content: "本文", memo: "メモ")]
    )
}

private func syncAttachment(_ name: String, _ bytes: [UInt8]) -> SyncAttachment {
    SyncAttachment(
        attachmentId: UUID(),
        fileName: name,
        bytes: Data(bytes)
    )
}

@Test func explicitImportAndExportRoundTripPreservesDocumentAndAttachmentBytes() async throws {
    let root = try portableBridgeTempDirectory()
    defer { try? FileManager.default.removeItem(at: root) }

    let repository = NovelpkgRepository()
    let bridge = SyncV2PortableBridge(repository: repository)
    let source = root.appendingPathComponent("source.novelpkg", isDirectory: true)
    let destination = root.appendingPathComponent("exported.novelpkg", isDirectory: true)
    let document = portableBridgeDocument()
    try await repository.save(document, to: source)
    let attachmentDirectory = source.appendingPathComponent("attachments", isDirectory: true)
    try Data([0, 1, 2, 255]).write(to: attachmentDirectory.appendingPathComponent("画像.bin"))
    try Data("参考資料".utf8).write(to: attachmentDirectory.appendingPathComponent("参考.txt"))

    let imported = try await bridge.importExplicitPackage(from: source)
    #expect(imported.document == document)
    #expect(imported.attachments.map(\.fileName) == ["参考.txt", "画像.bin"])
    #expect(imported.attachments.allSatisfy { $0.byteCount == $0.bytes.count })

    let repeated = try await bridge.importExplicitPackage(from: source)
    #expect(imported.attachments.map(\.attachmentId) == repeated.attachments.map(\.attachmentId))

    try await bridge.exportExplicitPackage(
        document: imported.document,
        attachments: imported.attachments,
        to: destination
    )
    let exported = try await bridge.importExplicitPackage(from: destination)
    #expect(exported.document == document)
    #expect(exported.attachments.map(\.fileName) == imported.attachments.map(\.fileName))
    #expect(exported.attachments.map(\.bytes) == imported.attachments.map(\.bytes))
    #expect(exported.attachments.map(\.attachmentId) == imported.attachments.map(\.attachmentId))
}

@Test func exportRejectsDuplicateOrPortableCollidingNamesBeforeWritingDestination() async throws {
    let root = try portableBridgeTempDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let destination = root.appendingPathComponent("duplicate.novelpkg", isDirectory: true)
    let bridge = SyncV2PortableBridge()
    let values = [
        syncAttachment("資料.txt", [1]),
        syncAttachment("資料.TXT", [2])
    ]

    await #expect(throws: SyncV2PortableBridgeError.attachmentNameCollision("資料.TXT")) {
        try await bridge.exportExplicitPackage(
            document: portableBridgeDocument(),
            attachments: values,
            to: destination
        )
    }
    #expect(!FileManager.default.fileExists(atPath: destination.path))
}

@Test func exportRejectsExistingDestinationWithoutReplacingIt() async throws {
    let root = try portableBridgeTempDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let destination = root.appendingPathComponent("existing.novelpkg", isDirectory: true)
    let repository = NovelpkgRepository()
    try await repository.save(portableBridgeDocument(), to: destination)
    let before = try await repository.load(from: destination)

    await #expect(throws: SyncV2PortableBridgeError.destinationExists) {
        try await SyncV2PortableBridge().exportExplicitPackage(
            document: portableBridgeDocument(),
            attachments: [],
            to: destination
        )
    }
    #expect(try await repository.load(from: destination) == before)
}

@Test func importFailsClosedForAttachmentSymlinkAndLeavesPackageUntouched() async throws {
    let root = try portableBridgeTempDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let source = root.appendingPathComponent("symlink.novelpkg", isDirectory: true)
    let repository = NovelpkgRepository()
    try await repository.save(portableBridgeDocument(), to: source)
    let attachments = source.appendingPathComponent("attachments", isDirectory: true)
    let sourceBytes = root.appendingPathComponent("outside.bin")
    try Data([9, 8, 7]).write(to: sourceBytes)
    try FileManager.default.createSymbolicLink(
        at: attachments.appendingPathComponent("unsafe.bin"),
        withDestinationURL: sourceBytes
    )

    await #expect(throws: SyncV2PortableBridgeError.symbolicLink(relativePath: "attachments/unsafe.bin")) {
        try await SyncV2PortableBridge().importExplicitPackage(from: source)
    }
    #expect(FileManager.default.fileExists(atPath: source.path))
    #expect(FileManager.default.fileExists(atPath: attachments.appendingPathComponent("unsafe.bin").path))
}

@Test func importRejectsNestedAttachmentPathAndDoesNotCreateRuntimeState() async throws {
    let root = try portableBridgeTempDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let source = root.appendingPathComponent("nested.novelpkg", isDirectory: true)
    let repository = NovelpkgRepository()
    try await repository.save(portableBridgeDocument(), to: source)
    let attachments = source.appendingPathComponent("attachments", isDirectory: true)
    let nested = attachments.appendingPathComponent("nested", isDirectory: true)
    try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
    try Data([1]).write(to: nested.appendingPathComponent("guide.txt"))

    await #expect(throws: SyncV2PortableBridgeError.unsupportedAttachmentItem(relativePath: "attachments/nested")) {
        try await SyncV2PortableBridge().importExplicitPackage(from: source)
    }
    #expect(FileManager.default.fileExists(atPath: source.path))
}

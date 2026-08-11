import Foundation
import NovelCore
@testable import NovelStorage
import Testing

@Test func portablePackageValidationRejectsSymlinkWithoutReplacingExistingExport() async throws {
    let tempDir = try makeTempDirectory()
    defer { try? FileManager.default.removeItem(at: tempDir) }

    let repository = NovelpkgRepository()
    let source = tempDir.appendingPathComponent("Source.novelpkg", isDirectory: true)
    let destination = tempDir.appendingPathComponent("Existing.novelpkg", isDirectory: true)
    let sourceDocument = NovelDocument(title: "取り込み元", chapters: [Chapter(title: "第一章")])
    let existingDocument = NovelDocument(title: "既存の書き出し", chapters: [Chapter(title: "第一章")])
    try await repository.save(sourceDocument, to: source)
    try await repository.save(existingDocument, to: destination)

    let outside = tempDir.appendingPathComponent("outside.txt")
    try "外部の内容".write(to: outside, atomically: true, encoding: .utf8)
    try FileManager.default.createSymbolicLink(
        at: source.appendingPathComponent("future-resource"),
        withDestinationURL: outside
    )

    await #expect(throws: NovelpkgPortableTransferError.self) {
        try await repository.saveValidatedCopy(
            sourceDocument,
            from: source,
            to: destination
        )
    }
    #expect(try await repository.load(from: destination) == existingDocument)
}

@Test func validatedPortableCopyPreservesPackageOwnedDataAndReadsBackExactly() async throws {
    let tempDir = try makeTempDirectory()
    defer { try? FileManager.default.removeItem(at: tempDir) }

    let repository = NovelpkgRepository()
    let source = tempDir.appendingPathComponent("Source.novelpkg", isDirectory: true)
    let destination = tempDir.appendingPathComponent("Export.novelpkg", isDirectory: true)
    let attachmentSource = tempDir.appendingPathComponent("資料.txt")
    let document = NovelDocument(title: "安全な書き出し", chapters: [Chapter(title: "第一章")])
    try await repository.save(document, to: source)
    try "資料本文".write(to: attachmentSource, atomically: true, encoding: .utf8)
    _ = try await repository.addAttachment(from: attachmentSource, to: source)
    _ = try await repository.saveSnapshot(document, to: source)
    try "{}".write(
        to: source.appendingPathComponent("future-metadata.json"),
        atomically: true,
        encoding: .utf8
    )

    try await repository.saveValidatedCopy(document, from: source, to: destination)

    #expect(try await repository.validatePortablePackage(at: destination) == document)
    #expect(try await repository.listAttachments(in: destination).map(\.fileName) == ["資料.txt"])
    #expect(try await repository.listSnapshots(in: destination).count == 1)
    #expect(FileManager.default.fileExists(
        atPath: destination.appendingPathComponent("future-metadata.json").path
    ))
}

@Test func portablePackageValidationEnforcesResourceAndOverlapBounds() async throws {
    let tempDir = try makeTempDirectory()
    defer { try? FileManager.default.removeItem(at: tempDir) }

    let repository = NovelpkgRepository()
    let source = tempDir.appendingPathComponent("Source.novelpkg", isDirectory: true)
    let document = NovelDocument(title: "resource", chapters: [Chapter(title: "第一章")])
    try await repository.save(document, to: source)

    let tinyLimits = NovelpkgRepository.PortablePackageLimits(
        maximumDepth: 16,
        maximumItemCount: 20000,
        maximumFileBytes: 3,
        maximumTotalBytes: 2 * 1024 * 1024 * 1024
    )
    #expect(throws: NovelpkgPortableTransferError.self) {
        try NovelpkgRepository.validatePortablePackageSynchronously(
            at: source,
            requiresPackageExtension: true,
            limits: tinyLimits
        )
    }

    let nestedDestination = source.appendingPathComponent("Nested.novelpkg", isDirectory: true)
    await #expect(throws: NovelpkgPortableTransferError.invalidPackage) {
        try await repository.saveValidatedCopy(
            document,
            from: source,
            to: nestedDestination
        )
    }
}

@Test func portablePackageValidationRejectsOversizedKnownTextBeforeLoadingIt() async throws {
    let tempDir = try makeTempDirectory()
    defer { try? FileManager.default.removeItem(at: tempDir) }

    let repository = NovelpkgRepository()
    let source = tempDir.appendingPathComponent("Oversized.novelpkg", isDirectory: true)
    let document = NovelDocument(title: "oversized", chapters: [Chapter(title: "第一章")])
    try await repository.save(document, to: source)
    let episodeID = try #require(document.chapters.first?.episodes.first?.id)
    let episodeURL = source
        .appendingPathComponent("episodes", isDirectory: true)
        .appendingPathComponent("\(episodeID.rawValue.uuidString).md")
    try Data(repeating: 0x61, count: 1_048_577).write(to: episodeURL)

    await #expect(throws: NovelpkgPortableTransferError.self) {
        try await repository.validatePortablePackage(at: source)
    }
}

import Foundation
import NovelCore
@testable import NovelExport
import Testing

@Test func exporterCreatesAndReplacesOutputWithoutLeavingTemporaryFiles() throws {
    let directory = try makeExportTempDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }

    let destination = directory.appendingPathComponent("Novel.txt")
    try Data("古い出力".utf8).write(to: destination)
    let document = NovelDocument(
        title: "作品",
        chapters: [Chapter(title: "章", episodes: [Episode(title: "話", content: "新しい本文")])]
    )
    let exporter = NovelExporter()
    let expected = try exporter.render(document, options: ExportOptions(format: .plainText))

    try exporter.export(document, to: destination, options: ExportOptions(format: .plainText))

    #expect(try Data(contentsOf: destination) == expected)
    #expect(try temporaryExportFiles(in: directory).isEmpty)
}

@Test func longValidDestinationNamesCreateAndReplaceWithoutLeavingTemporaryFiles() throws {
    let directory = try makeExportTempDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }

    for (filenameByteCount, oldData) in [
        (214, nil),
        (255, Data("古い出力".utf8))
    ] {
        let filename = String(repeating: "a", count: filenameByteCount - 4) + ".txt"
        #expect(filename.lengthOfBytes(using: .utf8) == filenameByteCount)

        let destination = directory.appendingPathComponent(filename)
        if let oldData {
            try oldData.write(to: destination)
        }

        let newData = Data("新しい出力-\(filenameByteCount)".utf8)
        try AtomicExportWriter.write(newData, to: destination)

        #expect(try Data(contentsOf: destination) == newData)
        #expect(try temporaryExportFiles(in: directory).isEmpty)
    }
}

@Test func failedCommitPreservesExistingOutputAndRemovesTemporaryFile() throws {
    let directory = try makeExportTempDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }

    let destination = directory.appendingPathComponent("Protected.md")
    let oldData = Data("既存の大切な出力".utf8)
    let newData = Data("置換予定の出力".utf8)
    try oldData.write(to: destination)
    var observedTemporaryURL: URL?

    do {
        try AtomicExportWriter.write(
            newData,
            to: destination,
            fileManager: .default
        ) { temporaryURL, destinationURL, _ in
            observedTemporaryURL = temporaryURL
            #expect(temporaryURL.deletingLastPathComponent() == destinationURL.deletingLastPathComponent())
            #expect(try Data(contentsOf: temporaryURL) == newData)
            #expect(try Data(contentsOf: destinationURL) == oldData)
            throw ForcedCommitFailure()
        }
        Issue.record("置換失敗を注入したのに書き出しが成功した")
    } catch let error as ExportError {
        #expect(
            error == .destinationReplacementFailed(
                destination: destination,
                reason: "forced commit failure"
            )
        )
    }

    let temporaryURL = try #require(observedTemporaryURL)
    #expect(try Data(contentsOf: destination) == oldData)
    #expect(!FileManager.default.fileExists(atPath: temporaryURL.path))
    #expect(try temporaryExportFiles(in: directory).isEmpty)
}

@Test func nonFileDestinationThrowsTypedError() throws {
    let destination = try #require(URL(string: "https://example.com/Novel.txt"))

    do {
        try AtomicExportWriter.write(Data(), to: destination)
        Issue.record("ファイルURLではないのに書き出しが成功した")
    } catch let error as ExportError {
        #expect(error == .invalidDestination(destination))
    }
}

private struct ForcedCommitFailure: Error, CustomStringConvertible {
    var description: String {
        "forced commit failure"
    }
}

private func makeExportTempDirectory() throws -> URL {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("NovelExportTests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

private func temporaryExportFiles(in directory: URL) throws -> [URL] {
    try FileManager.default.contentsOfDirectory(
        at: directory,
        includingPropertiesForKeys: nil
    ).filter { $0.lastPathComponent.hasSuffix(".tmp") }
}

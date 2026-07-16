#if os(macOS)
import Foundation
@testable import NovelExport
import Testing

@Test func generatedEPUBPassesSystemUnzipAndXMLWellFormednessChecks() throws {
    let directory = try makeExternalValidationDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }

    let destination = directory.appendingPathComponent("Validation.epub")
    try NovelExporter().export(
        makeEPUBFixture(),
        to: destination,
        options: ExportOptions(format: .epub)
    )

    let unzip = try runValidationTool(
        executable: URL(fileURLWithPath: "/usr/bin/unzip"),
        arguments: ["-t", destination.path]
    )
    #expect(unzip.status == 0, Comment(rawValue: unzip.output))

    let archive = try TestZIPArchive(data: Data(contentsOf: destination))
    let xmlPaths = archive.localEntries.map(\.path).filter { path in
        path.hasSuffix(".xml") || path.hasSuffix(".opf") || path.hasSuffix(".xhtml")
    }
    for path in xmlPaths {
        let fileName = path.replacingOccurrences(of: "/", with: "_")
        let fileURL = directory.appendingPathComponent(fileName)
        try archive.data(named: path).write(to: fileURL)
        let xmllint = try runValidationTool(
            executable: URL(fileURLWithPath: "/usr/bin/xmllint"),
            arguments: ["--noout", fileURL.path]
        )
        #expect(xmllint.status == 0, Comment(rawValue: "\(path): \(xmllint.output)"))
    }
}

private struct ValidationToolResult {
    let status: Int32
    let output: String
}

private func runValidationTool(executable: URL, arguments: [String]) throws -> ValidationToolResult {
    let process = Process()
    let outputPipe = Pipe()
    let errorPipe = Pipe()
    process.executableURL = executable
    process.arguments = arguments
    process.standardOutput = outputPipe
    process.standardError = errorPipe
    try process.run()
    process.waitUntilExit()

    let output = outputPipe.fileHandleForReading.readDataToEndOfFile()
    let errors = errorPipe.fileHandleForReading.readDataToEndOfFile()
    let combined = output + errors
    return ValidationToolResult(
        status: process.terminationStatus,
        output: String(bytes: combined, encoding: .utf8) ?? ""
    )
}

private func makeExternalValidationDirectory() throws -> URL {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("NovelExport-EPUBValidation-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}
#endif
